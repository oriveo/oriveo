/**
 * Sample data for the context page family: every value comes from the shared manifest `shared/test-fixtures/shots/context.v1.json` (the entry reads it and passes it in as a parameter).
 * Capability figures (window / output cap / price line / price) come only from the manifest `models[].entry`, decoded by production metadata (initMetadata takes the
 * lean full-bundle path) into the cache; B is computed by production windowOf -> ContextBudget.window; checkpoints are built through production serialization,
 * ledger rows are written into the fenced in-memory database in the production ContextManifest shape; the suggestion bar uses the production singleton.
 * Only imported dynamically from the dev branch; never touches the real database or the network (metadata requests are answered locally by this module).
 */
import type { StoreApi } from 'zustand';
import { PROVIDER_KINDS, type AIModel, type AppPreference, type ChatMessage, type Conversation, type LastUsedModelRef, type Provider, type ProviderKind } from '@oriveo/shared';
import { ContextBudget, type BudgetCapOption } from '@oriveo/core/context/budget';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import type { ContextManifest, ContextManifestSegment } from '@oriveo/core/context/manifest';
import type { StopReason } from '@oriveo/core/context/stop-reason';
import { memoryIntentFingerprint, type MemoryCandidateRecord } from '@oriveo/core/context/memory-intent';
import { MEMORY_INTENT_CANDIDATE_TTL_MS } from '@oriveo/core/context/memory-intent-lexicon';
import type { AppStore } from '../../../lib/core/store/app-store';
import type { ContextCheckpointRow } from '../../../lib/infra/storage/context-checkpoint-store';
import { appendContextManifest } from '../../../lib/infra/storage/context-ledger-store';
import { initMetadata, resolveMetadataBackendURL } from '../../../lib/core/metadata/metadata-client';
import { ContextCompactionStore } from '../../../lib/core/chat/context-compaction/context-compaction-store';
import { noteCompactionSaved } from '../../../lib/core/chat/context-compaction/context-compaction-actions';
import { displayRhoHiOf, windowOf } from '../../../lib/core/chat/context-pipeline/chat-context';
import { currentUsageBudgetOf } from '../../../lib/core/chat/context-visibility/use-context-usage';
import { resolveContextDefaultCap } from '../../../lib/core/context-cap-preferences';
import { gateCapConfirm, CapConfirmCancelledError } from '../../../lib/core/chat/context-visibility/cap-confirm-gate';
import { capConfirmStateKey, type CapConfirmAttempt, type CapConfirmState } from '../../../lib/core/chat/context-visibility/cap-confirm';
import { setPreference } from '../../../lib/infra/storage/preferences';
import { stopFamilyForProvider } from '../../../lib/core/chat/stop-reason-outcome';
import { offerDirectiveSuggestion } from '../../../lib/core/chat/conversation-instructions/directive-suggestion';
import { beginMemorySuggestion, resolveMemorySuggestion } from '../../../lib/core/chat/conversation-instructions/memory-suggestion';
import type { ContextShotPage } from './context-shots-pages';
import type { ContextShotsModelEntry, ContextShotsModel, ContextShotsCheckpoint, ContextShotsLedger, ContextShotsManifestPage, ContextShotsManifest } from './context-shots-manifest';

export type { ContextShotsModelEntry, ContextShotsModel, ContextShotsCheckpoint, ContextShotsLedger, ContextShotsManifestPage, ContextShotsManifest } from './context-shots-manifest';
export { isCompleteContextShotsManifest } from './context-shots-manifest';

/** The manifest `models[].provider` is already the Server provider key (= this client's ProviderKind); an invalid kind refuses to open (no guessing). */
export function contextShotProviderKind(provider: string): ProviderKind {
  if (!(PROVIDER_KINDS as readonly string[]).includes(provider)) {
    throw new Error(`[context-shots] unknown fixture provider ${provider}`);
  }
  return provider as ProviderKind;
}

/* -- metadata: manifest model entries answered as a lean full bundle and handed to production initMetadata to decode -- */

/** Lean metadata body containing only the manifest models (Server /api/metadata shape). */
export function contextShotsMetadataPayload(manifest: ContextShotsManifest): Record<string, unknown> {
  const providers: Record<string, { models: Record<string, ContextShotsModelEntry> }> = {};
  for (const model of manifest.models) {
    const kind = contextShotProviderKind(model.provider);
    providers[kind] ??= { models: {} };
    providers[kind].models[model.entry.id] = model.entry;
  }
  return {
    version: 1,
    view: 'lean',
    updatedAt: manifest.clock,
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers,
  };
}

/**
 * Metadata requests are answered locally: the index view returns 400 (production falls back to the lean full bundle as against an old server), lean returns the manifest body,
 * other metadata paths return 404; non-metadata requests return null and pass to the layer below (the fence).
 */
export function contextShotsMetadataResponse(url: URL, manifest: ContextShotsManifest): Response | null {
  let origin: string | null = null;
  try {
    origin = new URL(resolveMetadataBackendURL()).origin;
  } catch {
    origin = null;
  }
  if (url.origin !== origin || !url.pathname.startsWith('/api/metadata')) return null;
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  if (url.pathname !== '/api/metadata') return json(404, { message: 'not available in context shots' });
  if (url.searchParams.get('view') === 'index') return json(400, { message: 'index view not served in context shots' });
  return json(200, contextShotsMetadataPayload(manifest));
}

/** Take over metadata requests on top of the current fetch (the fence) and let production initMetadata decode into the cache. Returns the teardown function. */
export async function loadContextShotsMetadata(manifest: ContextShotsManifest): Promise<() => void> {
  const lower = globalThis.fetch;
  const fetchWithMetadata: typeof fetch = async (input, init) => {
    const base = typeof window === 'undefined' ? 'http://localhost/' : window.location.href;
    const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    const local = contextShotsMetadataResponse(new URL(raw, base), manifest);
    return local ?? lower(input, init);
  };
  globalThis.fetch = fetchWithMetadata;
  await initMetadata();
  return () => {
    if (globalThis.fetch === fetchWithMetadata) globalThis.fetch = lower;
  };
}

/* -- plan -- */

export interface ContextShotPlan {
  page: ContextShotPage;
  /** chat = the production conversation page; settings = the settings page (empty page for card 1). */
  target: 'chat' | 'settings';
  /** The open conversation; null = a new empty conversation (or the settings page). */
  conversationId: string | null;
  providers: Provider[];
  conversation: Conversation | null;
  lastUsedModelRef: LastUsedModelRef | null;
  preferences: Partial<AppPreference>;
  /** Connection and model for this page (null for the settings page). */
  provider: Provider | null;
  model: AIModel | null;
  checkpoint: { kind: 'summary' | 'fallback'; source: ContextShotsCheckpoint; count: number } | null;
  ledger: ContextShotsLedger | null;
  directive: { message: ChatMessage; assistantId: string } | null;
  memory: { userId: string; assistantId: string; candidate: MemoryCandidateRecord } | null;
  /** After entering the page, tap open the divider detail (open = detail). */
  openDetail: boolean;
  /** Layer stacked over the conversation page after entering (the settings page goes through target instead). */
  open: 'panel' | 'picker' | 'detail' | 'conversationSettings' | 'confirm' | null;
  /** open = confirm: the pre-send input handed to production gateCapConfirm. */
  confirm: { attempt: CapConfirmAttempt; estimatedInput: number; conversationState: CapConfirmState } | null;
  clockMs: number;
}

function shotModel(entry: ContextShotsModelEntry): AIModel {
  // Window / output cap / price are not copied into the connection: production windowOf falls back to the metadata catalog (resolveCatalogModel).
  return {
    id: entry.id,
    name: entry.displayName,
    capabilities: [],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '',
  };
}

function shotProvider(model: ContextShotsModel): Provider {
  const aiModel = shotModel(model.entry);
  return {
    id: `shots-${model.ref}`,
    kind: contextShotProviderKind(model.provider),
    status: { kind: 'connected' },
    models: [aiModel],
    catalogModels: [aiModel],
    apiKey: 'shots-demo-key',
    apiKeyPreview: '••••',
  };
}

/**
 * Fixture message id -> deterministic UUID (production message ids are 36-char UUIDs; checkpoint text
 * embeds kept ids, so short ids would skew token counts). Same formula as Android / iOS:
 * `c0de0000-0000-4000-8000-` + UTF-8 bytes of the fixture id as hex, left-padded to 12 digits.
 */
export function contextShotMessageId(fixtureId: string): string {
  const hex = Array.from(new TextEncoder().encode(fixtureId), (b) => b.toString(16).padStart(2, '0')).join('');
  if (hex.length === 0 || hex.length > 12) throw new Error(`[context-shots] fixture message id ${fixtureId} does not fit a UUID tail`);
  return `c0de0000-0000-4000-8000-${hex.padStart(12, '0')}`;
}

function shotMessage(
  message: { id: string; createdAt: string; role: 'user' | 'assistant'; content: string },
  provider: Provider,
  model: AIModel,
): ChatMessage {
  return {
    id: contextShotMessageId(message.id),
    role: message.role,
    text: message.content,
    createdAt: message.createdAt,
    providerID: provider.id,
    providerKind: provider.kind,
    providerName: provider.kind,
    modelID: model.id,
    modelName: model.name,
    estimatedCost: 0,
    state: 'delivered',
  };
}

function ledgerOf(manifest: ContextShotsManifest, key: string | undefined): ContextShotsLedger | null {
  if (key === undefined) return null;
  const ledger = manifest.manifests[key];
  if (typeof ledger !== 'object' || ledger === null) throw new Error(`[context-shots] manifest has no ledger ${key}`);
  return ledger;
}

export function contextShotPlan(page: ContextShotPage, manifest: ContextShotsManifest): ContextShotPlan {
  const entry = manifest.pages.find((p) => p.name === page);
  if (!entry) throw new Error(`[context-shots] manifest has no page ${page}`);
  const providers = manifest.models.map(shotProvider);
  const clockMs = Date.parse(manifest.clock);
  // Sample pages do not show the first-time "save as note" prompt: its toast would cover the top bar; the production path is untouched.
  const preferences: Partial<AppPreference> = { hasSeenNoteCaptureHint: true };
  if (entry.preferences?.aiSummary !== undefined) preferences.contextAISummaryEnabled = entry.preferences.aiSummary;
  if (entry.preferences?.defaultCap !== undefined) preferences.contextDefaultCap = entry.preferences.defaultCap;
  if (entry.preferences?.priceLineReminder !== undefined) {
    preferences.contextPriceLineReminderEnabled = entry.preferences.priceLineReminder;
  }
  const base = {
    page,
    providers,
    preferences,
    clockMs,
    checkpoint: null,
    ledger: null,
    directive: null,
    memory: null,
    openDetail: false,
    open: null,
    confirm: null,
  };
  if (entry.open === 'settings' || entry.model === undefined) {
    return { ...base, target: 'settings', conversationId: null, conversation: null, lastUsedModelRef: null, provider: null, model: null };
  }
  const index = manifest.models.findIndex((m) => m.ref === entry.model);
  if (index < 0) throw new Error(`[context-shots] manifest has no model ${entry.model}`);
  const provider = providers[index]!;
  const model = provider.models[0]!;
  const lastUsedModelRef = { providerID: provider.id, modelID: model.id };
  if (entry.messages === 'none') {
    return { ...base, target: 'chat', conversationId: null, conversation: null, lastUsedModelRef, provider, model };
  }

  const source = manifest.conversation;
  const messages = source.messages.map((m) => shotMessage(m, provider, model));
  if (entry.lastAssistantStopReason !== undefined) {
    // Manifest $pages: lastAssistantStopReason lands on a6 (by id, not by position).
    const target = messages.find((m) => m.id === contextShotMessageId('a6'));
    if (!target) throw new Error('[context-shots] manifest conversation has no a6');
    target.stopReason = entry.lastAssistantStopReason as StopReason;
  }
  let directive: ContextShotPlan['directive'] = null;
  let memory: ContextShotPlan['memory'] = null;
  const extra = entry.directiveSuggestion ?? entry.memorySuggestion;
  if (extra) {
    // The appended assistant reply comes 30 seconds after the user message (manifest $pages).
    const replyAt = new Date(Date.parse(extra.createdAt) + 30_000).toISOString();
    const userId = contextShotMessageId(extra.userId);
    const assistantId = contextShotMessageId(extra.assistantId);
    const user = shotMessage({ id: extra.userId, createdAt: extra.createdAt, role: 'user', content: extra.user }, provider, model);
    messages.push(
      user,
      shotMessage({ id: extra.assistantId, createdAt: replyAt, role: 'assistant', content: extra.assistant }, provider, model),
    );
    if (entry.directiveSuggestion) directive = { message: user, assistantId };
    if (entry.memorySuggestion) {
      const c = entry.memorySuggestion.candidate;
      memory = {
        userId,
        assistantId,
        candidate: {
          id: c.id,
          status: 'pending',
          proposedLayer: c.proposedLayer,
          proposedKind: c.proposedKind,
          content: c.content,
          scope: { type: 'global', id: null },
          source: { type: 'conversation', conversationId: source.id, messageIds: [userId], observedAtMs: clockMs },
          sensitivity: 'normal',
          confidence: c.confidence,
          fingerprint: memoryIntentFingerprint(c.content),
          createdAtMs: clockMs,
          expiresAtMs: clockMs + MEMORY_INTENT_CANDIDATE_TTL_MS,
          resolvedAtMs: null,
        },
      };
    }
  }
  const last = messages[messages.length - 1];
  const conversation: Conversation = {
    id: source.id,
    title: source.title,
    hasCustomTitle: true,
    providerID: provider.id,
    modelID: model.id,
    providerKind: provider.kind,
    previewText: last?.text ?? '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt: manifest.clock,
    createdAt: source.createdAt,
    ...(entry.instructions !== undefined ? { instructions: entry.instructions } : {}),
    ...(entry.conversationCap !== undefined && entry.conversationCap !== null ? { contextCap: entry.conversationCap } : {}),
  };
  let checkpoint: ContextShotPlan['checkpoint'] = null;
  if (entry.checkpoint) {
    const cp = manifest.checkpoints[entry.checkpoint];
    if (!cp) throw new Error(`[context-shots] manifest has no checkpoint ${entry.checkpoint}`);
    const covers = { ...cp, coversFrom: contextShotMessageId(cp.coversFrom), coversTo: contextShotMessageId(cp.coversTo) };
    checkpoint = { kind: entry.checkpoint, source: covers, count: entry.compactionCount ?? 1 };
  }
  return {
    ...base,
    target: 'chat',
    conversationId: source.id,
    conversation,
    lastUsedModelRef,
    provider,
    model,
    checkpoint,
    ledger: ledgerOf(manifest, entry.manifest),
    directive,
    memory,
    openDetail: entry.open === 'detail',
    open: entry.open ?? null,
    confirm: confirmOf(entry),
  };
}

function confirmOf(entry: ContextShotsManifestPage): ContextShotPlan['confirm'] {
  if (entry.open !== 'confirm') return null;
  const confirm = entry.confirm;
  if (!confirm) throw new Error(`[context-shots] confirm page ${entry.name} has no confirm input`);
  return { attempt: confirm.attempt, estimatedInput: confirm.estimatedInput, conversationState: confirm.conversationState };
}

/* -- persistence (fenced in-memory database) and suggestion bar -- */

/** B for this page's conversation at the current tier (production currentUsageBudgetOf: windowOf + ContextBudget.window). */
function capOf(plan: ContextShotPlan): BudgetCapOption {
  return plan.conversation?.contextCap ?? resolveContextDefaultCap(plan.preferences);
}

/**
 * Build checkpoint rows through production serialization: the newest one follows the manifest (coversFrom..coversTo); when compactionCount > 1,
 * also add rows covering earlier assistant messages (same createdAt; production resolveConcurrency picks the newest by coversTo).
 */
export async function contextShotCheckpointRows(plan: ContextShotPlan): Promise<ContextCheckpointRow[]> {
  const { checkpoint, conversation, provider, model } = plan;
  if (!checkpoint || !conversation || !provider || !model) return [];
  const B = currentUsageBudgetOf(provider, model.id, conversation.id, capOf(plan));
  if (B === null || B === undefined) throw new Error('[context-shots] checkpoint page needs a known window');
  const rhoHi = await displayRhoHiOf(provider, model.id);
  const messages = conversation.messages;
  const targetIndex = messages.findIndex((m) => m.id === checkpoint.source.coversTo);
  if (targetIndex < 0) throw new Error(`[context-shots] checkpoint covers unknown ${checkpoint.source.coversTo}`);
  const earlier = messages.slice(0, targetIndex).filter((m) => m.role === 'assistant').reverse();
  const coversToIndexes = [targetIndex, ...earlier.slice(0, checkpoint.count - 1).map((m) => messages.indexOf(m))];
  if (coversToIndexes.length !== checkpoint.count) throw new Error('[context-shots] not enough messages for compactionCount');
  const packerVersion = ContextCheckpoint.constants.packerVersion;
  const createdAt = Date.parse(checkpoint.source.createdAt);
  const summary = checkpoint.kind === 'summary' ? checkpoint.source.summary ?? null : null;
  return coversToIndexes.map((index) => {
    const covered = messages.slice(0, index + 1);
    const coversFrom = checkpoint.source.coversFrom;
    const coversTo = covered[covered.length - 1]!.id;
    const kept = ContextCheckpoint.pickUserMessages(
      covered.filter((m) => m.role === 'user').map((m) => ({ id: m.id, text: m.text })),
      B,
      rhoHi,
    );
    return {
      conversationId: conversation.id,
      checkpointId: ContextCheckpoint.checkpointId(conversation.id, coversTo, packerVersion),
      kind: checkpoint.kind,
      coversFrom,
      coversTo,
      coversDigest: ContextCheckpoint.coversDigest(covered.map((m) => ({ id: m.id, text: m.text }))),
      messagesCovered: covered.length,
      userMessageIds: kept.map((m) => m.id),
      text: ContextCheckpoint.serialize(coversFrom, coversTo, covered.length, kept, summary),
      summary,
      language: null,
      model: model.id,
      packerVersion,
      createdAt,
      cost: null,
    };
  });
}

/**
 * Ledger row: manifest values in the production ContextManifest shape, written 1 minute before the clock, matching the last assistant message.
 * requestId is fixed per conversation: when several pages are applied in turn on the same in-memory database, the later page overwrites the earlier one instead of stacking rows at the same moment.
 */
export function contextShotLedgerRow(plan: ContextShotPlan, checkpointId: string | null): ContextManifest | null {
  const { ledger, conversation, provider, model } = plan;
  if (!ledger || !conversation || !provider || !model) return null;
  const budget = ContextBudget.window(windowOf(provider, model, null, capOf(plan)));
  return {
    requestId: `shots-${conversation.id}`,
    conversationId: conversation.id,
    purpose: 'chat',
    transport: stopFamilyForProvider(provider.kind),
    model: model.id,
    W: ledger.W,
    O: budget.O,
    B: ledger.B,
    basis: ledger.observedInput !== undefined ? 'observed' : 'estimated',
    estimatedInput: ledger.estimatedInput,
    ...(ledger.observedInput !== undefined ? { observedInput: ledger.observedInput } : {}),
    segments: ledger.segments as ContextManifestSegment[],
    ...(checkpointId ? { checkpointId } : {}),
    unansweredMerged: 0,
    reminder: false,
    stopReason: ledger.stopReason as StopReason,
    createdAt: plan.clockMs - 60_000,
  };
}

/** Write into the in-memory store and the fenced in-memory database, then raise the prompt / suggestion bar through the production path; never touches the real database. Must be called after metadata is in the cache. */
export async function applyContextShotPlan(plan: ContextShotPlan, store: StoreApi<AppStore>): Promise<void> {
  const state = store.getState();
  store.setState({
    providers: plan.providers,
    conversations: plan.conversation ? [plan.conversation] : [],
    preferences: { ...state.preferences, ...plan.preferences },
    lastUsedModelRef: plan.lastUsedModelRef,
  });
  const rows = await contextShotCheckpointRows(plan);
  for (const row of rows) await ContextCompactionStore.put(row);
  if (plan.conversationId && rows.length > 0) noteCompactionSaved(plan.conversationId, rows.length);
  const ledger = contextShotLedgerRow(plan, rows[0]?.checkpointId ?? null);
  if (ledger) await appendContextManifest(ledger);
  if (plan.conversationId && plan.directive) {
    offerDirectiveSuggestion(store, plan.conversationId, plan.directive.message, plan.directive.assistantId, 'tool');
  }
  if (plan.conversationId && plan.memory) {
    const ticket = beginMemorySuggestion(plan.conversationId, plan.memory.userId, plan.memory.assistantId);
    resolveMemorySuggestion(store, ticket, plan.memory.candidate);
  }
}

/**
 * open = confirm: following the production send-path gate (gateCapConfirm), decide using the window at this page's conversation tier and the manifest P-hat,
 * suspend through production requestCapConfirmation so the confirm dialog shows it (kind / cost are all computed by production).
 * It stays suspended until the user answers or the signal aborts; nothing is sent after an answer / abort.
 */
export async function raiseContextShotConfirm(plan: ContextShotPlan, store: StoreApi<AppStore>, signal: AbortSignal): Promise<void> {
  const { confirm, conversation, provider, model } = plan;
  if (!confirm || !conversation || !provider || !model) return;
  // The manifest's conversation-confirm state is written as-is into production local state (fenced in-memory storage), read back by production capConfirmInputOf.
  setPreference(capConfirmStateKey(conversation.id), confirm.conversationState);
  try {
    await gateCapConfirm({
      store,
      conversationId: conversation.id,
      provider,
      model,
      attempt: confirm.attempt,
      window: windowOf(provider, model, null, capOf(plan)),
      estimatedInput: confirm.estimatedInput,
      signal,
    });
  } catch (error) {
    if (!(error instanceof CapConfirmCancelledError)) throw error;
  }
}
