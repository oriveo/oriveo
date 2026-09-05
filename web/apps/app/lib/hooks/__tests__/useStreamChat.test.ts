import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => {
  const mockStopStream = vi.fn();
  const mockSendMessage = vi.fn();
  const mockContinueAnswering = vi.fn();
  const mockRetryLibraryMessage = vi.fn();
  const mockContinueLibraryAnswering = vi.fn();
  const mockSendLibraryMessage = vi.fn();
  const mockLoadChatOperations = vi.fn();
  const mockCancelManagedChat = vi.fn();
  const mockFetchManagedRequest = vi.fn();
  const mockLibraryFeatureEnabled = vi.fn();
  const mockSyncAdapter = {
    didCompleteAssistantMessage: vi.fn(),
    didCompleteRound: vi.fn(),
  };
  const mockUpdateConversation = vi.fn();
  const mockBeginStreamingForConversation = vi.fn();
  const mockClearStreamingForConversation = vi.fn();
  const mockSetStreamingText = vi.fn();
  const mockAppendStreamingText = vi.fn();
  const mockStoreState = {
    activeConversationId: 'conversation-1',
    streamingTexts: { 'conversation-1': 'Partial answer' } as Record<string, string>,
    streamingMessageIds: { 'conversation-1': 'assistant-1' } as Record<string, string>,
    streamingConversationIds: ['conversation-1'],
    conversations: [
      {
        id: 'conversation-1',
        providerID: 'provider-1',
        modelID: 'model-1',
        messages: [
          { id: 'user-1', role: 'user', text: 'Hello', state: 'delivered' },
          { id: 'assistant-1', role: 'assistant', text: '', state: 'generating' },
        ],
      },
    ],
    providers: [] as any[],
    updateConversation: mockUpdateConversation,
    beginStreamingForConversation: mockBeginStreamingForConversation,
    clearStreamingForConversation: mockClearStreamingForConversation,
    setStreamingText: mockSetStreamingText,
    appendStreamingText: mockAppendStreamingText,
  };

  return {
    mockStopStream,
    mockSendMessage,
    mockContinueAnswering,
    mockRetryLibraryMessage,
    mockContinueLibraryAnswering,
    mockSendLibraryMessage,
    mockLoadChatOperations,
    mockCancelManagedChat,
    mockFetchManagedRequest,
    mockLibraryFeatureEnabled,
    mockSyncAdapter,
    mockUpdateConversation,
    mockBeginStreamingForConversation,
    mockClearStreamingForConversation,
    mockSetStreamingText,
    mockAppendStreamingText,
    mockStoreState,
  };
});

vi.mock('next/navigation', () => ({
  useRouter: () => ({
    replace: vi.fn(),
  }),
}));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: any) => unknown) => selector(mocks.mockStoreState),
  getVanillaStore: () => ({
    getState: () => mocks.mockStoreState,
  }),
  tryGetVanillaStore: () => ({
    getState: () => mocks.mockStoreState,
  }),
}));

vi.mock('../../core/chat/operations', () => ({
  sendMessage: (...args: unknown[]) => mocks.mockSendMessage(...args),
  stopStream: (...args: unknown[]) => mocks.mockStopStream(...args),
}));

vi.mock('../../core/chat/operations-lazy', () => ({
  loadChatOperations: (...args: unknown[]) => mocks.mockLoadChatOperations(...args),
}));

vi.mock('../../core/chat/operations-library-send', () => ({
  sendLibraryMessage: (...args: unknown[]) =>
    mocks.mockSendLibraryMessage(...args),
  retryLibraryMessage: (...args: unknown[]) =>
    mocks.mockRetryLibraryMessage(...args),
  continueLibraryAnswering: (...args: unknown[]) =>
    mocks.mockContinueLibraryAnswering(...args),
}));

vi.mock('../../core/library/feature-flag', () => ({
  isLibraryFeatureEnabled: () => mocks.mockLibraryFeatureEnabled(),
}));

vi.mock('../../core/chat/stop-stream', () => ({
  stopStream: (...args: unknown[]) => mocks.mockStopStream(...args),
}));

vi.mock('../../core/managed/api', () => ({
  cancelManagedChat: (...args: unknown[]) => mocks.mockCancelManagedChat(...args),
  fetchManagedRequest: (...args: unknown[]) => mocks.mockFetchManagedRequest(...args),
}));

vi.mock('../../core/sync-port', () => ({
  getSyncAdapter: () => mocks.mockSyncAdapter,
}));

import {
  flushAndInterruptActiveStream,
  useStreamChat,
} from '../useStreamChat';
import {
  __resetActiveStreamsForTests,
  hasStream,
  listActiveStreamConversationIds,
} from '../../core/chat/active-streams';
import { selectIsStreamingFor } from '../../core/store/selectors';
import { __resetStreamBatcherForTests } from '../../core/chat/stream-batcher';
import {
  isNewConversationRoutePromotion,
  resetNewConversationRoutePromotionForTests,
} from '../../core/chat/route-transition';
import {
  clearStreamPartialBackup,
  readStreamPartialBackup,
  upsertStreamPartialBackup,
} from '../../core/store/stream-partial-backup';

const provider: any = {
  id: 'provider-1',
  kind: 'openai',
  apiKey: 'sk-test',
  apiKeyPreview: 'sk-...test',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
};

const currentModel: any = {
  id: 'model-1',
  name: 'Model 1',
  capabilities: [],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '$',
};

function resetState() {
  mocks.mockStopStream.mockReset();
  mocks.mockSendMessage.mockReset();
  mocks.mockContinueAnswering.mockReset();
  mocks.mockRetryLibraryMessage.mockReset();
  mocks.mockContinueLibraryAnswering.mockReset();
  mocks.mockSendLibraryMessage.mockReset();
  mocks.mockLoadChatOperations.mockReset();
  mocks.mockCancelManagedChat.mockReset();
  mocks.mockCancelManagedChat.mockResolvedValue(undefined);
  mocks.mockFetchManagedRequest.mockReset();
  mocks.mockLibraryFeatureEnabled.mockReset();
  mocks.mockLibraryFeatureEnabled.mockReturnValue(true);
  mocks.mockFetchManagedRequest.mockResolvedValue({
    requestId: 'mreq_1',
    clientRequestId: 'assistant-1',
    publicModelId: 'gpt-4.1',
    status: 'settled',
    finalStatus: 'settled',
    messageStatus: 'completed',
    settlement: {
      chargedMicrousd: 23000,
      releasedMicrousd: 477000,
      releasedToDebtMicrousd: 0,
      displayCharge: '$0.023',
      ledgerId: 'led_1',
    },
    availableBalanceMicrousd: 1177000,
    displayBalance: '$1.177',
  });
  mocks.mockSyncAdapter.didCompleteAssistantMessage.mockReset();
  mocks.mockSyncAdapter.didCompleteRound.mockReset();
  mocks.mockUpdateConversation.mockReset();
  mocks.mockBeginStreamingForConversation.mockReset();
  mocks.mockClearStreamingForConversation.mockReset();
  mocks.mockSetStreamingText.mockReset();
  mocks.mockAppendStreamingText.mockReset();
  mocks.mockStoreState.activeConversationId = 'conversation-1';
  mocks.mockStoreState.streamingTexts = { 'conversation-1': 'Partial answer' };
  mocks.mockStoreState.streamingMessageIds = { 'conversation-1': 'assistant-1' };
  mocks.mockStoreState.streamingConversationIds = ['conversation-1'];
  mocks.mockStoreState.conversations = [
    {
      id: 'conversation-1',
      providerID: 'provider-1',
      modelID: 'model-1',
      messages: [
        { id: 'user-1', role: 'user', text: 'Hello', state: 'delivered' },
        { id: 'assistant-1', role: 'assistant', text: '', state: 'generating' },
      ],
    },
  ];
  mocks.mockStoreState.providers = [];
  mocks.mockLoadChatOperations.mockResolvedValue({
    sendMessage: mocks.mockSendMessage,
    retryMessage: vi.fn(),
    continueAnswering: mocks.mockContinueAnswering,
    editAndResend: vi.fn(),
  });
  if (typeof window !== 'undefined') window.sessionStorage.clear();
  clearStreamPartialBackup();
  __resetActiveStreamsForTests();
  __resetStreamBatcherForTests();
  resetNewConversationRoutePromotionForTests();
}

describe('useStreamChat send', () => {
  beforeEach(resetState);

  it('loads chat operations lazily before sending a message', async () => {
    mocks.mockSendMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('Hello', [], undefined);
    });

    expect(mocks.mockLoadChatOperations).toHaveBeenCalledTimes(1);
    expect(mocks.mockSendMessage).toHaveBeenCalledTimes(1);
  });

  it('routes an explicit Library source mention through research when the composer toggle is off', async () => {
    mocks.mockSendLibraryMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      libraryResearchEnabled: false,
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('@Notion summarize the roadmap', [], undefined);
    });

    expect(mocks.mockSendLibraryMessage).toHaveBeenCalledTimes(1);
    expect(mocks.mockSendMessage).not.toHaveBeenCalled();
  });

  // Both sendLibraryMessage call sites (the composer send, and the one after initMetadata when the
  // first leg makes no tool call) used to keep their own duplicate errorDetails table and now share
  // libraryMessagePresentation(). This pins that the shared constant really carries the new
  // library_not_connected code and the messageKeys mapping, instead of one of two tables being updated.
  it('sendLibraryMessage receives presentation params carrying library_not_connected and the messageKeys mapping', async () => {
    mocks.mockSendLibraryMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      libraryResearchEnabled: true,
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('Summarize the roadmap', [], undefined);
    });

    expect(mocks.mockSendLibraryMessage).toHaveBeenCalledTimes(1);
    const [, params] = mocks.mockSendLibraryMessage.mock.calls[0];
    expect(params).toMatchObject({
      cancelledText: 'researchCancelled',
      errorTitle: 'researchErrorTitle',
      errorDetail: 'genericError',
      errorDetails: expect.objectContaining({
        library_not_connected: 'error.notConnected',
      }),
      messageKeys: {
        'library.error.sourceForbidden': 'error.sourceForbidden',
      },
    });
  });

  it('routes source mentions through normal chat and strips Library context when the feature is disabled', async () => {
    mocks.mockLibraryFeatureEnabled.mockReturnValue(false);
    mocks.mockSendMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });
    const documents = [{ docId: 'roadmap', source: 'notion' as const, title: 'Roadmap' }];

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      libraryResearchEnabled: true,
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('@Notion summarize the roadmap', [], undefined, [], [], documents);
    });

    expect(mocks.mockSendLibraryMessage).not.toHaveBeenCalled();
    expect(mocks.mockSendMessage).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ libraryContextDocuments: undefined }),
    );
  });

  it('routes selected Library documents through direct context even when research or a mention is enabled', async () => {
    mocks.mockSendMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const documents = [{ docId: 'roadmap', source: 'notion' as const, title: 'Roadmap' }];
    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      libraryResearchEnabled: true,
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('@Notion summarize this', [], undefined, [], [], documents);
    });

    expect(mocks.mockSendMessage).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({ libraryContextDocuments: documents }),
    );
    expect(mocks.mockSendLibraryMessage).not.toHaveBeenCalled();
  });

  it('restores selected Library documents when direct-context send fails', async () => {
    const onLibraryContextFailed = vi.fn();
    mocks.mockSendMessage.mockImplementation((_ctx, params) => {
      params.onFailed?.('question');
      return {
        abort: vi.fn(),
        convId: 'conversation-1',
        msgId: 'assistant-1',
        done: Promise.resolve(),
      };
    });
    const documents = [{ docId: 'roadmap', source: 'notion' as const, title: 'Roadmap' }];
    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
      onLibraryContextFailed,
    }));

    await act(async () => {
      await result.current.send('question', [], undefined, [], [], documents);
    });

    expect(onLibraryContextFailed).toHaveBeenCalledWith(documents);
  });

  it('marks a newly created conversation before promoting the route', async () => {
    mocks.mockSendMessage.mockImplementation((_ctx, params) => {
      params.onNewConversation?.('conversation-new');
      return {
        abort: vi.fn(),
        convId: 'conversation-new',
        msgId: 'assistant-new',
        done: Promise.resolve(),
      };
    });

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('Hello', [], undefined);
    });

    expect(isNewConversationRoutePromotion('conversation-new')).toBe(true);
  });

  it('does NOT abort a previous stream when sending to a different conversation', async () => {
    let resolveFirst: () => void = () => {};
    const firstDone = new Promise<void>((r) => { resolveFirst = r; });
    const firstAbort = vi.fn();
    const secondAbort = vi.fn();
    mocks.mockSendMessage.mockReturnValueOnce({
      abort: firstAbort,
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: firstDone,
    });
    mocks.mockSendMessage.mockReturnValueOnce({
      abort: secondAbort,
      convId: 'conversation-2',
      msgId: 'assistant-2',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      void result.current.send('Hello A', [], undefined);
      await Promise.resolve();
      await Promise.resolve();
    });

    // Second send goes to a different conversation; with multi-conversation streaming A must not be interrupted
    await act(async () => {
      void result.current.send('Hello B', [], undefined);
      await Promise.resolve();
      await Promise.resolve();
    });

    // The old stream must not be aborted
    expect(firstAbort).not.toHaveBeenCalled();
    // and it must not be marked interrupted either
    const interruptCall = mocks.mockUpdateConversation.mock.calls.find((call) =>
      Array.isArray(call[1]?.messages) &&
      call[1].messages.some((m: any) => m.id === 'assistant-1' && m.state === 'interrupted'),
    );
    expect(interruptCall).toBeUndefined();

    resolveFirst();
  });

  it('uses the latest conversation model from the store when the render snapshot is stale after a model switch', async () => {
    const staleProvider: any = {
      ...provider,
      id: 'provider-old',
      models: [{ ...currentModel, id: 'model-old', name: 'Old Model' }],
    };
    const freshProvider: any = {
      ...provider,
      id: 'provider-new',
      models: [{ ...currentModel, id: 'model-new', name: 'New Model' }],
    };
    const staleModel: any = staleProvider.models[0];
    const staleConversation: any = {
      id: 'conversation-1',
      providerID: staleProvider.id,
      providerKind: staleProvider.kind,
      modelID: staleModel.id,
      messages: [],
    };

    mocks.mockStoreState.providers = [staleProvider, freshProvider];
    mocks.mockStoreState.conversations = [{
      ...staleConversation,
      providerID: freshProvider.id,
      modelID: 'model-new',
    }];
    mocks.mockSendMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider: staleProvider,
      currentModel: staleModel,
      conversation: staleConversation,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.send('Hello after switch', [], staleConversation);
    });

    expect(mocks.mockSendMessage).toHaveBeenCalledTimes(1);
    expect(mocks.mockSendMessage.mock.calls[0][1]).toMatchObject({
      provider: expect.objectContaining({ id: 'provider-new' }),
      model: expect.objectContaining({ id: 'model-new' }),
      conversation: expect.objectContaining({
        id: 'conversation-1',
        providerID: 'provider-new',
        modelID: 'model-new',
      }),
    });
  });

});

describe('useStreamChat Library recovery routing', () => {
  beforeEach(resetState);

  it('retries a historical Library assistant even when the composer toggle is off', async () => {
    const conversation = mocks.mockStoreState.conversations[0] as any;
    conversation.messages[1] = {
      ...conversation.messages[1],
      state: 'failed',
      libraryResearchEnabled: true,
    };
    const normalRetry = vi.fn();
    mocks.mockLoadChatOperations.mockResolvedValue({
      retryMessage: normalRetry,
    });
    mocks.mockRetryLibraryMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      libraryResearchEnabled: false,
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.retry('assistant-1');
    });

    expect(mocks.mockRetryLibraryMessage).toHaveBeenCalledTimes(1);
    expect(normalRetry).not.toHaveBeenCalled();
  });

  // All three paths produce step rows (a pinned document is persisted with the message too), so the
  // steps are a progress display rather than a path marker: using them as the research-mode rule would send a message with user-pinned documents down the agent or server retrieval path on continuation.
  it('keeps a document-context message on the normal continuation path even when it carries research steps', async () => {
    const conversation = mocks.mockStoreState.conversations[0] as any;
    conversation.messages[1] = {
      ...conversation.messages[1],
      text: 'Partial answer',
      state: 'interrupted',
      libraryResearchEnabled: undefined,
      researchSteps: [
        {
          tool: 'library_read',
          label: 'Q3 Roadmap',
          status: 'completed',
        },
      ],
    };
    mocks.mockContinueAnswering.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      libraryResearchEnabled: false,
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.continueAnswering('assistant-1');
    });

    expect(mocks.mockContinueAnswering).toHaveBeenCalledTimes(1);
    expect(mocks.mockContinueLibraryAnswering).not.toHaveBeenCalled();
  });

  it('uses normal retry for historical Library messages when the feature is disabled', async () => {
    mocks.mockLibraryFeatureEnabled.mockReturnValue(false);
    const conversation = mocks.mockStoreState.conversations[0] as any;
    conversation.messages[1] = {
      ...conversation.messages[1],
      state: 'failed',
      libraryResearchEnabled: true,
    };
    const normalRetry = vi.fn().mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });
    mocks.mockLoadChatOperations.mockResolvedValue({ retryMessage: normalRetry });

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await result.current.retry('assistant-1');
    });

    expect(normalRetry).toHaveBeenCalledTimes(1);
    expect(mocks.mockRetryLibraryMessage).not.toHaveBeenCalled();
  });
});

/**
 * Make the stream dictionary of the mock store actually react to actions.
 * The default fixture only records calls without changing state, which cannot verify rules such as whether streamingTexts has a key.
 */
function wireStreamingDictMocks() {
  mocks.mockBeginStreamingForConversation.mockImplementation((convId: string, msgId: string) => {
    mocks.mockStoreState.streamingTexts = { ...mocks.mockStoreState.streamingTexts, [convId]: '' };
    mocks.mockStoreState.streamingMessageIds = { ...mocks.mockStoreState.streamingMessageIds, [convId]: msgId };
    if (!mocks.mockStoreState.streamingConversationIds.includes(convId)) {
      mocks.mockStoreState.streamingConversationIds = [...mocks.mockStoreState.streamingConversationIds, convId];
    }
  });
  mocks.mockSetStreamingText.mockImplementation((convId: string, text: string) => {
    mocks.mockStoreState.streamingTexts = { ...mocks.mockStoreState.streamingTexts, [convId]: text };
  });
  mocks.mockClearStreamingForConversation.mockImplementation((convId: string) => {
    const nextTexts = { ...mocks.mockStoreState.streamingTexts };
    const nextMsgIds = { ...mocks.mockStoreState.streamingMessageIds };
    delete nextTexts[convId];
    delete nextMsgIds[convId];
    mocks.mockStoreState.streamingTexts = nextTexts;
    mocks.mockStoreState.streamingMessageIds = nextMsgIds;
    mocks.mockStoreState.streamingConversationIds =
      mocks.mockStoreState.streamingConversationIds.filter((id: string) => id !== convId);
  });
  mocks.mockStoreState.streamingTexts = {};
  mocks.mockStoreState.streamingMessageIds = {};
  mocks.mockStoreState.streamingConversationIds = [];
}

/** Hold loadChatOperations open to create the window where the dynamic import has not resolved yet */
function suspendChatOperations(): (ops: unknown) => void {
  let resolveOps: (ops: unknown) => void = () => {};
  mocks.mockLoadChatOperations.mockReturnValue(new Promise((resolve) => { resolveOps = resolve; }));
  return (ops: unknown) => resolveOps(ops);
}

describe('useStreamChat placeholder registration during the dynamic import window', () => {
  beforeEach(resetState);

  it('continuation: streaming state is entered before the import resolves, visible to both the selector and sessions', async () => {
    wireStreamingDictMocks();
    const resolveOps = suspendChatOperations();
    const conversation = mocks.mockStoreState.conversations[0] as any;
    conversation.messages[1].state = 'interrupted';
    conversation.messages[1].text = 'partial so far';

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    let pending: Promise<void> | undefined;
    await act(async () => {
      pending = result.current.continueAnswering('assistant-1');
      await Promise.resolve();
    });

    // Both sides of the rule have to light up, otherwise stop, the pagehide backup and an overriding send would all miss this stream
    expect(selectIsStreamingFor('conversation-1')(mocks.mockStoreState as any)).toBe(true);
    expect(hasStream('conversation-1')).toBe(true);
    expect(mocks.mockSetStreamingText).toHaveBeenCalledWith('conversation-1', 'partial so far');
    expect(mocks.mockContinueAnswering).not.toHaveBeenCalled();

    mocks.mockContinueAnswering.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });
    await act(async () => {
      resolveOps({ continueAnswering: mocks.mockContinueAnswering });
      await pending;
    });
    expect(mocks.mockContinueAnswering).toHaveBeenCalledTimes(1);
  });

  it('  import resolve  ', async () => {
    wireStreamingDictMocks();
    const resolveOps = suspendChatOperations();
    const conversation = mocks.mockStoreState.conversations[0] as any;

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    let pending: Promise<void> | undefined;
    await act(async () => {
      pending = result.current.send('Hello', conversation.messages, conversation);
      await Promise.resolve();
    });

    expect(selectIsStreamingFor('conversation-1')(mocks.mockStoreState as any)).toBe(true);
    expect(hasStream('conversation-1')).toBe(true);
    expect(mocks.mockSendMessage).not.toHaveBeenCalled();

    mocks.mockSendMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });
    await act(async () => {
      resolveOps({ sendMessage: mocks.mockSendMessage });
      await pending;
    });
    expect(mocks.mockSendMessage).toHaveBeenCalledTimes(1);
  });

  it('stops a reserved continue before chat operations load', async () => {
    wireStreamingDictMocks();
    mocks.mockStopStream.mockImplementation((...args: unknown[]) => {
      (args[4] as (() => void) | null)?.();
    });
    const resolveOps = suspendChatOperations();
    const conversation = mocks.mockStoreState.conversations[0] as any;
    conversation.messages[1] = {
      id: 'assistant-1',
      role: 'assistant',
      text: 'partial so far',
      state: 'interrupted',
    };

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    let pending: Promise<void> | undefined;
    await act(async () => {
      pending = result.current.continueAnswering('assistant-1');
      await Promise.resolve();
    });

    act(() => {
      result.current.stop();
    });

    expect(mocks.mockStopStream).toHaveBeenCalledWith(
      expect.anything(),
      conversation,
      conversation.messages,
      'partial so far',
      expect.any(Function),
      expect.objectContaining({
        msgId: 'assistant-1',
        isRecovery: true,
      }),
    );

    await act(async () => {
      resolveOps({ continueAnswering: mocks.mockContinueAnswering });
      await pending;
    });
    expect(mocks.mockContinueAnswering).not.toHaveBeenCalled();
    expect(hasStream('conversation-1')).toBe(false);
    expect(selectIsStreamingFor('conversation-1')(mocks.mockStoreState as any)).toBe(false);
  });

  it('dynamic import failure: the placeholder stream state is cleaned up so the composer does not lock permanently', async () => {
    wireStreamingDictMocks();
    mocks.mockLoadChatOperations.mockRejectedValue(new Error('chunk load failed'));
    const conversation = mocks.mockStoreState.conversations[0] as any;

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      await expect(result.current.continueAnswering('assistant-1')).rejects.toThrow('chunk load failed');
    });

    expect(hasStream('conversation-1')).toBe(false);
    expect(selectIsStreamingFor('conversation-1')(mocks.mockStoreState as any)).toBe(false);
    expect(mocks.mockClearStreamingForConversation).toHaveBeenCalledWith('conversation-1');
  });

  it('sending again in the same conversation during the placeholder window: sessions keeps a single entry and the placeholder handle is aborted rather than lost', async () => {
    wireStreamingDictMocks();
    const resolveOps = suspendChatOperations();
    const conversation = mocks.mockStoreState.conversations[0] as any;

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation,
      messages: conversation.messages,
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    let firstPending: Promise<void> | undefined;
    let secondPending: Promise<void> | undefined;
    await act(async () => {
      firstPending = result.current.send('Hello A', conversation.messages, conversation);
      await Promise.resolve();
      secondPending = result.current.send('Hello B', conversation.messages, conversation);
      await Promise.resolve();
    });

    expect(listActiveStreamConversationIds()).toEqual(['conversation-1']);

    mocks.mockSendMessage.mockReturnValue({
      abort: vi.fn(),
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: Promise.resolve(),
    });
    await act(async () => {
      resolveOps({ sendMessage: mocks.mockSendMessage });
      await Promise.all([firstPending, secondPending]);
    });

    // The earlier placeholder is aborted by the later send (the handle was not lost, so it stands down on its own) and only one stream really starts
    expect(mocks.mockSendMessage).toHaveBeenCalledTimes(1);
    expect(listActiveStreamConversationIds()).toHaveLength(0);
  });
});

describe('flushAndInterruptActiveStream (sign-out / global)', () => {
  beforeEach(resetState);

  it('aborts all active streams and clears sessionStorage backup', async () => {
    let resolveDone: () => void = () => {};
    const donePromise = new Promise<void>((r) => { resolveDone = r; });
    const abortFn = vi.fn();
    mocks.mockSendMessage.mockReturnValue({
      abort: abortFn,
      convId: 'conversation-1',
      msgId: 'assistant-1',
      done: donePromise,
    });

    const { result } = renderHook(() => useStreamChat({
      provider, currentModel,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));

    await act(async () => {
      void result.current.send('Hello', [], undefined);
      await Promise.resolve();
      await Promise.resolve();
    });

    // Store a backup first to verify flushAndInterruptActiveStream clears it
    upsertStreamPartialBackup({
      conversationId: 'conversation-1',
      msgId: 'assistant-1',
      partial: 'Partial answer',
      ts: 1,
    });
    expect(Object.keys(readStreamPartialBackup())).toContain('conversation-1');

    flushAndInterruptActiveStream();
    expect(abortFn).toHaveBeenCalled();
    // streamingConversationIds is cleared by active-streams through a store action
    expect(mocks.mockClearStreamingForConversation).toHaveBeenCalledWith('conversation-1');
    expect(Object.keys(readStreamPartialBackup())).toHaveLength(0);

    resolveDone();
  });
});

describe('sessionStorage backup module (multi-conversation map)', () => {
  beforeEach(resetState);

  it('round-trips multiple backup payloads via sessionStorage', () => {
    upsertStreamPartialBackup({
      conversationId: 'c1',
      msgId: 'm1',
      partial: 'hello world',
      ts: 12345,
    });
    upsertStreamPartialBackup({
      conversationId: 'c2',
      msgId: 'm2',
      partial: 'second stream',
      ts: 22222,
    });
    const map = readStreamPartialBackup();
    expect(map.c1).toEqual({
      conversationId: 'c1',
      msgId: 'm1',
      partial: 'hello world',
      ts: 12345,
    });
    expect(map.c2).toEqual({
      conversationId: 'c2',
      msgId: 'm2',
      partial: 'second stream',
      ts: 22222,
    });
    // Clearing one conversation leaves the others alone
    clearStreamPartialBackup('c1');
    const after = readStreamPartialBackup();
    expect(after.c1).toBeUndefined();
    expect(after.c2).toBeDefined();
    // Clear everything
    clearStreamPartialBackup();
    expect(Object.keys(readStreamPartialBackup())).toHaveLength(0);
  });
});
