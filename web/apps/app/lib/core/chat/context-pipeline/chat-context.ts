/**
 * Context projection for the main chat path (send / retry / regenerate / send after edit, purpose=chat) and explicit continuation (purpose=continue):
 * ContextAssembler.assemble produces the plan, system = plan.system, history = plan.messages mapped back to app messages by message id,
 * and [D] (attachment notes, direct library access) is appended to the end of the current user text.
 */
import type { StoreApi } from 'zustand';
import { buildEffectiveUserContent, type AIModel, type ChatMessage, type Conversation, type Provider, type ProviderKind, type ReasoningMode } from '@oriveo/shared';
import type { GenerationParameterOverrides } from '@oriveo/core/providers/request-builders/types';
import type { ContentPart, StreamOptions, StreamUsage } from '@oriveo/core/providers/types';
import {
  ContextAssembler,
  type AssembleDynamic,
  type AssembleInput,
  type ContextPlan,
} from '@oriveo/core/context/assemble';
import { detectDirective } from '@oriveo/core/context/directive-detector';
import {
  CONTEXT_BUDGET_CONSTANTS,
  ContextBudget,
  type BudgetCapOption,
  type ContextWindowBudget,
  type MaxOutputSources,
} from '@oriveo/core/context/budget';
import type { ContextManifest } from '@oriveo/core/context/manifest';
import { ContextOverflowClassifier, type OverflowFamily } from '@oriveo/core/context/overflow';
import type { StopFamily, StopReason } from '@oriveo/core/context/stop-reason';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import type { ContextPlanReject } from '@oriveo/core/context/plan';
import type { ContextMessage } from '@oriveo/core/context/message';
import { RhoCalibration } from '@oriveo/core/context/calibration';
import type { ContinuationFingerprint } from '@oriveo/core/providers/request-builders/types';
import type { AppStore } from '../../store/app-store';
import { resolveCatalogModel } from '../../metadata/metadata-client';
import { resolveContextDefaultCap } from '../../context-cap-preferences';
import { appendContextManifest, getRhoCalibration, putRhoCalibration } from '../../../infra/storage/context-ledger-store';
import { buildChatContextSources, type PromptInjectionContext } from '../prompt-injection';
import { stopFamilyForRequest } from '../stop-reason-outcome';
import { createCanonicalUUID } from '../../../utils/id-utils';
import {
  generationParameterFallbackModelId,
  generationParameterProfileFingerprint,
  resolveGenerationParameterOverrides,
} from '../generation-parameter-settings';
import {
  buildProviderStreamOptions,
  buildStreamOptionsFromIntent,
  filterGenerationParameterOverrides,
} from '../stream-options';
import type { ContextCheckpointRow } from '../../../infra/storage/context-checkpoint-store';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { sendStream } from '../../providers/service';
import { requestBaseURLText } from '../../providers/endpoint-source';
import { readStream } from '../../../utils/chat-stream-utils';
import { ContextCompactionStore } from '../context-compaction/context-compaction-store';
import type { CompactionContext, ReadySummaryRequest } from './compaction-coordinator';
import { assemblePurposeRequest } from './purpose-request';
import { transportInput } from './transport-input';

export interface ChatContextAssembly {
  /** The assembler input of this request (without [D]); assembling the same input again only adds the [D] block. */
  readonly input: AssembleInput;
  readonly promptContext: PromptInjectionContext;
  /** Id of the first tail message after the fallback (0.90 or overflow recovery); absent when no fallback ran. */
  readonly tailFrom?: string;
  /** Checkpoint text the fallback put into the tail (the checkpoint digest of the continuation fingerprint); absent when no fallback ran. */
  readonly checkpointText?: string;
  /**
   * Text of a user message with a quote after it is expanded at the provider boundary (what the model actually sees), by message id;
   * history keeps the original text, and the library row digest and the compaction snapshot use this version.
   */
  readonly expandedUserTexts?: Readonly<Record<string, string>>;
}

/** Purpose of the assembler entry: main chat path, explicit continuation, or one leg of the tool loop. */
export type ChatContextPurpose = 'chat' | 'continue' | 'toolLoopLeg';

/** Transport key for rho calibration and the manifest: the provider instance id. */
export function contextTransportIdOf(provider: { id: string; kind: ProviderKind }): string {
  return provider.id;
}

/**
 * Effective cap tier of this conversation: the conversation's contextCap when set, otherwise the global contextDefaultCap (unresolvable = auto).
 * Without a conversation (first send of a new conversation) only the global value is used.
 */
export function contextCapOf(store: StoreApi<AppStore>, conversation: Conversation | undefined): BudgetCapOption {
  return conversation?.contextCap ?? resolveContextDefaultCap(store.getState().preferences);
}

/**
 * The window comes from the model: contextLength / maxOutputTokens, falling back to the catalog when the model lacks them.
 * The price line T only takes the pricing.longContext decoded from the catalog; Relay does not use T. budgetCap = the effective tier of this conversation.
 */
export function windowOf(
  provider: Provider,
  model: AIModel,
  userMaxOutput: number | null,
  budgetCap: BudgetCapOption,
): AssembleInput['window'] & { budgetCap: BudgetCapOption } {
  const catalog = resolveCatalogModel(model.id, provider.kind);
  const usesPriceLine = provider.kind !== 'relay';
  const maxOutput: MaxOutputSources = {
    user: userMaxOutput,
    recipe: null,
    model: model.maxOutputTokens ?? catalog?.maxOutputTokens ?? null,
  };
  return {
    W: model.contextLength ?? catalog?.contextLength ?? null,
    windowKind: 'total',
    maxOutput,
    priceLineTokens: usesPriceLine ? catalog?.pricing?.longContext?.thresholdTokens ?? null : null,
    budgetCap,
  };
}

/** Budget computed from the same window input as assemble (O for the manifest, U for an overflow miss); O and U do not depend on the tier, so the default tier is used. */
function chatWindowBudgetOf(provider: Provider, model: AIModel, userMaxOutput: number | null): ContextWindowBudget {
  return ContextBudget.window(windowOf(provider, model, userMaxOutput, CONTEXT_BUDGET_CONSTANTS.budgetCapDefault));
}

/** rho key (transport key, model id sent on the wire); rho0 is used when there is no record or the Ledger cannot be read. */
async function rhoHiOf(provider: Provider, wireModelId: string): Promise<number> {
  try {
    return (await getRhoCalibration(contextTransportIdOf(provider), wireModelId)).rhoHi;
  } catch {
    return RhoCalibration.initial().rhoHi;
  }
}

/** rho for display (token counts before / after on the separator row): same source as the send path; rho0 when the provider / model is missing. */
export function displayRhoHiOf(provider: Provider | undefined, modelId: string | undefined): Promise<number> {
  if (!provider || !modelId) return Promise.resolve(RhoCalibration.initial().rhoHi);
  return rhoHiOf(provider, modelId);
}

function toContextMessage(message: ChatMessage): ContextMessage | null {
  if (message.role !== 'user' && message.role !== 'assistant') return null;
  return {
    id: message.id,
    role: message.role,
    text: message.text ?? '',
    state: message.state,
    attachments: message.attachments ?? [],
  };
}

export async function prepareChatContextAssembly(input: {
  store: StoreApi<AppStore>;
  conversation: Conversation | undefined;
  conversationId: string;
  provider: Provider;
  model: AIModel;
  /** Outbound history (including this turn's user message, attachments already filtered by the current model's capabilities). */
  messages: ChatMessage[];
  keepAssistantId?: string;
  latestUserText: string;
  /** Defaults to chat; for continue, messages are cut at the target assistant message (inclusive) and the assembler replaces current with the continuation sentence. */
  purpose?: ChatContextPurpose;
}): Promise<ChatContextAssembly> {
  const [sources, rhoHi] = await Promise.all([
    buildChatContextSources(input.store, input.conversation, input.latestUserText),
    rhoHiOf(input.provider, input.model.id),
  ]);
  const history = input.messages
    .map(toContextMessage)
    .filter((message): message is ContextMessage => message !== null);
  const expandedUserTexts: Record<string, string> = {};
  for (const message of input.messages) {
    if (message.role !== 'user' || !message.quoteContext) continue;
    const expanded = buildEffectiveUserContent(message.text ?? '', message.quoteContext);
    if (expanded !== (message.text ?? '')) expandedUserTexts[message.id] = expanded;
  }
  return {
    ...(Object.keys(expandedUserTexts).length > 0 ? { expandedUserTexts } : {}),
    input: {
      purpose: input.purpose ?? 'chat',
      window: windowOf(input.provider, input.model, null, contextCapOf(input.store, input.conversation)),
      rhoHi,
      conversation: { id: input.conversationId, ...sources.conversation },
      memoryItems: sources.memoryItems,
      reminderEnabled: sources.reminderEnabled,
      // This turn's user message is already at the end of the history: the assembler normalizes "history + current" and "the whole history" to the same result.
      history,
      ...(input.keepAssistantId ? { keepAssistantId: input.keepAssistantId } : {}),
    },
    promptContext: sources.promptContext,
  };
}

/**
 * Model id sent on the wire (the model key for rho and the manifest): when a relay inline image generation switches to a chat driver model, the driver id.
 */
export function chatWireModelIdOf(model: AIModel, sent: Pick<StreamOptions, 'relayDriverModelID'> | undefined): string {
  return sent?.relayDriverModelID || model.id;
}

/** Rereads rho by the wire model id: only swapped when it differs from the id used at prepare time (affects this assemble's estimate only). */
export async function withChatRhoModel(
  assembly: ChatContextAssembly,
  provider: Provider,
  model: AIModel,
  wireModelId: string,
): Promise<ChatContextAssembly> {
  if (wireModelId === model.id) return assembly;
  return { ...assembly, input: { ...assembly.input, rhoHi: await rhoHiOf(provider, wireModelId) } };
}

/**
 * The panel "max output" used by the pre-send check: same resolution chain as the send path (scope readback -> profile filter).
 * Returns null when none is set.
 */
export function chatUserMaxOutputFor(input: {
  provider: Provider;
  model: AIModel;
  conversationId?: string;
  reasoningMode: ReasoningMode;
  webSearchEnabled?: boolean;
}): number | null {
  const { provider, model } = input;
  const unresolved = resolveGenerationParameterOverrides({
    providerId: provider.id,
    modelId: model.id,
    profileFingerprint: generationParameterProfileFingerprint(provider, model),
    fallbackModelId: generationParameterFallbackModelId(provider, model),
    ...(input.conversationId ? { conversationId: input.conversationId } : {}),
    reasoningMode: input.reasoningMode,
  });
  if (!unresolved) return null;
  const options = buildProviderStreamOptions(
    provider,
    buildStreamOptionsFromIntent(model, input.reasoningMode, input.webSearchEnabled, unresolved),
    model,
  );
  return userMaxOutputOf(filterGenerationParameterOverrides(provider, model, unresolved, options));
}

/** The user value of the panel "max output" (first in the O chain); null when unset or not a positive number. */
export function userMaxOutputOf(overrides: GenerationParameterOverrides | undefined): number | null {
  const override = overrides?.max_output_tokens;
  return override?.state === 'value' && typeof override.value === 'number' && override.value > 0
    ? override.value
    : null;
}

/**
 * The window input (W / O / T / tier) assembleChatPlan used to build the plan.
 * The pre-send confirmation gate judges B / limitedBy / T from it and does not recompute from the store.
 */
export type ChatPlanWindow = ReturnType<typeof windowOf>;

export function chatPlanWindowOf(
  assembly: ChatContextAssembly,
  options: { provider: Provider; model: AIModel; userMaxOutput?: number | null },
): ChatPlanWindow {
  // The tier reuses what assembly already resolved (prepareChatContextAssembly) and does not reread preferences.
  return windowOf(
    options.provider,
    options.model,
    options.userMaxOutput ?? null,
    assembly.input.window.budgetCap ?? CONTEXT_BUDGET_CONSTANTS.budgetCapDefault,
  );
}

export function assembleChatPlan(
  assembly: ChatContextAssembly,
  options: { provider: Provider; model: AIModel; dynamic?: AssembleDynamic; userMaxOutput?: number | null },
): ContextPlan {
  const input: AssembleInput = {
    ...assembly.input,
    window: chatPlanWindowOf(assembly, options),
    ...(options.dynamic ? { dynamic: options.dynamic } : {}),
  };
  const plan = ContextAssembler.assemble(input);
  if (plan.messages !== null) return plan;
  // Rejection is already blocked by the entry pre-check (chatContextRejectBeforeSend); getting here means the send-time input differs from the pre-check (e.g. the panel max output),
  // so assemble again with an unknown window (an unknown window never rejects) and send the request as usual.
  return ContextAssembler.assemble({ ...input, window: { ...input.window, W: null } });
}

// The only implementation of the projection and the [D] text lives in transport-input.ts (the PlannedChatRequest brand is sealed only there).
export { planDynamicText, projectPlanMessages } from './transport-input';

/**
 * Pre-send rejection check: called at the entry before the assistant message is created and the stream is interrupted. An unknown window does not reject and returns null directly.
 * messages is the outbound history (including this turn's user message); returns plan.reject.
 */
export async function chatContextRejectBeforeSend(input: {
  store: StoreApi<AppStore>;
  conversation: Conversation | undefined;
  provider: Provider;
  model: AIModel;
  messages: ChatMessage[];
  latestUserText: string;
  /** Panel max output (the user level of O): uses the same window input as assembleChatPlan. */
  userMaxOutput?: number | null;
}): Promise<ContextPlanReject | null> {
  const window = windowOf(input.provider, input.model, input.userMaxOutput ?? null, contextCapOf(input.store, input.conversation));
  if (window.W === null) return null;
  const assembly = await prepareChatContextAssembly({
    ...input,
    conversationId: input.conversation?.id ?? '',
  });
  return ContextAssembler.assemble({ ...assembly.input, window }).reject;
}

function planMessageText(message: { blocks: ReadonlyArray<{ kind: string; text: string }> }): string {
  return message.blocks.filter((block) => block.kind === 'text').map((block) => block.text).join('');
}

/** All outbound text of the current message: body + [D] ([D] follows the body after a blank line, consistent with appendTextToLatestUserMessage). */
function planMessageWireText(message: { blocks: ReadonlyArray<{ kind: string; text: string }> }): string {
  const dynamic = message.blocks.filter((block) => block.kind === 'dynamic').map((block) => block.text).join('\n\n');
  const text = planMessageText(message);
  return dynamic ? `${text}\n\n${dynamic}` : text;
}

/**
 * In-memory fallback before sending at 0.90: when plan.compaction=required, ContextCheckpoint.fallback picks the tail,
 * the checkpoint is handed to the assembler to be placed before the first user text block, and the assembly to rebuild with is returned.
 * Only changes this request and saves nothing; it is sent even when targetMet=false. Returns null when the plan needs no fallback.
 * A chat send reaches here only when there is no usable library row and the compaction coordinator returned noop.
 */
export function compactChatContextAssembly(
  assembly: ChatContextAssembly,
  plan: ContextPlan,
  oldSummary: string | null,
): ChatContextAssembly | null {
  if (plan.compaction !== 'required' || plan.budget.B === null) return null;
  return fallbackChatContextAssembly(assembly, plan, plan.budget.B, oldSummary);
}

/**
 * Overflow recovery fallback: ignores the 0.90 line and picks the tail again from the failed request's plan; when W is unknown, B = the failed request's estimatedInput.
 * Returns null (no resend) when no checkpoint can be produced (the history is already within the tail budget).
 */
export function overflowFallbackChatContextAssembly(
  assembly: ChatContextAssembly,
  plan: ContextPlan,
  oldSummary: string | null,
): ChatContextAssembly | null {
  const B = plan.budget.B ?? plan.budget.estimatedInput;
  if (B === null || B <= 0) return null;
  return fallbackChatContextAssembly(assembly, plan, B, oldSummary);
}

/** oldSummary: the non-empty summary of the current checkpoint winner, still carried by the fallback checkpoint; pass null when there is none. */
function fallbackChatContextAssembly(
  assembly: ChatContextAssembly,
  plan: ContextPlan,
  B: number,
  oldSummary: string | null,
): ChatContextAssembly | null {
  const planMessages = plan.messages;
  if (planMessages === null || planMessages.length === 0) return null;
  const rhoHi = assembly.input.rhoHi ?? RhoCalibration.initial().rhoHi;
  const current = planMessages[planMessages.length - 1];
  const earlier = planMessages.slice(0, -1);
  const fixedTokens = (plan.system === null ? 0 : ContextBudget.estimateMessage(plan.system, rhoHi))
    + ContextBudget.estimateMessage(planMessageWireText(current), rhoHi);
  const result = ContextCheckpoint.fallback(
    earlier.map((message) => ({
      id: message.id,
      role: message.role,
      estTokens: ContextBudget.estimateMessage(planMessageText(message), rhoHi),
      ...(message.role === 'user'
        ? { text: planMessageText(message), isDirective: detectDirective(planMessageText(message)).isDirective }
        : {}),
    })),
    B,
    rhoHi,
    fixedTokens,
    oldSummary,
  );
  if (!result.checkpointText) return null;
  if (result.tailStartId) return spliceCheckpointAssembly(assembly, result.tailStartId, result.checkpointText, current.id);
  // When no tail start can be given the tail is only the current message: the unanswered user message merged into the current message by the original plan (whose answer failed) is not in the plan history,
  // so take the user messages after the last plan-history message and before the current message in the original history and rejoin them to the tail; on rebuild sanitize still merges them into <oriveo-unanswered>.
  const history = assembly.input.history;
  const currentIndex = history.findIndex((message) => message.id === current.id);
  const lastKept = earlier[earlier.length - 1];
  // When the last plan-history message cannot be found in the original history, from = 0 (findIndex -1 + 1), treated as nothing to rejoin.
  const from = lastKept ? history.findIndex((message) => message.id === lastKept.id) + 1 : 0;
  const lastKeptFound = !lastKept || from > 0;
  const carried = lastKeptFound && currentIndex > from
    ? history.slice(from, currentIndex).filter((message) => message.role === 'user')
    : [];
  return spliceCheckpointAssembly(assembly, current.id, result.checkpointText, current.id, carried);
}

/**
 * The tail starts at startId in the history and the checkpoint is handed to the assembler (input.checkpoint): after sanitize it
 * is placed before the first user text block and is not wrapped into the unanswered envelope. Returns null when the tail has neither a user message nor a current message.
 */
function spliceCheckpointAssembly(
  assembly: ChatContextAssembly,
  startId: string,
  checkpointText: string,
  currentId: string,
  carriedUsers: ContextMessage[] = [],
): ChatContextAssembly | null {
  const history = assembly.input.history;
  const start = history.findIndex((message) => message.id === startId);
  if (start < 0) return null;
  const tail = [...carriedUsers, ...history.slice(start)];
  const firstUser = tail.findIndex((message) => message.role === 'user');
  const target = firstUser >= 0 ? firstUser : tail.findIndex((message) => message.id === currentId);
  if (target < 0) return null;
  return {
    ...assembly,
    input: { ...assembly.input, history: tail, checkpoint: checkpointText },
    tailFrom: startId,
    checkpointText,
  };
}

/* ── Library rows ────────────────────────── */

/** Message text handed to library rows / the coordinator: user messages after quote expansion, assistant messages verbatim. */
function modelSeenText(assembly: ChatContextAssembly, message: ContextMessage): string {
  return message.role === 'user' ? assembly.expandedUserTexts?.[message.id] ?? message.text : message.text;
}

/** The newest library row usable under the current history; an unreadable database counts as none. */
export async function latestValidChatCheckpoint(
  conversationId: string,
  assembly: ChatContextAssembly,
): Promise<ContextCheckpointRow | null> {
  try {
    return await ContextCompactionStore.latestValid(
      conversationId,
      assembly.input.history.map((message) => ({ id: message.id, text: modelSeenText(assembly, message) })),
    );
  } catch {
    return null;
  }
}

/**
 * Applies a library row: tail = history after coversTo, and row.text is handed to the assembler as input.checkpoint.
 * Returns null when coversTo is the last message of the history (there is no tail).
 */
export function applyCheckpointRowAssembly(
  assembly: ChatContextAssembly,
  row: Pick<ContextCheckpointRow, 'coversTo' | 'text'>,
): ChatContextAssembly | null {
  const history = assembly.input.history;
  const coversIndex = history.findIndex((message) => message.id === row.coversTo);
  const tailStart = coversIndex < 0 ? undefined : history[coversIndex + 1];
  if (!tailStart) return null;
  return spliceCheckpointAssembly(assembly, tailStart.id, row.text, history[history.length - 1].id);
}

/**
 * Conversation snapshot for the coordinator: messages = local history before the current message (user messages quote-expanded, assistant messages verbatim, same basis as latestValid),
 * fixedTokens = system + the full outbound text of the current message (same basis as the in-memory fallback). Returns null when the window is unknown.
 */
export function chatCompactionContextOf(
  assembly: ChatContextAssembly,
  plan: ContextPlan,
  options: { provider: Provider; model: AIModel; userMaxOutput: number | null; B?: number | null },
): CompactionContext | null {
  const planMessages = plan.messages;
  // Overflow recovery passes B the way the in-memory fallback does (when W is unknown, the failed request's estimatedInput); by default the plan's B is used.
  const B = options.B !== undefined ? options.B : plan.budget.B;
  if (planMessages === null || planMessages.length === 0 || B === null) return null;
  const U = chatWindowBudgetOf(options.provider, options.model, options.userMaxOutput).U;
  if (U === null) return null;
  const rhoHi = assembly.input.rhoHi ?? RhoCalibration.initial().rhoHi;
  const current = planMessages[planMessages.length - 1];
  const prefixTokens = plan.system === null ? 0 : ContextBudget.estimateMessage(plan.system, rhoHi);
  return {
    messages: assembly.input.history
      .filter((message) => message.id !== current.id)
      .map((message) => ({ message, text: modelSeenText(assembly, message) }))
      .map(({ message, text }) => ({
        id: message.id,
        role: message.role as 'user' | 'assistant',
        text,
        estTokens: ContextBudget.estimateMessage(text, rhoHi),
        ...(message.role === 'user' ? { isDirective: detectDirective(text).isDirective } : {}),
        ...(message.attachments.length > 0
          ? {
            attachments: message.attachments.map((attachment) => ({
              kind: attachment.kind === 'image' ? 'image' as const : 'file' as const,
              name: attachment.fileName,
            })),
          }
          : {}),
      })),
    B,
    U,
    prefixTokens,
    rhoHi,
    fixedTokens: prefixTokens + ContextBudget.estimateMessage(planMessageWireText(current), rhoHi),
    model: options.model.id,
  };
}

/**
 * One compaction summary call: the conversation's provider/model goes through the one-shot call channel, purpose=compaction;
 * system = req.system ?? the system of this chat plan, messages = req.messages, max output = req.maxOutputTokens;
 * no tools, [D] or extra memory.
 */
export async function requestCompactionSummary(input: {
  provider: Provider;
  model: AIModel;
  req: ReadySummaryRequest;
  chatSystem: string | null;
  /** Conversation instructions: the compaction assembly input carries them, consistent with the chat input; the system on the wire is still chatSystem. */
  instructions: string;
  /** Cancel / stop: aborts this summary request. */
  signal?: AbortSignal;
}): Promise<string> {
  const { provider, model, req } = input;
  const planned = assemblePurposeRequest({
    purpose: 'compaction',
    system: req.system ?? input.chatSystem,
    messages: req.messages,
    instructions: input.instructions,
  });
  // Goes through sendStream, the same channel as runChatOutbound.
  const options = buildProviderStreamOptions(provider, { maxOutputTokens: req.maxOutputTokens }, model);
  const transport = transportInput(planned, { options, planMessages: true });
  if (input.signal?.aborted) return '';
  const { stream, abort } = sendStream(
    provider.kind,
    resolveProviderAPIKey(provider, model.id),
    model.id,
    transport.messages,
    requestBaseURLText(provider),
    transport.options,
  );
  return readAbortable(stream, abort, input.signal);
}

/** Reads the summary stream to the end; aborts the underlying request when the signal aborts. */
async function readAbortable(
  stream: Parameters<typeof readStream>[0],
  abort: () => void,
  signal: AbortSignal | undefined,
): Promise<string> {
  if (signal?.aborted) {
    abort();
    return '';
  }
  signal?.addEventListener('abort', abort, { once: true });
  try {
    const { fullText } = await readStream(stream, '', () => {});
    return fullText;
  } finally {
    signal?.removeEventListener('abort', abort);
  }
}

/**
 * Continuation fingerprint: {digest of plan.system, wire model id, digest of the checkpoint text}.
 * Stored on this device together with the continuation state and not saved to the database; anything unavailable counts as "changed".
 */
export interface ChatContinuationFingerprint {
  system: string;
  model: string;
  checkpoint: string;
}

/** FNV-1a 32-bit digest plus length: only used to tell whether something "changed", not for security. */
function contentDigest(text: string): string {
  let hash = 0x811c9dc5;
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193);
  }
  return `${text.length}:${(hash >>> 0).toString(16)}`;
}

export function chatContinuationFingerprintOf(
  plan: ContextPlan,
  wireModelId: string,
  assembly: ChatContextAssembly,
): ChatContinuationFingerprint {
  return {
    system: contentDigest(plan.system ?? ''),
    model: wireModelId,
    checkpoint: contentDigest(assembly.checkpointText ?? ''),
  };
}

/** Compares the fingerprint of this leg with the leg that produced the continuation state; when the previous leg's fingerprint is unavailable, all three items count as "changed". */
export function compareChatContinuationFingerprint(
  previous: ChatContinuationFingerprint | undefined,
  current: ChatContinuationFingerprint,
): ContinuationFingerprint {
  if (!previous) return { systemChanged: true, modelChanged: true, checkpointChanged: true };
  return {
    systemChanged: previous.system !== current.system,
    modelChanged: previous.model !== current.model,
    checkpointChanged: previous.checkpoint !== current.checkpoint,
  };
}

/** Delivery facts of this attempt that stream-runner attaches to the failure error (non-enumerable). */
interface ChatContextAttempt {
  imageOutputStarted?: boolean;
  relayTransport?: StreamOptions['relayTransport'];
  relayDriverModelID?: string;
}

function contextAttemptOf(error: unknown): ChatContextAttempt | undefined {
  if (!error || typeof error !== 'object') return undefined;
  const attempt = (error as { contextAttempt?: unknown }).contextAttempt;
  return attempt && typeof attempt === 'object' ? attempt as ChatContextAttempt : undefined;
}

/** The relay protocol actually delivered by the failed attempt (differs from the requested one after a first-send protocol switch / protocol-level fallback); falls back to the requested one when nothing was delivered. */
export function failedRelayTransportOf(
  error: unknown,
  requested: StreamOptions['relayTransport'],
): StreamOptions['relayTransport'] {
  return contextAttemptOf(error)?.relayTransport ?? requested;
}

/** The model id sent on the wire by the failed attempt. */
export function failedWireModelIdOf(error: unknown, model: AIModel, requested: StreamOptions | undefined): string {
  const attempt = contextAttemptOf(error);
  return attempt?.relayDriverModelID || chatWireModelIdOf(model, requested);
}

/**
 * Protocol family of this request: the family of the finish the stream delivered if any, otherwise the wire protocol actually delivered (the connection kind when there is none).
 */
export function chatStopFamilyOf(
  finish: { family?: unknown } | undefined,
  kind: ProviderKind,
  relayTransport: StreamOptions['relayTransport'],
): StopFamily {
  return typeof finish?.family === 'string' ? finish.family as StopFamily : stopFamilyForRequest(kind, relayTransport);
}

/** Protocol family of the failed request: taken from the finish on the error when present, otherwise from the wire protocol actually delivered. */
export function failedStopFamilyOf(error: unknown, kind: ProviderKind, requested: StreamOptions['relayTransport']): StopFamily {
  const finish = error && typeof error === 'object' ? (error as { finish?: { family?: unknown } }).finish : undefined;
  return chatStopFamilyOf(finish, kind, failedRelayTransportOf(error, requested));
}

/**
 * Whether a send failure is a context overflow: classify(this family, httpStatus, rawBody) with empty extraPatterns.
 * An in-stream error frame has no HTTP status, so 200 is assumed and only the error code is recognized.
 */
export function isContextOverflowFailure(
  error: unknown,
  kind: ProviderKind,
  relayTransport?: StreamOptions['relayTransport'],
): boolean {
  if (!error || typeof error !== 'object') return false;
  const record = error as { httpStatus?: unknown; rawBody?: unknown; streamErrorFrame?: unknown };
  if (typeof record.rawBody !== 'string') return false;
  const status = typeof record.httpStatus === 'number' ? record.httpStatus : record.streamErrorFrame === true ? 200 : null;
  if (status === null) return false;
  return ContextOverflowClassifier.classify(overflowFamilyOf(failedStopFamilyOf(error, kind, relayTransport)), status, record.rawBody, {}).overflow;
}

/** Stop-reason family -> overflow-recognition family: Interactions error bodies have the same shape as generateContent, and llama.cpp is recognized by the OpenAI-compatible error body. */
function overflowFamilyOf(family: StopFamily): OverflowFamily {
  switch (family) {
    case 'gemini_interactions':
      return 'gemini';
    case 'llama_cpp':
      return 'openai_compatible';
    default:
      return family;
  }
}

/** Whether this attempt already produced body text / reasoning (the outputStarted that stream-runner attaches to the error). */
export function failureOutputStarted(error: unknown): boolean {
  return Boolean(error && typeof error === 'object' && (error as { outputStarted?: unknown }).outputStarted === true);
}

/** "Output started" for overflow recovery: any of body, thinking or image deltas. */
export function failureAnyOutputStarted(error: unknown): boolean {
  return failureOutputStarted(error) || contextAttemptOf(error)?.imageOutputStarted === true;
}

/** Observed input tokens: taken from the in-stream usage; undefined when missing. */
export function observedChatInputOf(usage: StreamUsage | undefined): number | undefined {
  const value = usage?.prompt_tokens ?? usage?.messageUsage?.inputTokens;
  return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : undefined;
}

/** UTF-8 byte count of the outbound history text; null when there are non-text parts (images / files). */
function requestTextBytes(history: ReadonlyArray<{ content: string | ContentPart[] }>): number | null {
  let bytes = 0;
  for (const message of history) {
    if (typeof message.content === 'string') {
      bytes += ContextBudget.utf8Bytes(message.content);
      continue;
    }
    for (const part of message.content) {
      if (part.type !== 'text') return null;
      bytes += ContextBudget.utf8Bytes(part.text);
    }
  }
  return bytes;
}

/** After a successful finish, a text-only request with usage writes one rho sample; requests with image / file attachments are not recorded. A Ledger read or write failure does not affect sending. */
export async function recordChatRhoSample(input: {
  provider: Provider;
  /** Model id sent on the wire (rho key). */
  wireModelId: string;
  plan: ContextPlan;
  history: ReadonlyArray<{ content: string | ContentPart[] }>;
  observedInput: number | undefined;
}): Promise<void> {
  if (input.observedInput === undefined) return;
  if ((input.plan.messages ?? []).some((message) => message.attachments.length > 0)) return;
  const textBytes = requestTextBytes(input.history);
  if (textBytes === null || textBytes <= 0) return;
  const key = contextTransportIdOf(input.provider);
  try {
    const next = (await getRhoCalibration(key, input.wireModelId)).recordingSample(input.observedInput, 0, textBytes);
    await putRhoCalibration(key, input.wireModelId, next);
  } catch {
    // Ledger unavailable: no calibration this time.
  }
}

/** Predicted P̂ < U but it overflowed: rho is raised by overflowMissFactor and written back. Not recorded when the window is unknown. */
export async function recordChatOverflowMiss(input: {
  provider: Provider;
  model: AIModel;
  /** Model id sent on the wire (rho key). */
  wireModelId: string;
  plan: ContextPlan;
  userMaxOutput: number | null;
}): Promise<void> {
  const pHat = input.plan.budget.estimatedInput;
  if (pHat === null || input.plan.budget.W === null) return;
  const U = chatWindowBudgetOf(input.provider, input.model, input.userMaxOutput).U;
  if (U === null || pHat >= U) return;
  const key = contextTransportIdOf(input.provider);
  try {
    const next = (await getRhoCalibration(key, input.wireModelId)).recordingOverflowMiss();
    await putRhoCalibration(key, input.wireModelId, next);
  } catch {
    // Ledger unavailable: no write-back this time.
  }
}

let lastManifestAt = 0;

/** One manifest per chat request (createdAt strictly increases, so resends within the same millisecond keep their order). A write failure does not affect sending. */
export async function appendChatManifest(input: {
  conversationId: string;
  provider: Provider;
  model: AIModel;
  /** Model id sent on the wire (manifest.model). */
  wireModelId: string;
  /** This attempt's StopFamily (manifest.transport). */
  family: StopFamily;
  plan: ContextPlan;
  userMaxOutput: number | null;
  tailFrom?: string;
  /** The library row checkpointId applied to this request; not passed for the in-memory fallback / overflow reprojection. */
  checkpointId?: string;
  stopReason: StopReason;
  observedInput?: number;
}): Promise<void> {
  const { plan } = input;
  lastManifestAt = Math.max(Date.now(), lastManifestAt + 1);
  const manifest: ContextManifest = {
    requestId: createCanonicalUUID(),
    conversationId: input.conversationId,
    purpose: plan.purpose,
    transport: input.family,
    model: input.wireModelId,
    W: plan.budget.W,
    O: chatWindowBudgetOf(input.provider, input.model, input.userMaxOutput).O,
    B: plan.budget.B,
    // observed has a value; otherwise an estimate -> estimated; neither -> unknown.
    basis: input.observedInput !== undefined
      ? 'observed'
      : plan.budget.estimatedInput !== null ? 'estimated' : 'unknown',
    estimatedInput: plan.budget.estimatedInput ?? 0,
    ...(input.observedInput !== undefined ? { observedInput: input.observedInput } : {}),
    segments: plan.segments,
    ...(input.tailFrom ? { tailFrom: input.tailFrom } : {}),
    ...(input.checkpointId ? { checkpointId: input.checkpointId } : {}),
    unansweredMerged: plan.unansweredMerged,
    reminder: plan.reminder,
    stopReason: input.stopReason,
    createdAt: lastManifestAt,
  };
  try {
    await appendContextManifest(manifest);
  } catch {
    // Ledger unavailable: nothing recorded this time.
  }
}
