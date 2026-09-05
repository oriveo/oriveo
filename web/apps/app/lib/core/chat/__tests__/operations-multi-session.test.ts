// @vitest-environment jsdom
//
// Concurrent streaming across conversations - integration test over the keyed store, active-streams
// and stream-batcher.
//
// Scenarios covered:
//   1. partials in different conversations do not overwrite each other
//   2. sending in one conversation does not interrupt another conversation's stream
//   3. lifecycle flush across several streams
//   4. pagehide backup across several streams
//   5. abortAllStreams clears everything
//   6. selector isolation and a stable streamingConversationIds reference
//   7. clearStreamPartialBackup(convId) clears only that entry
//   8. same-conversation replacement through flushAndInterruptStream

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { createAppStore, type AppStore } from '../../store/app-store';
import {
  selectIsStreamingFor,
  selectStreamingTextFor,
  selectStreamingConversationIds,
} from '../../store/selectors';
import {
  abortAllStreams,
  backupAllStreamsToSessionStorage,
  flushAllStreamsForLifecycle,
  flushAndInterruptStream,
  registerStream,
  __resetActiveStreamsForTests,
} from '../active-streams';
import {
  __resetStreamBatcherForTests,
  batchAppendStreaming,
  flushPendingStreaming,
} from '../stream-batcher';
import { createPartialFlushScheduler } from '../partial-flush';
import {
  clearStreamPartialBackup,
  readStreamPartialBackup,
} from '../../store/stream-partial-backup';

// Make active-streams and stream-batcher see the store this test creates.
let testStore: ReturnType<typeof createAppStore>;
let vanillaStoreReady: boolean;
vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: () => undefined,
  getVanillaStore: () => testStore,
  tryGetVanillaStore: () => vanillaStoreReady ? testStore : null,
}));

function makeProvider(): Provider {
  return {
    id: 'p-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••test',
  };
}

function makeModel(): AIModel {
  return {
    id: 'gpt-4',
    name: 'GPT-4',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: 'standard',
  };
}

function makeAssistantMsg(id: string): ChatMessage {
  const provider = makeProvider();
  const model = makeModel();
  return {
    id,
    role: 'assistant',
    text: '',
    providerID: provider.id,
    providerKind: provider.kind,
    providerName: 'OpenAI',
    modelID: model.id,
    modelName: model.name,
    estimatedCost: 0,
    state: 'generating',
  };
}

function makeConversation(convId: string, assistantId: string): Conversation {
  return {
    id: convId,
    title: `Conv ${convId}`,
    hasCustomTitle: false,
    providerID: 'p-1',
    modelID: 'gpt-4',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [makeAssistantMsg(assistantId)],
    draftText: '',
    updatedAt: '2026-05-07T00:00:00.000Z',
  };
}

function registerFakeStream(store: AppStore, convId: string, msgId: string, abort = vi.fn()) {
  // Inject the store action the caller would call: begin populates the streaming map and ids.
  store.beginStreamingForConversation(convId, msgId);
  // Register in active-streams, holding abort and flushScheduler.
  registerStream({
    conversationId: convId,
    msgId,
    abort,
    flushScheduler: createPartialFlushScheduler(testStore, convId, msgId),
  });
  return { abort };
}

beforeEach(() => {
  testStore = createAppStore({
    conversations: [],
  });
  vanillaStoreReady = true;
  __resetActiveStreamsForTests();
  __resetStreamBatcherForTests();
  if (typeof window !== 'undefined') window.sessionStorage.clear();
  clearStreamPartialBackup();
});

describe('concurrent streaming across conversations', () => {
  it('lifecycle callbacks before store initialization are safe no-ops', () => {
    vanillaStoreReady = false;

    expect(() => flushAllStreamsForLifecycle()).not.toThrow();
    expect(() => backupAllStreamsToSessionStorage()).not.toThrow();
    expect(readStreamPartialBackup()).toEqual({});
  });

  it('1. partials in different conversations do not overwrite each other', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    testStore.setState({ conversations: [convA, convB] });
    registerFakeStream(testStore.getState(), 'A', 'mA');
    registerFakeStream(testStore.getState(), 'B', 'mB');

    batchAppendStreaming('A', 'Hello A ');
    batchAppendStreaming('B', 'Hello B ');
    batchAppendStreaming('A', 'continued');
    flushPendingStreaming('A');
    flushPendingStreaming('B');

    expect(selectStreamingTextFor('A')(testStore.getState())).toBe('Hello A continued');
    expect(selectStreamingTextFor('B')(testStore.getState())).toBe('Hello B ');
    expect(selectStreamingTextFor('A')(testStore.getState()))
      .not.toBe(selectStreamingTextFor('B')(testStore.getState()));
  });

  it('2. sending a new message in one conversation does not interrupt another stream', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    testStore.setState({ conversations: [convA, convB] });
    const { abort: abortA } = registerFakeStream(testStore.getState(), 'A', 'mA');
    registerFakeStream(testStore.getState(), 'B', 'mB');

    batchAppendStreaming('A', 'partA');
    flushPendingStreaming('A');
    // Simulate the user sending in B - A must not be interrupted.
    // The entry guard only applies to B and its own previous stream; B has none here, so A is untouched.
    expect(abortA).not.toHaveBeenCalled();
    expect(selectIsStreamingFor('A')(testStore.getState())).toBe(true);
    expect(selectStreamingTextFor('A')(testStore.getState())).toBe('partA');
  });

  it('3. same-conversation replacement: flushAndInterruptStream interrupts only that conversation', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    testStore.setState({ conversations: [convA, convB] });
    const { abort: abortA } = registerFakeStream(testStore.getState(), 'A', 'mA');
    const { abort: abortB } = registerFakeStream(testStore.getState(), 'B', 'mB');

    batchAppendStreaming('A', 'partA');
    batchAppendStreaming('B', 'partB');
    flushPendingStreaming('A');
    flushPendingStreaming('B');

    flushAndInterruptStream('A');

    expect(abortA).toHaveBeenCalledTimes(1);
    expect(abortB).not.toHaveBeenCalled();
    const state = testStore.getState();
    const aMsg = state.conversations.find((c) => c.id === 'A')?.messages.find((m) => m.id === 'mA');
    const bMsg = state.conversations.find((c) => c.id === 'B')?.messages.find((m) => m.id === 'mB');
    expect(aMsg?.state).toBe('interrupted');
    expect(aMsg?.text).toBe('partA');
    expect(bMsg?.state).toBe('generating');
    expect(selectIsStreamingFor('A')(state)).toBe(false);
    expect(selectIsStreamingFor('B')(state)).toBe(true);
  });

  it('4. lifecycle flush across streams writes back every message.text', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    const convC = makeConversation('C', 'mC');
    testStore.setState({ conversations: [convA, convB, convC] });
    registerFakeStream(testStore.getState(), 'A', 'mA');
    registerFakeStream(testStore.getState(), 'B', 'mB');
    registerFakeStream(testStore.getState(), 'C', 'mC');
    batchAppendStreaming('A', 'aaa');
    batchAppendStreaming('B', 'bbb');
    batchAppendStreaming('C', 'ccc');

    flushAllStreamsForLifecycle();

    const state = testStore.getState();
    expect(state.conversations.find((c) => c.id === 'A')!.messages[0].text).toBe('aaa');
    expect(state.conversations.find((c) => c.id === 'B')!.messages[0].text).toBe('bbb');
    expect(state.conversations.find((c) => c.id === 'C')!.messages[0].text).toBe('ccc');
    // state is still generating, since the stream may keep running.
    expect(state.conversations.find((c) => c.id === 'A')!.messages[0].state).toBe('generating');
  });

  it('5. pagehide backup writes a multi-stream map into sessionStorage', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    testStore.setState({ conversations: [convA, convB] });
    registerFakeStream(testStore.getState(), 'A', 'mA');
    registerFakeStream(testStore.getState(), 'B', 'mB');
    batchAppendStreaming('A', 'aaa');
    batchAppendStreaming('B', 'bbb');

    backupAllStreamsToSessionStorage();

    const map = readStreamPartialBackup();
    expect(map.A).toEqual(expect.objectContaining({
      conversationId: 'A',
      msgId: 'mA',
      partial: 'aaa',
    }));
    expect(map.B).toEqual(expect.objectContaining({
      conversationId: 'B',
      msgId: 'mB',
      partial: 'bbb',
    }));
  });

  it('6. abortAllStreams marks every message interrupted and leaves sessions and ids empty', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    const convC = makeConversation('C', 'mC');
    testStore.setState({ conversations: [convA, convB, convC] });
    const { abort: abortA } = registerFakeStream(testStore.getState(), 'A', 'mA');
    const { abort: abortB } = registerFakeStream(testStore.getState(), 'B', 'mB');
    const { abort: abortC } = registerFakeStream(testStore.getState(), 'C', 'mC');
    batchAppendStreaming('A', 'aa');
    batchAppendStreaming('B', 'bb');
    batchAppendStreaming('C', 'cc');

    abortAllStreams();

    expect(abortA).toHaveBeenCalled();
    expect(abortB).toHaveBeenCalled();
    expect(abortC).toHaveBeenCalled();
    const state = testStore.getState();
    expect(state.streamingConversationIds).toHaveLength(0);
    expect(state.conversations.every((c) => c.messages[0].state === 'interrupted')).toBe(true);
  });

  it('7. streamingConversationIds keeps a stable reference after many appended tokens', () => {
    const convA = makeConversation('A', 'mA');
    testStore.setState({ conversations: [convA] });
    registerFakeStream(testStore.getState(), 'A', 'mA');
    const idsBefore = selectStreamingConversationIds(testStore.getState());
    for (let i = 0; i < 50; i++) {
      batchAppendStreaming('A', 'x');
      flushPendingStreaming('A');
    }
    const idsAfter = selectStreamingConversationIds(testStore.getState());
    expect(idsAfter).toBe(idsBefore);
    expect(idsAfter).toEqual(['A']);
  });

  it('8. selector isolation: appending to A does not change B\'s selector output', () => {
    const convA = makeConversation('A', 'mA');
    const convB = makeConversation('B', 'mB');
    testStore.setState({ conversations: [convA, convB] });
    registerFakeStream(testStore.getState(), 'A', 'mA');
    registerFakeStream(testStore.getState(), 'B', 'mB');
    const beforeB = selectStreamingTextFor('B')(testStore.getState());
    batchAppendStreaming('A', 'foo');
    flushPendingStreaming('A');
    const afterB = selectStreamingTextFor('B')(testStore.getState());
    expect(beforeB).toBe(afterB);
    expect(selectStreamingTextFor('A')(testStore.getState())).toBe('foo');
  });
});
