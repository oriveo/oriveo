// @vitest-environment jsdom

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

// Partial mock: keep the real exports such as getRelayRuntimeConfig and
// DEFAULT_RELAY_RUNTIME_CONFIG and spy only on resolveCatalogModel. Otherwise
// buildProviderStreamOptions calling getRelayRuntimeConfig throws "No export defined", sendMessage
// silently takes the catch branch and sendStream is never called.
vi.mock('../../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../../metadata/metadata-client')>(
    '../../metadata/metadata-client',
  );
  return {
    ...actual,
    resolveCatalogModel: vi.fn(),
  };
});

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: '••••relay',
    baseURLText: 'https://relay.example.com/v1',
    relayResolvedBaseURLText: 'https://relay.example.com/v1',
    relayResolvedTransport: 'openai_responses',
    relayResolvedAuthMode: 'bearer',
    relayResolvedHeaderProfile: 'none',
    relayResolvedFamilyHint: 'openai',
    relayRequested: {
      transport: 'openai_responses',
      authMode: 'bearer',
      reasoningEffort: 'xhigh',
      serviceTier: 'fast',
      stream: true,
      disableResponseStorage: true,
    },
    relayImage: {
      enabled: true,
      mode: 'tool_model',
      toolModelID: 'gpt-image-2',
      outputFormat: 'png',
    },
    ...overrides,
  };
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-5.4',
    name: 'GPT-5.4',
    capabilities: ['text'],
    reasoningModeAvailable: true,
    isAvailable: true,
    isDefault: true,
    priceTier: 'standard',
    promptPrice: 0.001,
    completionPrice: 0.002,
    ...overrides,
  };
}

function makeConversation(message: ChatMessage, overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1',
    title: 'Relay Chat',
    hasCustomTitle: false,
    providerID: 'relay-1',
    modelID: 'gpt-5.4',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [message],
    draftText: '',
    updatedAt: '2026-04-23T00:00:00.000Z',
    ...overrides,
  };
}

describe('chat operations with relay image config', () => {
  beforeEach(() => {
    mocks.sendStream.mockReset();
    mocks.buildChatHistory.mockReset();
    mocks.readStream.mockReset();
    mocks.processImageAttachments.mockReset();
    mocks.enqueueUsageEvent.mockReset();
    mocks.checkBudgetExceeded.mockReset();

    mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hello' }]);
    mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
    mocks.readStream.mockResolvedValue({
      fullText: 'relay response',
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      imageAttachments: [],
      servedModelID: 'gpt-5.4',
    });
    mocks.processImageAttachments.mockResolvedValue({
      finalText: 'relay response',
      processedAttachments: [],
    });
    mocks.enqueueUsageEvent.mockResolvedValue(undefined);
  });

  it('sendMessage forwards the advanced relay request fields, and relayImage config produces no relayImageToolModelID', async () => {
    // model.capabilities plus imageGenProfile both being set gives supportsImageGen=true, used by
    // the Gemini transport. relayImage config is not forwarded to the stream options.
    const provider = makeProvider();
    const model = makeModel({
      capabilities: ['text', 'imageGeneration'],
      imageGenProfile: 'relay_image_profile',
    });
    const conversation = makeConversation({
      id: 'm-assistant-0',
      role: 'assistant',
      text: 'previous',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'Relay',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
    });
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });
    const quoteContext = {
      schemaVersion: 1 as const, sourceMessageId: 'source-relay', sourceRole: 'assistant' as const,
      contentKind: 'code' as const, leadingText: 'const ', selectedText: 'value',
      trailingText: ' = 42;', contextTruncated: false,
    };

    const handle = sendMessage(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        text: 'draw something',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        quoteContext,
      },
    );

    await handle.done;

    expect(mocks.buildChatHistory).toHaveBeenCalledWith(
      expect.arrayContaining([expect.objectContaining({ role: 'user', text: 'draw something', quoteContext })]),
      model,
      'relay',
    );

    expect(mocks.sendStream).toHaveBeenCalledWith(
      'relay',
      'sk-relay',
      'gpt-5.4',
      expect.any(Array),
      'https://relay.example.com/v1',
      expect.objectContaining({
        relayResolvedBaseURLText: 'https://relay.example.com/v1',
        relayTransport: 'openai_responses',
        relayAuthMode: 'bearer',
        relayHeaderProfile: 'none',
        relayFamilyHint: 'openai',
        relayServiceTier: 'fast',
        relayReasoningEffort: 'xhigh',
        relayDisableResponseStorage: true,
        // toolModelID is not forwarded to the adapter
        relayImageToolModelID: undefined,
        supportsImageGen: true,
      }),
    );
  });

  it('continueAnswering forwards the advanced relay fields too, and relayImage config produces no toolModelID', async () => {
    const provider = makeProvider();
    const model = makeModel({
      capabilities: ['text', 'imageGeneration'],
      imageGenProfile: 'relay_image_profile',
    });
    const interruptedMessage: ChatMessage = {
      id: 'm-assistant-1',
      role: 'assistant',
      text: 'Partial',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'Relay',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'interrupted',
    };
    const conversation = makeConversation(interruptedMessage);
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });

    const handle = continueAnswering(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        messageId: interruptedMessage.id,
        conversation,
        messages: conversation.messages,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle.done;

    expect(mocks.sendStream).toHaveBeenLastCalledWith(
      'relay',
      'sk-relay',
      'gpt-5.4',
      expect.any(Array),
      'https://relay.example.com/v1',
      expect.objectContaining({
        relayServiceTier: 'fast',
        relayReasoningEffort: 'xhigh',
        relayDisableResponseStorage: true,
        relayImageToolModelID: undefined,
        supportsImageGen: true,
      }),
    );
  });

  it('sendMessage passes relayRequested.stream=false into runtime stream options', async () => {
    const provider = makeProvider({
      relayResolvedTransport: 'openai_chat_completions',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        stream: false,
      },
      relayImage: undefined,
    });
    const model = makeModel();
    const conversation = makeConversation({
      id: 'm-assistant-2',
      role: 'assistant',
      text: 'previous',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'Relay',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'delivered',
    });
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
    });

    const handle = sendMessage(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        text: 'reply once',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle.done;

    expect(mocks.sendStream).toHaveBeenCalledWith(
      'relay',
      'sk-relay',
      'gpt-5.4',
      expect.any(Array),
      'https://relay.example.com/v1',
      expect.objectContaining({
        relayTransport: 'openai_chat_completions',
        relayStream: false,
      }),
    );
  });
});
