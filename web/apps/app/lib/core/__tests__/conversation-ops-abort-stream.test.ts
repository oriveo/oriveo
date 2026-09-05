// @vitest-environment jsdom
//
// Deleting a conversation must abort its active streams and mark them interrupted, or the state ends up inconsistent.

import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import { createAppStore, type AppStore } from '../store/app-store';
import { deleteConversation, deleteConversations } from '../conversation-ops';
import {
  __resetActiveStreamsForTests,
  registerStream,
  hasStream,
} from '../chat/active-streams';
import { __resetStreamBatcherForTests, batchAppendStreaming } from '../chat/stream-batcher';
import { createPartialFlushScheduler } from '../chat/partial-flush';

const mockSyncAdapter = {
  didDeleteConversations: vi.fn(),
  didUpdateConversationTitle: vi.fn(),
  didUpdateConversationModel: vi.fn(),
};

// Deletion goes through intent queueing and replay rather than calling the adapter directly, where optional chaining would silently drop the deletion when the adapter is null.
const mockFlushPendingDeletions = vi.fn(async () => {});

vi.mock('../sync-port', () => ({
  getSyncAdapter: vi.fn(() => mockSyncAdapter),
  flushPendingConversationDeletions: (...args: unknown[]) =>
    (mockFlushPendingDeletions as (...a: unknown[]) => Promise<void>)(...args),
}));

let testStore: ReturnType<typeof createAppStore>;
vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: () => undefined,
  getVanillaStore: () => testStore,
  tryGetVanillaStore: () => testStore,
}));

function makeConv(id: string, msgId: string): Conversation {
  return {
    id,
    title: `Conv ${id}`,
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [
      {
        id: msgId,
        role: 'assistant',
        text: '',
        providerID: 'p1',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelID: 'm1',
        modelName: 'M1',
        estimatedCost: 0,
        state: 'generating',
      },
    ],
    draftText: '',
    updatedAt: '2026-05-07T00:00:00.000Z',
    createdAt: '2026-05-07T00:00:00.000Z',
  };
}

function startFakeStream(store: AppStore, convId: string, msgId: string) {
  const abort = vi.fn();
  store.beginStreamingForConversation(convId, msgId);
  registerStream({
    conversationId: convId,
    msgId,
    abort,
    flushScheduler: createPartialFlushScheduler(testStore, convId, msgId),
  });
  return abort;
}

beforeEach(() => {
  testStore = createAppStore({ conversations: [] });
  __resetActiveStreamsForTests();
  __resetStreamBatcherForTests();
  vi.clearAllMocks();
});

describe('deleteConversation aborts active stream', () => {
  it('aborts the conversation stream before removing it', () => {
    const conv = makeConv('A', 'mA');
    testStore.setState({ conversations: [conv] });
    const abortA = startFakeStream(testStore.getState(), 'A', 'mA');

    batchAppendStreaming('A', 'partial answer');

    deleteConversation(testStore, 'A');

    // abort was called once
    expect(abortA).toHaveBeenCalledTimes(1);
    // the session was cleared
    expect(hasStream('A')).toBe(false);
    // streamingConversationIds must not contain A
    const state = testStore.getState();
    expect(state.streamingConversationIds).not.toContain('A');
    // streamingTexts must not contain A either
    expect(state.streamingTexts.A).toBeUndefined();
    // the conversation was removed
    expect(state.conversations.find((c) => c.id === 'A')).toBeUndefined();
    // sync was notified once
    expect(mockFlushPendingDeletions).toHaveBeenCalledWith(['A']);
  });

  it('no-ops abort path when conversation has no active stream', () => {
    const conv = makeConv('B', 'mB');
    testStore.setState({ conversations: [conv] });

    expect(() => deleteConversation(testStore, 'B')).not.toThrow();

    const state = testStore.getState();
    expect(state.conversations.find((c) => c.id === 'B')).toBeUndefined();
    expect(mockFlushPendingDeletions).toHaveBeenCalledWith(['B']);
  });

  it('deleteConversations aborts streams for all targeted ids', () => {
    const convA = makeConv('A', 'mA');
    const convB = makeConv('B', 'mB');
    const convC = makeConv('C', 'mC'); // C  
    testStore.setState({ conversations: [convA, convB, convC] });
    const abortA = startFakeStream(testStore.getState(), 'A', 'mA');
    const abortB = startFakeStream(testStore.getState(), 'B', 'mB');

    deleteConversations(testStore, ['A', 'B', 'C']);

    expect(abortA).toHaveBeenCalledTimes(1);
    expect(abortB).toHaveBeenCalledTimes(1);
    expect(hasStream('A')).toBe(false);
    expect(hasStream('B')).toBe(false);
    const state = testStore.getState();
    expect(state.conversations).toHaveLength(0);
    expect(state.streamingConversationIds).toHaveLength(0);
    expect(mockFlushPendingDeletions).toHaveBeenCalledWith(['A', 'B', 'C']);
  });
});
