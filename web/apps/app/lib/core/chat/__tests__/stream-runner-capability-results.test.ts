import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider, AIModel } from '@oriveo/shared';
import { runStreamPipeline } from '../stream-runner';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  readStream: vi.fn(),
  createPartialFlushScheduler: vi.fn(),
  applyCitationsToMessage: vi.fn(),
}));

vi.mock('../../providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../../../utils/chat-stream-utils', () => ({
  readStream: (...args: unknown[]) => mocks.readStream(...args),
}));

vi.mock('../partial-flush', () => ({
  createPartialFlushScheduler: (...args: unknown[]) => mocks.createPartialFlushScheduler(...args),
}));

vi.mock('../cost-fields', () => ({
  applyCitationsToMessage: (...args: unknown[]) => mocks.applyCitationsToMessage(...args),
}));

function proxyProvider(): Provider {
  return {
    id: 'connection-local-only',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'secret',
    apiKeyPreview: '••••',
  };
}

function model(): AIModel {
  return {
    id: 'gpt-4.1',
    name: 'GPT-4.1',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '$2.50 / 1M input',
  };
}

function store() {
  const conversations = [{
    id: 'conv-1',
    messages: [{ id: 'assistant-1', state: 'generating' }],
  }];
  return {
    getState: () => ({
      appendStreamingReasoningText: vi.fn(),
      conversations,
      updateConversation: (_id: string, patch: { messages: unknown[] }) => {
        conversations[0] = { ...conversations[0], messages: patch.messages as typeof conversations[0]['messages'] };
      },
    }),
  } as never;
}

describe('runStreamPipeline wire result states', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.createPartialFlushScheduler.mockReturnValue({
      onChunk: vi.fn(),
      dispose: vi.fn(),
    });
  });

  it('writes requested only after the final proxy dispatch exposes its context, then keeps generic failures out of rejected', async () => {
    const state = store();
    mocks.sendStream.mockReturnValue({
      stream: {} as ReadableStream,
      abort: vi.fn(),
      getCapabilityResultContext: () => ({
        version: 1,
        revision: 'runtime-r3',
        entries: [{
          owner: 'web', source: 'provider_recipe', wireApplied: true,
          protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1',
          definition: { capability: 'web', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1', signals: [] },
        }],
      }),
    });
    mocks.readStream.mockImplementation(async () => {
      throw new Error('upstream 429 timeout');
    });

    const error = await runStreamPipeline({
      store: state,
      appendChunk: vi.fn(),
      conversationId: 'conv-1',
      messageId: 'assistant-1',
      provider: proxyProvider(),
      model: model(),
      chatHistory: [{ role: 'user', content: 'hello' }],
      initialText: '',
      relayStreamOptions: undefined,
      setAbortFn: vi.fn(),
    }).catch((caught: unknown) => caught as Error & { capabilityResults?: unknown[] });

    expect(state.getState().conversations[0]?.messages[0]).toMatchObject({
      capabilityResults: [{ owner: 'web', state: 'requested', source: 'provider_recipe' }],
    });
    expect(error.capabilityResults).toEqual([{ owner: 'web', state: 'requested', source: 'provider_recipe', revision: 'runtime-r3' }]);
  });
});
