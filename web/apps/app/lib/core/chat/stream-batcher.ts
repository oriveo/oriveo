/**
 * Module-level rAF batcher with an independent bucket per conversation.
 *
 * Why it has to live outside the React hook lifecycle:
 *   - useStreamChat is mounted once by ChatView, but navigating to a non-chat route
 *     (settings/providers) unmounts the whole ChatView tree via PersistentShell, taking the rAF
 *     id and the pending chunks with it.
 *   - The point of uninterrupted streaming is that a stream started in any conversation keeps
 *     going wherever the user navigates, so the batcher has to outlive the React components.
 *
 * Multi-conversation design: one pending buffer and one rAF id per convId. A single rAF tick only
 * flushes the accumulated chunks of that convId, so conversations do not interfere.
 *
 * Text and reasoning share one rAF: both streams are written to the store in the same frame, so a
 * single re-render reflects both without extra rAF or re-render passes. Reasoning used to bypass
 * this module and write to the store directly (one set per SSE chunk, one re-render each, and a
 * provider can emit 100+/s). Once the expanded thinking block rendered markdown, this path had to
 * come under frame throttling, otherwise parsing frequency tracks the chunk rate.
 */

import { getVanillaStore } from '../../../providers/StoreProvider';

const pendingChunks: Map<string, string> = new Map();
const pendingReasoningChunks: Map<string, string> = new Map();
const rafIds: Map<string, number> = new Map();

function flush(convId: string): void {
  const pending = pendingChunks.get(convId);
  const pendingReasoning = pendingReasoningChunks.get(convId);
  rafIds.delete(convId);
  if (!pending && !pendingReasoning) return;
  if (pending) pendingChunks.set(convId, '');
  if (pendingReasoning) pendingReasoningChunks.set(convId, '');
  // Only append while the conversation is still streaming, so an in-flight rAF cannot write stale
  // data after a clear. The keys of streamingTexts and streamingReasoningTexts are kept in sync
  // atomically by begin/clearStreamingForConversation, so one guard covers both streams.
  const store = getVanillaStore();
  const state = store.getState();
  if (!Object.prototype.hasOwnProperty.call(state.streamingTexts, convId)) return;
  if (pending) state.appendStreamingText(convId, pending);
  if (pendingReasoning) state.appendStreamingReasoningText(convId, pendingReasoning);
}

function scheduleFlush(convId: string): void {
  if (rafIds.has(convId)) return;
  if (typeof requestAnimationFrame === 'undefined') {
    // Non-browser environments (SSR, tests) degrade to an immediate flush.
    flush(convId);
    return;
  }
  rafIds.set(convId, requestAnimationFrame(() => flush(convId)));
}

/** Accumulate one chunk into the conversation's pending buffer, flushed to the store on the next frame. */
export function batchAppendStreaming(convId: string, chunk: string): void {
  if (!chunk) return;
  pendingChunks.set(convId, (pendingChunks.get(convId) ?? '') + chunk);
  scheduleFlush(convId);
}

/** Reasoning counterpart. It shares a frame with the text stream and the same flush/discard exits, so the semantics are symmetric. */
export function batchAppendStreamingReasoning(convId: string, chunk: string): void {
  if (!chunk) return;
  pendingReasoningChunks.set(convId, (pendingReasoningChunks.get(convId) ?? '') + chunk);
  scheduleFlush(convId);
}

/** Write the conversation's pending chunks to the store immediately, cancelling the scheduled rAF. */
export function flushPendingStreaming(convId: string): void {
  const rafId = rafIds.get(convId);
  if (rafId !== undefined && typeof cancelAnimationFrame !== 'undefined') {
    cancelAnimationFrame(rafId);
  }
  rafIds.delete(convId);
  flush(convId);
}

/** Flush every conversation synchronously (the lifecycle hidden / pagehide path). */
export function flushAllPendingStreaming(): void {
  // Take the union of both streams: a conversation with only reasoning pending (backgrounded while
  // still thinking, before any text arrived) must not be skipped, or the tail of the reasoning is lost.
  const convIds = new Set([...pendingChunks.keys(), ...pendingReasoningChunks.keys()]);
  for (const convId of convIds) {
    flushPendingStreaming(convId);
  }
}

/** Discard the conversation's pending chunks (abort path), so unflushed chunks cannot leak into the next stream. */
export function discardPendingStreaming(convId: string): void {
  const rafId = rafIds.get(convId);
  if (rafId !== undefined && typeof cancelAnimationFrame !== 'undefined') {
    cancelAnimationFrame(rafId);
  }
  rafIds.delete(convId);
  pendingChunks.delete(convId);
  pendingReasoningChunks.delete(convId);
}

/** Test-only helper. */
export function __resetStreamBatcherForTests(): void {
  for (const rafId of rafIds.values()) {
    if (typeof cancelAnimationFrame !== 'undefined') cancelAnimationFrame(rafId);
  }
  rafIds.clear();
  pendingChunks.clear();
  pendingReasoningChunks.clear();
}
