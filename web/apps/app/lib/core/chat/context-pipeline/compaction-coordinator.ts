import { ContextBudget } from '@oriveo/core/context/budget';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import {
  ContextCompactionBreaker,
  ContextCompactor,
  type BreakerMode,
  type CompactFailureReason,
  type CompactMessage,
  type SummaryRequest,
  type SummaryRequestAttachment,
} from '@oriveo/core/context/compactor';
import { trimWhiteSpace } from '@oriveo/core/context/white-space';
import { tryGetVanillaStore } from '../../../../providers/StoreProvider';
import {
  type ContextCheckpointRow,
  listContextCheckpoints,
} from '../../../infra/storage/context-checkpoint-store';
import { isRuntimeFeatureEnabled } from '../../metadata/metadata-client';
import { ContextCompactionStore } from '../context-compaction/context-compaction-store';
import { noteCompactionSaved } from '../context-compaction/context-compaction-actions';

/*
 * Compaction coordinator:
 * decide AI / fallback -> produce the checkpoint row -> save it to the database.
 * The summary call and the conversation context are injected as functions; the send-path wiring is not here.
 */

export const CONTEXT_COMPACTION_FEATURE_KEY = 'context_compaction_enabled';

export type CompactionTrigger = 'preSend' | 'overflow' | 'manual';
export type CompactionOutcome = 'noop' | 'summary' | 'fallback';

export interface CompactionHistoryMessage extends CompactMessage {
  attachments?: SummaryRequestAttachment[];
}

/** Conversation snapshot used by this compaction (supplied by the caller from this chat plan). */
export interface CompactionContext {
  /** All local messages of this conversation, oldest to newest. */
  messages: readonly CompactionHistoryMessage[];
  B: number;
  U: number;
  prefixTokens: number;
  rhoHi: number;
  fixedTokens: number;
  /** The current model, written to the row's model. */
  model: string;
}

export type ReadySummaryRequest = Exclude<SummaryRequest, { shape: 'tooLarge' }>;

export interface CompactionCoordinatorDeps {
  context(conversationId: string, trigger: CompactionTrigger): CompactionContext | null | Promise<CompactionContext | null>;
  /** One summary call; null or a throw counts as a call error. When the signal aborts the call should end as soon as possible. */
  summarize(req: ReadySummaryRequest, signal: AbortSignal): Promise<string | null>;
  /** Preference contextAISummaryEnabled; by default read from app-store, missing counts as false. */
  aiSummaryEnabled?: () => boolean;
  /** Feature switch; by default reads context_compaction_enabled (default true). */
  remoteEnabled?: () => boolean;
  now?: () => number;
}

export interface CompactionResult {
  outcome: CompactionOutcome;
  /** The row saved by this run; on noop, if it waited for another compaction of the same conversation whose saved row is already enough, that row is carried too (not newly saved). */
  row?: ContextCheckpointRow;
  /** Reasons each summary attempt of this run was unqualified (in call order). */
  failures: CompactFailureReason[][];
  /** The user cancelled or stopped this compaction (a manual compaction shows no hint because of it). */
  cancelled?: boolean;
}

export interface CompactOptions {
  /** Abort signal of this send: aborting = the whole send is cancelled, nothing is saved and no fallback runs. */
  signal?: AbortSignal;
  /** AI summary only (pre-compaction): when AI is not used, or AI fails or is cancelled, returns noop and saves no fallback row (the breaker still counts). */
  aiOnly?: boolean;
}

/* ── AI summary in progress (in-memory per conversation, only during the summary call) ── */

interface CompactingEntry {
  trigger: CompactionTrigger;
  /** The user clicked "Cancel": preSend/overflow continue with the fallback, manual saves nothing. */
  cancel: AbortController;
  /** Stop button / send aborted: the whole run is cancelled and nothing is saved. */
  stop: AbortController;
}

const aiCompacting = new Map<string, CompactingEntry>();
const compactingListeners = new Set<(conversationId: string) => void>();

function emitCompacting(conversationId: string): void {
  for (const listener of [...compactingListeners]) listener(conversationId);
}

/** Whether this conversation is waiting for an AI summary call. */
export function isAICompacting(conversationId: string): boolean {
  return aiCompacting.has(conversationId);
}

/** Subscribes to in-progress changes; the callback argument is the changed conversation id. Returns the unsubscribe function. */
export function subscribeAICompacting(listener: (conversationId: string) => void): () => void {
  compactingListeners.add(listener);
  return () => {
    compactingListeners.delete(listener);
  };
}

/** Composer "Cancel": aborts the in-progress AI summary of this conversation. */
export function cancelCompaction(conversationId: string): void {
  aiCompacting.get(conversationId)?.cancel.abort();
}

/** Stop button: aborts the compaction triggered by a send (preSend / overflow) for this conversation, saving nothing. */
export function stopCompaction(conversationId: string): void {
  const entry = aiCompacting.get(conversationId);
  if (entry && entry.trigger !== 'manual') entry.stop.abort();
}

/* ── Single flight: one compaction per conversation at a time (pre-compaction, send and manual all register) ── */

const inFlight = new Map<string, Promise<void>>();

/** Whether a compaction is running for this conversation (including the fallback and saving phases). */
export function isCompactionInFlight(conversationId: string): boolean {
  return inFlight.has(conversationId);
}

/** Returns a signal that aborts when either of two signals aborts; release detaches the listeners (AbortSignal.any is not used, for older browsers). */
function bridgeSignals(a: AbortSignal, b: AbortSignal): { signal: AbortSignal; release: () => void } {
  const controller = new AbortController();
  const onAbort = () => controller.abort();
  if (a.aborted || b.aborted) {
    controller.abort();
    return { signal: controller.signal, release: () => {} };
  }
  a.addEventListener('abort', onAbort, { once: true });
  b.addEventListener('abort', onAbort, { once: true });
  return {
    signal: controller.signal,
    release: () => {
      a.removeEventListener('abort', onAbort);
      b.removeEventListener('abort', onAbort);
    },
  };
}

/* ── Breaker: in-memory per conversation, not persisted ─────────────────────────── */

const breakers = new Map<string, ContextCompactionBreaker>();

function breakerOf(conversationId: string): ContextCompactionBreaker {
  return breakers.get(conversationId) ?? ContextCompactionBreaker.initial;
}

function applyBreaker(conversationId: string, event: Parameters<ContextCompactionBreaker['apply']>[0]): void {
  breakers.set(conversationId, breakerOf(conversationId).apply(event));
}

export const CompactionBreakers = {
  state: breakerOf,
  mode(conversationId: string): BreakerMode {
    return breakerOf(conversationId).mode;
  },
  /** Counts one turn per chat send. */
  recordTurn(conversationId: string): void {
    applyBreaker(conversationId, 'turn');
  },
  /** User retry: reset to zero. */
  retry(conversationId: string): void {
    applyBreaker(conversationId, 'retry');
  },
  reset(): void {
    breakers.clear();
  },
};

/* ── Default readers ─────────────────────────────────────────────── */

function defaultAISummaryEnabled(): boolean {
  return tryGetVanillaStore()?.getState().preferences.contextAISummaryEnabled === true;
}

function defaultRemoteEnabled(): boolean {
  return isRuntimeFeatureEnabled(CONTEXT_COMPACTION_FEATURE_KEY);
}

/* ── Coordinator ───────────────────────────────────────────────── */

export function createCompactionCoordinator(deps: CompactionCoordinatorDeps) {
  const aiSummaryEnabled = deps.aiSummaryEnabled ?? defaultAISummaryEnabled;
  const remoteEnabled = deps.remoteEnabled ?? defaultRemoteEnabled;
  const now = deps.now ?? Date.now;

  /** One summary call; returns null immediately on abort (the caller then checks the abort reason). */
  async function callSummary(req: ReadySummaryRequest, signal: AbortSignal): Promise<string | null> {
    if (signal.aborted) return null;
    let onAbort: () => void = () => {};
    const aborted = new Promise<null>((resolve) => {
      onAbort = () => resolve(null);
      signal.addEventListener('abort', onAbort, { once: true });
    });
    try {
      return await Promise.race([deps.summarize(req, signal), aborted]);
    } catch {
      return null;
    } finally {
      signal.removeEventListener('abort', onAbort);
    }
  }

  function useAI(conversationId: string, trigger: CompactionTrigger): boolean {
    if (!remoteEnabled()) return false;
    if (trigger === 'manual') return true;
    return aiSummaryEnabled() && breakerOf(conversationId).mode === 'llm';
  }

  /** Deterministic fallback row; returns null when there is no checkpointText. */
  function fallbackRow(
    conversationId: string,
    ctx: CompactionContext,
    previous: ContextCheckpointRow | null,
  ): ContextCheckpointRow | null {
    const { messages } = ctx;
    const result = ContextCheckpoint.fallback(messages, ctx.B, ctx.rhoHi, ctx.fixedTokens, previous?.summary ?? null);
    if (result.checkpointText === undefined) return null;
    const tailIndex = result.tailStartId === null ? messages.length : messages.findIndex((m) => m.id === result.tailStartId);
    const coversIndex = tailIndex - 1;
    if (coversIndex < 0) return null;
    const coversTo = messages[coversIndex].id;
    const packerVersion = ContextCheckpoint.constants.packerVersion;
    return {
      conversationId,
      checkpointId: ContextCheckpoint.checkpointId(conversationId, coversTo, packerVersion),
      kind: 'fallback',
      coversFrom: messages[0].id,
      coversTo,
      coversDigest: ContextCheckpoint.coversDigest(
        messages.slice(0, coversIndex + 1).map((m) => ({ id: m.id, text: m.text })),
      ),
      messagesCovered: coversIndex + 1,
      userMessageIds: result.keptUserIds,
      text: result.checkpointText,
      summary: previous?.summary ?? null,
      language: null,
      model: ctx.model,
      packerVersion,
      createdAt: now(),
      cost: null,
    };
  }

  type AIAttempt =
    | { kind: 'noop' }
    | { kind: 'cancelled' }
    | { kind: 'stopped' }
    | { kind: 'fallback'; failures: CompactFailureReason[][] }
    | { kind: 'summary'; row: ContextCheckpointRow; failures: CompactFailureReason[][] };

  /** AI compaction, at most two summary calls. */
  async function summarizeRow(
    conversationId: string,
    trigger: CompactionTrigger,
    ctx: CompactionContext,
    previous: ContextCheckpointRow | null,
    sendSignal: AbortSignal | undefined,
  ): Promise<AIAttempt> {
    const { messages, B, rhoHi } = ctx;
    const span = ContextCheckpoint.selectSpan(messages, B, previous?.coversTo ?? null);
    if (span.action === 'noop') return { kind: 'noop' };

    const spanIds = new Set(span.spanIds);
    const req = ContextCompactor.summaryRequest({
      U: ctx.U,
      prefixTokens: ctx.prefixTokens,
      rhoHi,
      language: null,
      summaryMax: ContextBudget.derive(B).summaryMax,
      previousCheckpointText: previous?.text ?? null,
      previousSummary: previous?.summary ?? null,
      span: messages
        .filter((m) => spanIds.has(m.id))
        .map((m) => ({
          id: m.id,
          role: m.role,
          text: m.text,
          ...(m.attachments && m.attachments.length > 0 ? { attachments: m.attachments } : {}),
        })),
    });
    // The request does not fit: fall back, not counted as a failure
    if (req.shape === 'tooLarge') return { kind: 'fallback', failures: [] };

    const compactInput = {
      conversationId,
      B,
      rhoHi,
      messages,
      previous: previous ? { coversTo: previous.coversTo, summary: previous.summary ?? '' } : null,
    };
    const outputs: Array<string | null> = [];
    let result = ContextCompactor.compact({ ...compactInput, summaryOutputs: outputs });
    // Counts as "in progress" only during the summary call; if the same conversation already has a compaction in progress, its registration is not overwritten.
    const entry: CompactingEntry = { trigger, cancel: new AbortController(), stop: new AbortController() };
    const onSendAbort = () => entry.stop.abort();
    sendSignal?.addEventListener('abort', onSendAbort, { once: true });
    if (sendSignal?.aborted) entry.stop.abort();
    const bridge = bridgeSignals(entry.cancel.signal, entry.stop.signal);
    const callSignal = bridge.signal;
    const registered = !aiCompacting.has(conversationId);
    if (registered) {
      aiCompacting.set(conversationId, entry);
      emitCompacting(conversationId);
    }
    try {
      for (let i = 0; i < ContextCompactor.constants.maxSummaryAttempts; i += 1) {
        const output = await callSummary(req, callSignal);
        if (entry.stop.signal.aborted) return { kind: 'stopped' };
        if (entry.cancel.signal.aborted) return { kind: 'cancelled' };
        outputs.push(output);
        result = ContextCompactor.compact({ ...compactInput, summaryOutputs: [...outputs] });
        if (result.outcome !== 'fallback') break;
      }
    } finally {
      bridge.release();
      sendSignal?.removeEventListener('abort', onSendAbort);
      if (registered && aiCompacting.get(conversationId) === entry) {
        aiCompacting.delete(conversationId);
        emitCompacting(conversationId);
      }
    }
    if (result.outcome === 'noop') return { kind: 'noop' };
    if (result.outcome === 'fallback') {
      applyBreaker(conversationId, 'llmFailure');
      return { kind: 'fallback', failures: result.failures };
    }
    applyBreaker(conversationId, 'llmSuccess');
    return {
      kind: 'summary',
      failures: result.failures,
      row: {
        conversationId,
        checkpointId: result.checkpointId,
        kind: 'summary',
        coversFrom: result.coversFrom,
        coversTo: result.coversTo,
        coversDigest: result.coversDigest,
        messagesCovered: result.messagesCovered,
        userMessageIds: result.keptUserIds,
        text: result.text,
        // Store the trimmed text: consistent with the <summary> in the body, and also the previousSummary of the next incremental compaction.
        summary: trimWhiteSpace(outputs[result.attempts - 1] ?? ''),
        language: null,
        model: ctx.model,
        packerVersion: ContextCheckpoint.constants.packerVersion,
        createdAt: now(),
        cost: null,
      },
    };
  }

  /** Saves, then counts all local checkpointIds of this conversation; a save failure is logged and returns false. */
  async function save(row: ContextCheckpointRow): Promise<boolean> {
    try {
      await ContextCompactionStore.put(row);
    } catch (error) {
      console.error('[ContextCompaction] saving checkpoint failed:', error);
      return false;
    }
    let localIds: string[];
    try {
      localIds = (await listContextCheckpoints(row.conversationId)).map((r) => r.checkpointId);
    } catch (error) {
      console.error('[ContextCompaction] listing checkpoints failed:', error);
      return true;
    }
    // When the local save brings the count to exactly 3, show the hint once.
    noteCompactionSaved(row.conversationId, localIds.length);
    return true;
  }

  /** Entry point. If the same conversation already has a compaction running, wait for it to finish, then re-judge with latestValid. */
  async function compact(
    conversationId: string,
    trigger: CompactionTrigger,
    options: CompactOptions = {},
  ): Promise<CompactionResult> {
    let waited = false;
    for (let pending = inFlight.get(conversationId); pending; pending = inFlight.get(conversationId)) {
      waited = true;
      await pending;
      if (options.signal?.aborted) return { outcome: 'noop', failures: [], cancelled: true };
    }
    const run = runCompact(conversationId, trigger, options, waited);
    const settled = run.then(
      () => undefined,
      () => undefined,
    );
    inFlight.set(conversationId, settled);
    try {
      return await run;
    } finally {
      if (inFlight.get(conversationId) === settled) inFlight.delete(conversationId);
    }
  }

  /** P̂ after applying a library row (fixed part + row text + history after coversTo); returns null when the row is not in the history. */
  function pHatWith(ctx: CompactionContext, row: ContextCheckpointRow): number | null {
    const coversIndex = ctx.messages.findIndex((m) => m.id === row.coversTo);
    if (coversIndex < 0) return null;
    const tail = ctx.messages.slice(coversIndex + 1).reduce((sum, m) => sum + m.estTokens, 0);
    return ctx.fixedTokens + ContextBudget.estimateMessage(row.text, ctx.rhoHi) + tail;
  }

  async function runCompact(
    conversationId: string,
    trigger: CompactionTrigger,
    options: CompactOptions,
    waited: boolean,
  ): Promise<CompactionResult> {
    const { signal, aiOnly = false } = options;
    const stopped = (): CompactionResult => ({ outcome: 'noop', failures: [], cancelled: true });
    if (signal?.aborted) return stopped();
    const ctx = await deps.context(conversationId, trigger);
    if (!ctx || ctx.messages.length === 0) return { outcome: 'noop', failures: [] };
    const previous = await ContextCompactionStore.latestValid(
      conversationId,
      ctx.messages.map((m) => ({ id: m.id, text: m.text })),
    );
    if (signal?.aborted) return stopped();
    // Waited for another compaction (e.g. pre-compaction): if applying the row it saved is already below 0.90·B, do not compact again and hand that row to the caller to use directly.
    if (waited && previous && trigger !== 'manual') {
      const pHat = pHatWith(ctx, previous);
      if (pHat !== null && pHat < ContextBudget.derive(ctx.B).sendCompactAt) {
        return { outcome: 'noop', row: previous, failures: [] };
      }
    }

    let failures: CompactFailureReason[][] = [];
    if (useAI(conversationId, trigger)) {
      const attempt = await summarizeRow(conversationId, trigger, ctx, previous, signal);
      if (attempt.kind === 'noop') return { outcome: 'noop', failures: [] };
      // Stop: the whole run is cancelled and nothing is saved. Cancel on manual: nothing is saved; cancel on preSend/overflow: not counted as a failure, continue with the fallback.
      if (attempt.kind === 'stopped') return stopped();
      if (attempt.kind === 'cancelled' && trigger === 'manual') return stopped();
      if (attempt.kind === 'summary') {
        if (signal?.aborted) return stopped();
        // Save failure returns noop (no row); the caller falls back to the in-memory fallback.
        if (!(await save(attempt.row))) return { outcome: 'noop', failures: attempt.failures };
        return { outcome: 'summary', row: attempt.row, failures: attempt.failures };
      }
      if (attempt.kind === 'fallback') failures = attempt.failures;
    }
    if (aiOnly) return { outcome: 'noop', failures };

    const row = fallbackRow(conversationId, ctx, previous);
    if (!row) return { outcome: 'noop', failures };
    if (signal?.aborted) return stopped();
    if (!(await save(row))) return { outcome: 'noop', failures };
    return { outcome: 'fallback', row, failures };
  }

  return { compact };
}
