import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Persisting the source of a parameter-rejection record: goes through the production sendMessage and asserts on the failed message actually in the store.
 * An official connection with a signature hit -> generationParameterRejection carries signatureId; a relay only has the generic panel verdict -> it does not.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../utils/chat-stream-utils')>('../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../metadata/metadata-client';
import { sendMessage } from './operations';
import { beginCapabilityEvidenceIdentityIfAbsent } from '../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { batchAppendStreaming } from './stream-batcher';
import { sendStreamProxy } from '../providers/proxy-client';
import {
  generationParameterProfileFingerprint,
  saveGenerationParameterOverrides,
  valueOverride,
} from './generation-parameter-settings';

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-08-08T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: {
        temperature: { group: 'sampling', valueSchema: 'number', portability: 'portable' },
        max_output_tokens: { group: 'budget', valueSchema: 'integer', portability: 'portable' },
      },
      templates: {
        openai_chat_completions: {
          transport: 'openai_chat_completions',
          wire: { temperature: 'temperature', max_output_tokens: 'max_tokens' },
        },
      },
    },
  },
  providers: {},
  providerConfigs: [],
};

const provider = {
  id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const model = {
  id: 'my-private-model', name: 'my-private-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;
// Official DashScope connection: the signature table recognizes its "enable_search not supported" error body.
const qwenModel = {
  id: 'qwen-plus', name: 'qwen-plus', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  transport: 'openai_chat_completions',
} as AIModel;
const qwen = {
  id: 'official-qwen', kind: 'qwen', status: { kind: 'connected' }, models: [qwenModel], catalogModels: [qwenModel],
  apiKey: 'sk-qwen', apiKeyPreview: '••', authMode: 'apiKey',
} as unknown as Provider;
const scope = () => ({
  providerId: provider.id, modelId: model.id, conversationId: 'conv-1',
  profileFingerprint: generationParameterProfileFingerprint(provider, model),
});

const sentBodies: Record<string, unknown>[] = [];
let respond: () => Response;
const rejected = (status: number, error: Record<string, unknown>) => () => new Response(JSON.stringify({ error }), {
  status, headers: { 'Content-Type': 'application/json' },
});
const PARAM_ERROR = { message: "Unsupported value: 'temperature' does not support 1.7 with this model.", type: 'invalid_request_error', param: 'temperature', code: 'unsupported_value' };

function newStore(target: Provider = provider, targetModel: AIModel = model) {
  const conv = {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: target.id, providerKind: target.kind, modelID: targetModel.id, previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [provider, qwen], conversations: [conv as never] });
  mocks.store = store;
  return store;
}
const ctxOf = (store: ReturnType<typeof createAppStore>) => ({
  store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (key: string) => key,
});
const assistantOf = (store: ReturnType<typeof createAppStore>) =>
  store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;

async function send(target: Provider = provider, targetModel: AIModel = model) {
  const store = newStore(target, targetModel);
  const conv = store.getState().conversations[0];
  await sendMessage(ctxOf(store), {
    text: 'hello', prevMessages: [], conversation: conv, provider: target, model: targetModel, reasoningMode: 'automatic',
  }).done;
  return { store, failed: assistantOf(store) };
}

beforeEach(async () => {
  localStorage.clear();
  sentBodies.length = 0;
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE, timestamp: Date.now() } as never);
  await initMetadata();
  // A Relay's panel parameters are admitted by the "connection + endpoint" identity; in production it is established when the connection loads.
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  // Production Relay orchestration layer: it builds the real request body, and the upstream response comes from respond.
  mocks.sendStream.mockReset().mockImplementation((kind: Provider['kind'], apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) => kind !== 'relay'
    // An official connection goes through the production proxy client; the upstream error of /api/chat/stream comes from respond (the route passes the provider source through).
    ? sendStreamProxy(kind as never, apiKey, modelID, messages, baseURL, options)
    : sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
          return respond();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
  saveGenerationParameterOverrides(scope(), { temperature: valueOverride(1.7), max_output_tokens: valueOverride(256) });
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input.toString();
    if (!url.endsWith('/api/chat/stream')) throw new Error(`unexpected fetch: ${url}`);
    const response = respond();
    return new Response(response.body, {
      status: response.status, headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
    });
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('source of the parameter-rejection record', () => {
  it('WEB-REJECTION-RECOVERY-send_path_persists_signature_source', async () => {
    // Official connection signature hit: the failed message carries the signature source.
    respond = rejected(400, { code: 'invalid_parameter_error', message: 'This model does not support enable_search.' });
    const signed = (await send(qwen, qwenModel)).failed;
    expect(signed.state).toBe('failed');
    expect(signed.generationParameterRejection).toEqual({
      parameterId: 'enable_search', signatureId: 'dashscope.enable_search_not_supported',
    });

    // A relay only has the generic panel verdict: the record carries no signatureId.
    respond = rejected(400, PARAM_ERROR);
    const generic = (await send()).failed;
    expect(sentBodies).toHaveLength(1);
    expect(generic.state).toBe('failed');
    expect(generic.generationParameterRejection).toEqual({ parameterId: 'temperature' });
    expect(generic.generationParameterRejection).not.toHaveProperty('signatureId');
  });
});

describe('persisting a message with mixed currencies', () => {
  it('COST-CURRENCY-web_send_append_keeps_usd_and_non_usd_parts', async () => {
    // Official qwen connection: the catalog price is CNY (the model has no bundled price), so the generation cost can only go into nonUsdCost.
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({
      data: JSON.parse(JSON.stringify({
        ...METADATA_FIXTURE,
        providers: {
          qwen: {
            models: {
              'qwen-plus': {
                canonicalModelId: 'qwen-plus', capabilities: ['text'], pricingStatus: 'priced', currencyCode: 'CNY',
                pricingUnit: 'per_token', pricing: { promptPerMToken: 4, completionPerMToken: 16 },
              },
            },
          },
        },
      })),
      timestamp: Date.now(),
    } as never);
    await initMetadata();
    // The upstream goes through the production openai_chat_completions parser (usage -> breakdown), just not through the proxy route.
    respond = () => new Response([
      'data: {"id":"c1","choices":[{"index":0,"delta":{"content":"more"}}]}',
      'data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1000000,"completion_tokens":500000,"total_tokens":1500000}}',
      'data: [DONE]',
      '',
    ].join('\n\n'), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
    mocks.sendStream.mockImplementationOnce((_kind: Provider['kind'], apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
      sendRelayStream(apiKey, modelID, messages, baseURL || 'https://dashscope.example/v1', options, {
        transport: { fetch: async () => respond() },
        buildFetchArgs: (url, headers) => ({ url, headers }),
        getRelayRuntimeConfig: () => null,
      }));

    // An existing segment: USD 0.25 + CNY 1 (previous round's generation cost + retrieval cost).
    const user: ChatMessage = {
      id: 'u-1', role: 'user', text: 'hello', providerKind: 'qwen', providerName: 'Qwen', modelName: 'qwen-plus',
      estimatedCost: 0, state: 'delivered', createdAt: '2026-10-08T00:00:00.000Z',
    } as ChatMessage;
    const assistant: ChatMessage = {
      id: 'a-1', role: 'assistant', text: 'partial', providerKind: 'qwen', providerName: 'Qwen', modelName: 'qwen-plus',
      estimatedCost: 0.25, costSource: 'localEstimate', state: 'interrupted', createdAt: '2026-10-08T00:00:01.000Z',
      nonUsdCost: { currencyCode: 'CNY', amount: 1, costSource: 'localEstimate' },
    } as ChatMessage;
    const store = newStore(qwen, qwenModel);
    store.getState().updateConversation('conv-1', { messages: [user, assistant] });
    const conversation = store.getState().conversations[0];
    await sendMessage(ctxOf(store), {
      text: user.text, prevMessages: [user], conversation, provider: qwen, model: qwenModel, reasoningMode: 'automatic',
      userMessageOverride: user, assistantMessageOverride: { ...assistant, state: 'generating' }, persistUserMessage: false,
      userMessageAlreadyInHistory: true, appendToAssistant: true,
    }).done;

    const saved = store.getState().conversations[0];
    const delivered = saved.messages.find((m) => m.id === 'a-1')!;
    expect(delivered.state).toBe('delivered');
    // The USD part is kept as is (this round has no USD part); CNY adds within the same currency: 1 + (1M×4 + 0.5M×16)/1M = 13, with no conversion.
    expect(delivered.estimatedCost).toBeCloseTo(0.25, 10);
    expect(delivered.nonUsdCost?.currencyCode).toBe('CNY');
    expect(delivered.nonUsdCost?.costSource).toBe('localEstimate');
    expect(delivered.nonUsdCost?.amount).toBeCloseTo(13, 10);
    // Conversation totals: USD only accumulates estimatedCost, and CNY is totaled separately.
    expect(saved.estimatedCost).toBeCloseTo(0.25, 10);
    expect(Object.keys(saved.nonUsdCostTotals ?? {})).toEqual(['CNY']);
    expect(saved.nonUsdCostTotals?.CNY).toBeCloseTo(13, 10);
  });
});
