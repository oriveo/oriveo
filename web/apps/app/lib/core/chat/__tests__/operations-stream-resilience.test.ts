// @vitest-environment jsdom
//
// Guard regressions in the operations layer for uninterrupted streaming.
// After an abort, readStream returns normally through ctrl.close() rather than throwing, and the
// completion paths of sendMessage / continueAnswering must notice that something else already
// marked the message interrupted or failed and leave that state alone.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { continueAnswering, sendMessage } from '../operations';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  processImageAttachments: vi.fn(),
  enqueueUsageEvent: vi.fn(),
  checkBudgetExceeded: vi.fn(),
}));

vi.mock('../../providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../../../utils/chat-stream-utils', () => ({
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
  mapErrorKindKey: () => 'network',
  sanitizeOutboundMessages: (msgs: unknown[]) => msgs,
}));

vi.mock('../../../utils/stream-image-utils', () => ({
  processImageAttachments: (...args: unknown[]) => mocks.processImageAttachments(...args),
  backfillStorageRefs: vi.fn(),
}));

vi.mock('../../usage/usage-reporter', () => ({
  enqueueUsageEvent: (...args: unknown[]) => mocks.enqueueUsageEvent(...args),
}));

vi.mock('../../usage/budget-check', () => ({
  checkBudgetExceeded: (...args: unknown[]) => mocks.checkBudgetExceeded(...args),
}));

vi.mock('../../sync-port', () => ({
  getSyncAdapter: () => undefined,
  deleteAttachments: vi.fn(),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUID: vi.fn(),
}));

vi.mock('../../skills/knowledge-api', () => ({
  retrieveKnowledgeSnippets: vi.fn(),
}));

// Keep the real exports and mock only what has to be mocked: a factory that replaces the whole
// module and misses an export the send path uses (getCapabilityRuntime, which operations-send
// calls unconditionally) makes the send path throw "undefined is not a function" before dispatch,
// failing the test far away from the behavior under test.
vi.mock('../../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../../metadata/metadata-client')>(
    '../../metadata/metadata-client',
  );
  return {
    ...actual,
    // This fixture has no metadata ETag, so identity gets no revision and the negative cache fails closed.
    getMetadataRevision: () => undefined,
    // The send path goes through activeGenerationParameterIds -> resolveGenerationProfileForModel,
    // which calls this export unconditionally; this fixture has no metadata profile anyway.
    resolveGenerationProfileRef: vi.fn(() => undefined),
    resolveCatalogModel: vi.fn(),
    getDeclaredReasoningLevels: vi.fn(() => []),
    getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
    getRelayRuntimeConfig: vi.fn(() => null),
  };
});

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
    promptPrice: 0.001,
    completionPrice: 0.002,
  };
}

function makeConversation(messages: ChatMessage[]): Conversation {
  return {
    id: 'conv-1',
    title: 'Test',
    hasCustomTitle: false,
    providerID: 'p-1',
    modelID: 'gpt-4',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt: '2026-05-06T00:00:00.000Z',
  };
}

describe('operations guard: an abort must not overwrite a terminal state set elsewhere', () => {
  beforeEach(() => {
    mocks.sendStream.mockReset();
    mocks.buildChatHistory.mockReset();
    mocks.readStream.mockReset();
    mocks.processImageAttachments.mockReset();
    mocks.enqueueUsageEvent.mockReset();
    mocks.checkBudgetExceeded.mockReset();

    mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
    mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
    mocks.processImageAttachments.mockResolvedValue({
      finalText: 'should not be applied',
      processedAttachments: [],
    });
    mocks.enqueueUsageEvent.mockResolvedValue(undefined);
  });

  it('sendMessage appending to an existing conversation: once the assistant is marked interrupted elsewhere, the completion path does not overwrite it with delivered', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg: ChatMessage = {
      id: 'u1',
      role: 'user',
      text: 'previous user',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
    };
    const conversation = makeConversation([userMsg]);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });

    // Mocked readStream: simulates the guard marking the new assistantMsg interrupted while readStream runs
    mocks.readStream.mockImplementation(async () => {
      const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
      const assistantMsg = conv?.messages.find((m) => m.role === 'assistant' && m.state === 'generating');
      if (assistantMsg && conv) {
        store.getState().updateConversation(conv.id, {
          messages: conv.messages.map((m) =>
            m.id === assistantMsg.id ? { ...m, state: 'interrupted' as const, text: 'partial' } : m,
          ),
        });
      }
      return { fullText: 'fake-complete-text', reasoningText: '', usage: undefined, imageAttachments: [], servedModelID: 'gpt-4' };
    });

    const handle = sendMessage(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        text: 'new turn',
        prevMessages: [userMsg],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle.done;

    const finalConv = store.getState().conversations[0];
    const assistantMsg = finalConv?.messages.find((m) => m.role === 'assistant');
    // The guard works: the completion path sees interrupted and returns instead of overwriting with delivered
    expect(assistantMsg?.state).toBe('interrupted');
    expect(assistantMsg?.text).toBe('partial');
    expect(mocks.enqueueUsageEvent).not.toHaveBeenCalled();
  });

  it('sendMessage keeps the citations that already arrived on the stream after the message is marked interrupted elsewhere', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg: ChatMessage = {
      id: 'u1',
      role: 'user',
      text: 'previous user',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
    };
    const conversation = makeConversation([userMsg]);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });
    const citations = [{ url: 'https://source.example/a', title: 'Source A' }];

    mocks.readStream.mockImplementation(async () => {
      const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
      const assistantMsg = conv?.messages.find((m) => m.role === 'assistant' && m.state === 'generating');
      if (assistantMsg && conv) {
        store.getState().updateConversation(conv.id, {
          messages: conv.messages.map((m) =>
            m.id === assistantMsg.id ? { ...m, state: 'interrupted' as const, text: 'partial' } : m,
          ),
        });
      }
      return { fullText: 'fake-complete-text', reasoningText: '', usage: undefined, imageAttachments: [], servedModelID: 'gpt-4', citations };
    });

    const handle = sendMessage(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        text: 'new turn',
        prevMessages: [userMsg],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle.done;

    const finalConv = store.getState().conversations[0];
    const assistantMsg = finalConv?.messages.find((m) => m.role === 'assistant');
    expect(assistantMsg?.state).toBe('interrupted');
    expect(assistantMsg?.text).toBe('partial');
    expect(assistantMsg?.citations).toEqual(citations);
    expect(mocks.enqueueUsageEvent).not.toHaveBeenCalled();
  });

  it('continueAnswering: once the assistant is marked interrupted elsewhere, the completion path does not overwrite it', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const interruptedMsg: ChatMessage = {
      id: 'msg-1',
      role: 'assistant',
      text: 'partial',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'generating',
    };
    const conversation = makeConversation([interruptedMsg]);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });

    mocks.readStream.mockImplementation(async () => {
      // Simulate something outside marking msg-1 interrupted
      const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
      store.getState().updateConversation('conv-1', {
        messages: conv!.messages.map((m) =>
          m.id === 'msg-1' ? { ...m, state: 'interrupted' as const, text: 'partial-stopped' } : m,
        ),
      });
      return { fullText: 'fake-complete', reasoningText: '', usage: undefined, imageAttachments: [], servedModelID: 'gpt-4' };
    });

    const handle = continueAnswering(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        messageId: 'msg-1',
        conversation,
        messages: [interruptedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );
    await handle.done;

    const finalMsg = store.getState().conversations[0]?.messages.find((m) => m.id === 'msg-1');
    expect(finalMsg?.state).toBe('interrupted');
    expect(finalMsg?.text).toBe('partial-stopped');
    expect(mocks.enqueueUsageEvent).not.toHaveBeenCalled();
  });

  it('sendMessage writes the partial text and reasoning produced so far into the failed message when the stream fails midway, instead of clearing them', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg: ChatMessage = {
      id: 'u1',
      role: 'user',
      text: 'previous user',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
    };
    const conversation = makeConversation([userMsg]);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });

    // Produce a partial answer and then fail, which is what an upstream dropping mid-stream does.
    mocks.readStream.mockImplementation(async () => {
      store.getState().setStreamingText('conv-1', 'half of the answer so far');
      store.getState().appendStreamingReasoningText('conv-1', 'a fragment of thinking');
      throw { kind: 'upstream', message: 'Upstream HTTP 500', detail: 'boom' };
    });

    const handle = sendMessage(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        text: 'new turn',
        prevMessages: [userMsg],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle.done;

    const finalConv = store.getState().conversations[0];
    const assistantMsg = finalConv?.messages.find((m) => m.role === 'assistant');
    expect(assistantMsg?.state).toBe('failed');
    // The partial content is kept rather than cleared
    expect(assistantMsg?.text).toBe('half of the answer so far');
    expect(assistantMsg?.reasoningText).toBe('a fragment of thinking');
    expect(assistantMsg?.errorTitle).toBeTruthy();
    // The streaming dictionary was cleaned up in finally
    expect(store.getState().streamingTexts['conv-1']).toBeUndefined();
  });

  it('continueAnswering keeps the partial (existingText plus this round increment) and concatenates the earlier reasoning when the continuation stream fails', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const interruptedMsg: ChatMessage = {
      id: 'msg-1',
      role: 'assistant',
      text: 'the delivered first half',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'interrupted',
      reasoningText: 'earlier thinking',
    };
    const conversation = makeConversation([interruptedMsg]);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });

    // A continuation starts from setStreamingText(existingText) and appends this round increment; the reasoning partial holds only this round chunks
    mocks.readStream.mockImplementation(async () => {
      store.getState().appendStreamingText('conv-1', ' and this round increment');
      store.getState().appendStreamingReasoningText('conv-1', 'this round thinking');
      throw { kind: 'upstream', message: 'Upstream HTTP 500', detail: 'boom' };
    });

    const handle = continueAnswering(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        messageId: 'msg-1',
        conversation,
        messages: [interruptedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );
    await handle.done;

    const finalMsg = store.getState().conversations[0]?.messages.find((m) => m.id === 'msg-1');
    expect(finalMsg?.state).toBe('failed');
    // streamingTexts = existingText plus the append from this round
    expect(finalMsg?.text).toBe('the delivered first half and this round increment');
    // reasoning = the earlier reasoning plus this round
    expect(finalMsg?.reasoningText).toBe('earlier thinking\n\nthis round thinking');
    expect(finalMsg?.errorTitle).toBeTruthy();
    expect(store.getState().streamingTexts['conv-1']).toBeUndefined();
  });

  it('continueAnswering merges the earlier citations with the new ones after the message is marked interrupted elsewhere', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const interruptedMsg: ChatMessage = {
      id: 'msg-1',
      role: 'assistant',
      text: 'partial',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'generating',
      citations: [{ url: 'https://source.example/old', title: 'Old' }],
    };
    const conversation = makeConversation([interruptedMsg]);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });
    const nextCitations = [{ url: 'https://source.example/new', title: 'New' }];

    mocks.readStream.mockImplementation(async () => {
      const conv = store.getState().conversations.find((c) => c.id === 'conv-1');
      store.getState().updateConversation('conv-1', {
        messages: conv!.messages.map((m) =>
          m.id === 'msg-1' ? { ...m, state: 'interrupted' as const, text: 'partial-stopped' } : m,
        ),
      });
      return { fullText: 'fake-complete', reasoningText: '', usage: undefined, imageAttachments: [], servedModelID: 'gpt-4', citations: nextCitations };
    });

    const handle = continueAnswering(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        messageId: 'msg-1',
        conversation,
        messages: [interruptedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );
    await handle.done;

    const finalMsg = store.getState().conversations[0]?.messages.find((m) => m.id === 'msg-1');
    expect(finalMsg?.state).toBe('interrupted');
    expect(finalMsg?.text).toBe('partial-stopped');
    expect(finalMsg?.citations).toEqual([
      { url: 'https://source.example/old', title: 'Old' },
      { url: 'https://source.example/new', title: 'New' },
    ]);
    expect(mocks.enqueueUsageEvent).not.toHaveBeenCalled();
  });
});
