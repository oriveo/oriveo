/** Continuation lifecycle boundary.
 *
 * This module is intentionally local-only: no Zustand persistence, sync adapter, backup or
 * telemetry import is permitted. A new process never reads it to resume a tool loop; it merely
 * retains an interrupted marker for the next explicit send to decide whether to start clean.
 */
import { LocalContinuationStore } from './local-continuation-store';
import { validateContinuation, type ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';

// A persisted opaque block is usable only by the page process that captured it. A full reload
// creates a new token, so explicit Continue cleanly restarts instead of replaying a stale tool loop.
const processSessionId = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random()}`;
const store = new LocalContinuationStore(processSessionId);
function available() { return typeof indexedDB !== 'undefined'; }
const queues = new Map<string, Promise<void>>();
const deletedMessages = new Set<string>();
const deletedConversations = new Set<string>();
const conversationDeletionBarriers = new Map<string, Promise<void>>();
function queueKey(conversationId: string, messageId: string) { return `${conversationId}\u0000${messageId}`; }
function isDeleted(conversationId: string, messageId: string) {
  return deletedConversations.has(conversationId) || deletedMessages.has(queueKey(conversationId, messageId));
}
/** Serialize lifecycle writes per message: an SSE continuation arriving immediately before
 * stream completion must be persisted before the completion finalizer decides whether to retain it. */
function enqueueRaw(conversationId: string, messageId: string, action: () => Promise<void>): Promise<void> {
  const key = queueKey(conversationId, messageId);
  const prior = queues.get(key) ?? Promise.resolve();
  const next = prior.catch(() => undefined).then(action);
  queues.set(key, next);
  void next.finally(() => { if (queues.get(key) === next) queues.delete(key); }).catch(() => undefined);
  return next;
}
function enqueue(conversationId: string, messageId: string, action: () => Promise<void>): Promise<void> {
  if (isDeleted(conversationId, messageId)) return Promise.resolve();
  // Check again when the queued action reaches the front. A delete may have been requested
  // after an SSE event queued this write but before IndexedDB was touched.
  return enqueueRaw(conversationId, messageId, async () => {
    if (isDeleted(conversationId, messageId)) return;
    await action();
  });
}
function ignore(promise: Promise<unknown>) { void promise.catch(() => undefined); }

export function continuationSendStarted(conversationId: string, messageId: string): Promise<void> {
  if (!available()) return Promise.resolve();
  return enqueue(conversationId, messageId, () => store.save({ conversationId, messageId, state: { phase: 'sending' } }));
}
/** Only the proxy's validated internal event can create replayable state. */
export function continuationCaptured(conversationId: string, messageId: string, continuation: ContinuationIntent): void {
  if (!available() || !validateContinuation(continuation).accepted) return;
  ignore(enqueue(conversationId, messageId, () => store.save({ conversationId, messageId, state: { continuation } })));
}
/** Explicit user continue/retry is the sole reader; normal send/startup never calls this. */
export async function continuationForExplicitContinue(conversationId: string, messageId: string): Promise<ContinuationIntent | undefined> {
  if (!available() || isDeleted(conversationId, messageId)) return undefined;
  try {
    await (queues.get(queueKey(conversationId, messageId)) ?? Promise.resolve());
    const record = await store.load(conversationId, messageId);
    // After a background or lock-screen interruption only completed turns and their text are kept as
    // local fact; a later explicit resend must be a clean restart and must not replay the interrupted opaque state.
    if (record?.interrupted) return undefined;
    const continuation = record?.state.continuation;
    if (!continuation || typeof continuation !== 'object' || !validateContinuation(continuation as ContinuationIntent).accepted) return undefined;
    return continuation as ContinuationIntent;
  } catch {
    return undefined;
  }
}
export function continuationSendCompleted(conversationId: string, messageId: string): Promise<void> {
  if (!available()) return Promise.resolve();
  // A final answer has no pending continuation. But a complete preceding tool leg does: retain
  // only validated replay state for an explicit later continue; erase the initial marker.
  return enqueue(conversationId, messageId, async () => {
    const record = await store.load(conversationId, messageId);
    const continuation = record?.state.continuation;
    if (continuation && typeof continuation === 'object' && validateContinuation(continuation as ContinuationIntent).accepted) {
      await store.save({ ...record, interrupted: false });
    } else {
      await store.deleteMessage(conversationId, messageId);
    }
  });
}
export function continuationSendInterrupted(conversationId: string, messageId: string): Promise<void> {
  if (!available()) return Promise.resolve();
  return enqueue(conversationId, messageId, () => store.interruptToolLoop(conversationId, messageId));
}
export function deleteLocalMessageContinuation(conversationId: string, messageId: string): Promise<void> {
  if (!available()) return Promise.resolve();
  deletedMessages.add(queueKey(conversationId, messageId));
  // Deletion itself bypasses the tombstone gate, but stays ordered behind any already queued
  // write. Later lifecycle events are rejected both at enqueue time and at execution time.
  const deletion = enqueueRaw(conversationId, messageId, () => store.deleteMessage(conversationId, messageId));
  ignore(deletion);
  return deletion;
}
export function deleteLocalConversationContinuation(conversationId: string): Promise<void> {
  if (!available()) return Promise.resolve();
  const priorBarrier = conversationDeletionBarriers.get(conversationId);
  if (priorBarrier) return priorBarrier;
  deletedConversations.add(conversationId);
  // A conversation deletion crosses message keys, so it cannot rely on a single per-message
  // queue. Freeze this conversation first, await every queue already in flight, then cursor
  // delete. No later start/capture/complete/interrupted action can recreate a row.
  const pending = [...queues.entries()]
    .filter(([key]) => key.startsWith(`${conversationId}\u0000`))
    .map(([, pendingWrite]) => pendingWrite.catch(() => undefined));
  const barrier = Promise.all(pending).then(() => store.deleteConversation(conversationId));
  conversationDeletionBarriers.set(conversationId, barrier);
  ignore(barrier);
  return barrier;
}
