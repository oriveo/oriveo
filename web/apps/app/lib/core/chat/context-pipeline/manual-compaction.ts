import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import { tryGetVanillaStore } from '../../../../providers/StoreProvider';
import { withoutUnreceivableImages } from '../attachment-policy';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../stream-options';
import {
  applyCheckpointRowAssembly,
  assembleChatPlan,
  chatCompactionContextOf,
  chatUserMaxOutputFor,
  latestValidChatCheckpoint,
  prepareChatContextAssembly,
  requestCompactionSummary,
} from './chat-context';
import { ContextBudget } from '@oriveo/core/context/budget';
import { isRuntimeFeatureEnabled } from '../../metadata/metadata-client';
import {
  CONTEXT_COMPACTION_FEATURE_KEY,
  CompactionBreakers,
  createCompactionCoordinator,
  isAICompacting,
  type CompactionResult,
} from './compaction-coordinator';

/*
 * Manual compaction entry: trigger=manual, always an AI summary (ignoring the preference and the breaker),
 * falling back to the deterministic fallback only when the feature switch is off. The conversation snapshot and system are taken from a chat plan built on the same basis as runChatOutbound (with the library row applied).
 * Returns the coordinator result unchanged; returns noop (never throws) when there is no conversation or no model.
 */

const noop = (): CompactionResult => ({ outcome: 'noop', failures: [] });

function modelOf(provider: Provider, modelId: string): AIModel | undefined {
  return provider.models.find((m) => m.id === modelId) ?? provider.catalogModels?.find((m) => m.id === modelId);
}

/** Images, videos and files that keep their original bytes (usable as native file blocks) count as media; files the client already extracted to text do not. */
function carriesMedia(message: ChatMessage): boolean {
  return (message.attachments ?? []).some((attachment) => attachment.kind === 'image'
    || attachment.kind === 'video'
    || (attachment.kind === 'file' && Boolean(attachment.originalBase64Data)));
}

/**
 * Conversation snapshot on the same basis as runChatOutbound: the chat plan has applied the newest library row for the current history.
 * `firstMediaId`: the first message carrying media, found on the original conversation (before images are stripped); manual compaction
 * only covers the history before it, and that message and everything after it stay as-is after the compaction result and are
 * stripped by projection at outbound time.
 */
async function conversationSnapshot(conversationId: string) {
  const store = tryGetVanillaStore();
  if (!store) return null;
  const state = store.getState();
  const conversation = state.conversations.find((c) => c.id === conversationId);
  if (!conversation || conversation.messages.length === 0) return null;
  const provider = state.providers.find((p) => p.id === conversation.providerID);
  const model = provider ? modelOf(provider, conversation.modelID) : undefined;
  if (!provider || !model) return null;

  // Same basis as runChatOutbound: attachments filtered by the current model's capabilities, window taken from the panel max output.
  const firstMediaId = conversation.messages.find(carriesMedia)?.id ?? null;
  const scopeOptions = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model);
  const messages: ChatMessage[] = withoutUnreceivableImages(conversation.messages, provider, model, scopeOptions);
  const latestUserText = [...messages].reverse().find((m) => m.role === 'user')?.text ?? '';
  const assembly = await prepareChatContextAssembly({
    store, conversation, conversationId, provider, model, messages, latestUserText,
  });
  // Same resolution chain as the pre-send check: a dormant (invalid) max output does not enter the window.
  const userMaxOutput = chatUserMaxOutputFor({ provider, model, conversationId, reasoningMode: 'automatic' });
  const planOptions = { provider, model, userMaxOutput };
  let plan = assembleChatPlan(assembly, planOptions);
  // First apply the newest library row for the current history; system and budget are taken from the plan after applying it.
  const stored = await latestValidChatCheckpoint(conversationId, assembly);
  const applied = stored ? applyCheckpointRowAssembly(assembly, stored) : null;
  if (applied) plan = assembleChatPlan(applied, planOptions);
  return { assembly, plan, provider, model, userMaxOutput, stored: applied ? stored : null, firstMediaId };
}

type ConversationSnapshot = NonNullable<Awaited<ReturnType<typeof conversationSnapshot>>>;

function coordinatorOf(snapshot: ConversationSnapshot, options: { retainMedia?: boolean } = {}) {
  const { assembly, plan, provider, model, userMaxOutput, firstMediaId } = snapshot;
  return createCompactionCoordinator({
    context: () => {
      const ctx = chatCompactionContextOf(assembly, plan, { provider, model, userMaxOutput });
      if (!ctx || !options.retainMedia || firstMediaId === null) return ctx;
      const mediaIndex = ctx.messages.findIndex((message) => message.id === firstMediaId);
      return mediaIndex < 0 ? ctx : { ...ctx, messages: ctx.messages.slice(0, mediaIndex) };
    },
    summarize: (req, signal) => requestCompactionSummary({
      provider, model, req, chatSystem: plan.system, instructions: assembly.input.conversation.instructions ?? '', signal,
    }),
  });
}

export async function compactConversationNow(conversationId: string): Promise<CompactionResult> {
  const snapshot = await conversationSnapshot(conversationId);
  if (!snapshot) return noop();
  return coordinatorOf(snapshot, { retainMedia: true }).compact(conversationId, 'manual');
}

/*
 * Pre-compaction: called when the composer is focused or on first input.
 * Runs compact('preSend') in the background only in AI mode (preference on, feature switch on, breaker llm), when this conversation has no compaction in progress,
 * and P̂ (fixed part of the prefix and the current message + history after applying the newest library row) >= 0.75·B.
 * A failure or cancel returns noop and saves no fallback row (the breaker is still counted by the coordinator); it never throws and shows no hint.
 */
const precompacting = new Set<string>();

function aiModeOn(conversationId: string): boolean {
  if (tryGetVanillaStore()?.getState().preferences.contextAISummaryEnabled !== true) return false;
  if (!isRuntimeFeatureEnabled(CONTEXT_COMPACTION_FEATURE_KEY)) return false;
  return CompactionBreakers.mode(conversationId) === 'llm';
}

function precompactPHat(snapshot: ConversationSnapshot): { pHat: number; B: number } | null {
  const { assembly, plan, provider, model, userMaxOutput, stored } = snapshot;
  const ctx = chatCompactionContextOf(assembly, plan, { provider, model, userMaxOutput });
  if (!ctx) return null;
  let history = ctx.messages;
  let checkpointTokens = 0;
  if (stored) {
    const coversIndex = history.findIndex((m) => m.id === stored.coversTo);
    if (coversIndex >= 0) {
      history = history.slice(coversIndex + 1);
      checkpointTokens = ContextBudget.estimateMessage(stored.text, ctx.rhoHi);
    }
  }
  // fixedTokens already includes the prefix (system) and the current message.
  const pHat = ctx.fixedTokens + checkpointTokens + history.reduce((sum, m) => sum + m.estTokens, 0);
  return { pHat, B: ctx.B };
}

export async function precompactIfNeeded(conversationId: string): Promise<CompactionResult> {
  if (precompacting.has(conversationId) || isAICompacting(conversationId)) return noop();
  if (!aiModeOn(conversationId)) return noop();
  const state = tryGetVanillaStore()?.getState();
  const conversation = state?.conversations.find((c) => c.id === conversationId);
  const provider = state?.providers.find((p) => p.id === conversation?.providerID);
  if (!provider) return noop();

  precompacting.add(conversationId);
  try {
    const snapshot = await conversationSnapshot(conversationId);
    if (!snapshot) return noop();
    const estimate = precompactPHat(snapshot);
    if (!estimate || estimate.pHat < ContextBudget.derive(estimate.B).preCompactAt) return noop();
    if (isAICompacting(conversationId) || !aiModeOn(conversationId)) return noop();
    return await coordinatorOf(snapshot).compact(conversationId, 'preSend', { aiOnly: true });
  } catch (error) {
    console.error('[ContextCompaction] precompaction failed:', error);
    return noop();
  } finally {
    precompacting.delete(conversationId);
  }
}
