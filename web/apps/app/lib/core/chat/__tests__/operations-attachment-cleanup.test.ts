// @vitest-environment jsdom

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { editAndResend, retryMessage } from '../operations';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  processImageAttachments: vi.fn(),
  deleteAttachments: vi.fn(),
  getActiveUID: vi.fn(),
  getActiveUIDSync: vi.fn(),
  syncAdapter: {
    didSendMessage: vi.fn(),
    didCompleteAssistantMessage: vi.fn(),
    didRegenerate: vi.fn(),
    didDeleteMessages: vi.fn(),
  },
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
  getSyncAdapter: () => mocks.syncAdapter,
  deleteAttachments: (...args: unknown[]) => mocks.deleteAttachments(...args),
}));

vi.mock('../../../infra/storage/partition', () => ({
  getActiveUID: (...args: unknown[]) => mocks.getActiveUID(...args),
  getActiveUIDSync: (...args: unknown[]) => mocks.getActiveUIDSync(...args),
}));

vi.mock('../../skills/knowledge-api', () => ({
  retrieveKnowledgeSnippets: vi.fn(),
}));

// Keep the real exports and mock only what has to be mocked: a factory that replaces the whole
// module will miss any export the send chain later adds (such as the getCapabilityRuntime that
// operations-send now calls unconditionally), and the send chain then throws "undefined is not a function" before dispatch, turning the test red somewhere unrelated to the behavior under test.
vi.mock('../../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../../metadata/metadata-client')>(
    '../../metadata/metadata-client',
  );
  return {
    ...actual,
    // These fixtures have no metadata ETag, so identity cannot get a revision and the negative cache fails closed.
    getMetadataRevision: () => undefined,
    resolveCatalogModel: vi.fn(),
    resolveGenerationProfileRef: vi.fn(() => undefined),
    getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
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
    apiKeyPreview: 'test',
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
    promptPrice: 0,
    completionPrice: 0,
  };
}

function makeConversation(messages: ChatMessage[]): Conversation {
  return {
    id: 'conv-1',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: 'p-1',
    modelID: 'gpt-4',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt: '2026-05-11T00:00:00.000Z',
  };
}

describe('chat operation attachment cleanup', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getActiveUID.mockResolvedValue('user-1');
    mocks.getActiveUIDSync.mockReturnValue('user-1');
    mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hello' }]);
    mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
    mocks.readStream.mockResolvedValue({
      fullText: 'done',
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
      imageAttachments: [],
    });
    mocks.processImageAttachments.mockResolvedValue({ finalText: 'done', processedAttachments: [] });
    mocks.enqueueUsageEvent.mockResolvedValue(undefined);
  });

  it('retryMessage deletes removed assistant attachment refs but preserves the user attachment being resent', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const user: ChatMessage = {
      id: 'm-user',
      role: 'user',
      text: 'hello',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
      attachments: [{
        id: 'att-user',
        kind: 'image',
        fileName: 'user.png',
        mimeType: 'image/png',
        storageRef: 'users/user-1/attachments/user-image',
      }],
    };
    const assistant: ChatMessage = {
      id: 'm-assistant',
      role: 'assistant',
      text: 'old',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
      attachments: [{
        id: 'att-assistant',
        kind: 'image',
        fileName: 'assistant.png',
        mimeType: 'image/png',
        storageRef: 'users/user-1/attachments/assistant-image',
      }],
    };
    const conversation = makeConversation([user, assistant]);
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = retryMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: assistant.id,
        conversation,
        messages: conversation.messages,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle?.done;

    expect(mocks.deleteAttachments).toHaveBeenCalledWith('user-1', ['users/user-1/attachments/assistant-image']);
  });

  it('retryMessage keeps the original user message when retrying a failed assistant response', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const user: ChatMessage = {
      id: 'm-user',
      role: 'user',
      text: 'hello',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
    };
    const failedAssistant: ChatMessage = {
      id: 'm-assistant',
      role: 'assistant',
      text: '',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'failed',
      errorTitle: 'Request Failed',
      errorDetail: 'temporary upstream error',
    };
    const conversation = makeConversation([user, failedAssistant]);
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = retryMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: failedAssistant.id,
        conversation,
        messages: conversation.messages,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle?.done;

    const updated = store.getState().conversations.find((c) => c.id === conversation.id);
    expect(updated?.messages.filter((m) => m.role === 'user')).toHaveLength(1);
    expect(updated?.messages[0]?.id).toBe(user.id);
    expect(mocks.syncAdapter.didRegenerate).not.toHaveBeenCalledWith(
      expect.arrayContaining([user.id]),
      conversation.id,
      expect.anything(),
    );
    const historyArg = mocks.buildChatHistory.mock.calls.at(-1)?.[0] as ChatMessage[];
    expect(historyArg.filter((m) => m.role === 'user' && m.text === user.text)).toHaveLength(1);
  });

  it('editAndResend deletes all removed attachment refs', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const user: ChatMessage = {
      id: 'm-user',
      role: 'user',
      text: 'hello',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
      attachments: [{
        id: 'att-user',
        kind: 'image',
        fileName: 'user.png',
        mimeType: 'image/png',
        storageRef: 'users/user-1/attachments/user-image',
      }],
    };
    const assistant: ChatMessage = {
      id: 'm-assistant',
      role: 'assistant',
      text: 'old',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
      attachments: [{
        id: 'att-assistant',
        kind: 'image',
        fileName: 'assistant.png',
        mimeType: 'image/png',
        storageRef: 'users/user-1/attachments/assistant-image',
      }],
    };
    const conversation = makeConversation([user, assistant]);
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = editAndResend(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: user.id,
        newText: 'edited',
        conversation,
        messages: conversation.messages,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle?.done;

    expect(mocks.deleteAttachments).toHaveBeenCalledWith('user-1', [
      'users/user-1/attachments/user-image',
      'users/user-1/attachments/assistant-image',
    ]);
  });
});
