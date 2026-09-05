// @vitest-environment jsdom
//
// Behavior lock for merging the reasoning stream into the rAF batcher.
//
// Background: writing reasoning straight to the store means one set (and one re-render) per SSE
// chunk, and a provider can push 100+/s. Once the expanded reasoning block renders through markdown
// that path has to be frame-throttled, otherwise parse frequency tracks the chunk rate.
//
// The main new risk after merging is a lost tail: if stop or backgrounding only flushes the body,
// the last frame of reasoning is gone. This file locks the symmetry of the two streams at every exit.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createAppStore } from '../../store/app-store';
import {
  __resetStreamBatcherForTests,
  batchAppendStreaming,
  batchAppendStreamingReasoning,
  discardPendingStreaming,
  flushAllPendingStreaming,
  flushPendingStreaming,
} from '../stream-batcher';

let testStore: ReturnType<typeof createAppStore>;
vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: () => undefined,
  getVanillaStore: () => testStore,
}));

function beginStream(convId: string) {
  testStore.getState().beginStreamingForConversation(convId, `${convId}-msg`);
}

describe('stream-batcher reasoning channel', () => {
  beforeEach(() => {
    testStore = createAppStore();
    __resetStreamBatcherForTests();
  });

  it('a reasoning chunk reaches the store through a synchronous flush', () => {
    beginStream('A');
    batchAppendStreamingReasoning('A', 'first thought ');
    batchAppendStreamingReasoning('A', 'second thought');
    // Nothing reaches the store before the flush, which is the point of frame throttling
    expect(testStore.getState().streamingReasoningTexts.A).toBe('');
    flushPendingStreaming('A');
    expect(testStore.getState().streamingReasoningTexts.A).toBe('first thought second thought');
  });

  it('body and reasoning are written in the same frame without swallowing each other', () => {
    beginStream('A');
    batchAppendStreamingReasoning('A', 'thinking');
    batchAppendStreaming('A', 'body text');
    flushPendingStreaming('A');
    expect(testStore.getState().streamingTexts.A).toBe('body text');
    expect(testStore.getState().streamingReasoningTexts.A).toBe('thinking');
  });

  /** stop path: flushAndInterruptStream calls flushPendingStreaming before persisting, so the tail must survive. */
  it('a synchronous flush still writes when only reasoning is pending, so stop keeps the reasoning tail', () => {
    beginStream('A');
    batchAppendStreamingReasoning('A', 'the last stretch of thinking');
    flushPendingStreaming('A');
    expect(testStore.getState().streamingReasoningTexts.A).toBe('the last stretch of thinking');
  });

  /** The pagehide / lifecycle path iterates the union of both stream keys. */
  it('flushAll covers a conversation that only has reasoning pending', () => {
    beginStream('A');
    beginStream('B');
    batchAppendStreaming('A', 'body A');
    batchAppendStreamingReasoning('B', 'thinking B'); // B only has reasoning
    flushAllPendingStreaming();
    expect(testStore.getState().streamingTexts.A).toBe('body A');
    expect(testStore.getState().streamingReasoningTexts.B).toBe('thinking B');
  });

  it('discard clears both pending buffers so the next stream is not polluted', () => {
    beginStream('A');
    batchAppendStreaming('A', 'body text');
    batchAppendStreamingReasoning('A', 'thinking');
    discardPendingStreaming('A');
    flushPendingStreaming('A');
    expect(testStore.getState().streamingTexts.A).toBe('');
    expect(testStore.getState().streamingReasoningTexts.A).toBe('');
  });

  /** In-flight pending after the conversation was cleared: the guard must block it rather than write stale data. */
  it('no stale reasoning is written once the conversation has ended', () => {
    beginStream('A');
    batchAppendStreamingReasoning('A', 'a late thought');
    testStore.getState().clearStreamingForConversation('A');
    flushPendingStreaming('A');
    expect(testStore.getState().streamingReasoningTexts.A).toBeUndefined();
  });

  it('reasoning is bucketed per conversation', () => {
    beginStream('A');
    beginStream('B');
    batchAppendStreamingReasoning('A', "A's thinking");
    batchAppendStreamingReasoning('B', "B's thinking");
    flushPendingStreaming('A');
    expect(testStore.getState().streamingReasoningTexts.A).toBe("A's thinking");
    expect(testStore.getState().streamingReasoningTexts.B).toBe('');
    flushPendingStreaming('B');
    expect(testStore.getState().streamingReasoningTexts.B).toBe("B's thinking");
  });
});
