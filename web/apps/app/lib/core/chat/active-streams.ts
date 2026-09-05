/**
 * Module-level active streams table: a multi-session stream registry that outlives React lifecycles.
 *
 * Role: useStreamChat only wires things up; the sessions table itself does not depend on React.
 *   - Any conversation registers a session on send and survives route changes
 *   - Entry guards apply only within the same conversation
 *   - Lifecycle, sign-out and partition-switch paths walk every session
 *
 * Relationship with stream-batcher:
 *   - active-streams holds the abort handle, msgId and partial-flush scheduler
 *   - stream-batcher holds the per-conversation pending buffer and rAF id
 *   - They complement each other: aborting a session also discards that batcher buffer
 */

import { getVanillaStore, tryGetVanillaStore } from '../../../providers/StoreProvider';

import { flushPartialToMessage, type PartialFlushScheduler } from './partial-flush';
import {
  discardPendingStreaming,
  flushPendingStreaming,
  flushAllPendingStreaming,
} from './stream-batcher';
import {
  clearStreamPartialBackup,
  upsertStreamPartialBackup,
} from '../store/stream-partial-backup';

export interface StreamingSession {
  conversationId: string;
  msgId: string;
  abort: () => void;
  /**
   * Long-stream persistence scheduler. The one that actually feeds onChunk is created by
   * stream-runner itself; this registry copy is only disposed on endStream, so it may be absent
   * (during placeholder registration there is nothing to schedule yet).
   */
  flushScheduler?: PartialFlushScheduler;
  // Millisecond timestamp used to compute telemetry chat_message_stopped.elapsed_ms
  startedAt: number;
  /** Continuation or managed recovery stream (as opposed to a first send), used only for telemetry is_recovery. */
  isRecovery?: boolean;
  /**
   * Previous-round reasoning snapshot for continuations (from interruptedMsg.reasoningText).
   * partial-flush joins it with this round's partial so re-entry neither drops nor duplicates prev.
   * Undefined on a first round or when there is no reasoning.
   */
  initialReasoning?: string;
}

const sessions: Map<string, StreamingSession> = new Map();

export function registerStream(s: StreamingSession): void {
  sessions.set(s.conversationId, s);
}

export function getStream(convId: string): StreamingSession | undefined {
  return sessions.get(convId);
}

export function hasStream(convId: string): boolean {
  return sessions.has(convId);
}

export function endStream(convId: string): void {
  const session = sessions.get(convId);
  if (!session) return;
  session.flushScheduler?.dispose();
  sessions.delete(convId);
  discardPendingStreaming(convId);
}

/** All current session ids (a copied array, safe to delete from while iterating) */
export function listActiveStreamConversationIds(): string[] {
  return Array.from(sessions.keys());
}

/**
 * Persists the conversation's partial as `interrupted`, then aborts and ends the stream.
 * Used for overwrite-style sends in the same conversation, stop, conversation deletion and single-conversation failures.
 */
export function flushAndInterruptStream(convId: string): void {
  const session = sessions.get(convId);
  if (!session) return;
  // 1. Write rAF pending chunks into store.streamingTexts so the last slice is not lost
  flushPendingStreaming(convId);
  // 2. Persist store.streamingTexts[convId] into the message text with state=interrupted
  flushPartialToMessage(
    getVanillaStore(),
    session.conversationId,
    session.msgId,
    {
      state: 'interrupted',
      prevReasoning: session.initialReasoning,
    },
  );
  // 3. Abort the fetch and clear the streaming state
  session.abort();
  endStream(convId);
  getVanillaStore().getState().clearStreamingForConversation(convId);
  clearStreamPartialBackup(convId);
}

/**
 * Sign-out or partition switch: abort every session and persist them as interrupted.
 */
export function abortAllStreams(): void {
  for (const convId of listActiveStreamConversationIds()) {
    flushAndInterruptStream(convId);
  }
}

/**
 * visibilitychange=hidden: every session syncs its partial into message.text while state stays generating (the stream may still be running).
 */
export function flushAllStreamsForLifecycle(): void {
  if (sessions.size === 0) return;
  const store = tryGetVanillaStore();
  if (!store) return;
  flushAllPendingStreaming();
  for (const session of sessions.values()) {
    flushPartialToMessage(store, session.conversationId, session.msgId, {
      prevReasoning: session.initialReasoning,
    });
  }
}

/**
 * pagehide: write every session's partial into the sessionStorage backup map from a synchronous context.
 * An IDB transaction is not guaranteed to commit during pagehide, while sessionStorage is a synchronous, reliable fallback.
 */
export function backupAllStreamsToSessionStorage(): void {
  if (sessions.size === 0) return;
  const store = tryGetVanillaStore();
  if (!store) return;
  flushAllPendingStreaming();
  const ts = Date.now();
  for (const session of sessions.values()) {
    const partial = store.getState().streamingTexts[session.conversationId];
    if (!partial) continue;
    upsertStreamPartialBackup({
      conversationId: session.conversationId,
      msgId: session.msgId,
      partial,
      ts,
    });
  }
}

/** Test-only helper */
export function __resetActiveStreamsForTests(): void {
  sessions.clear();
}
