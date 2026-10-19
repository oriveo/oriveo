import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Main chat path max_tokens = plan.budget.oWire; when the Anthropic thinking budget >= oWire it is budget + 4096.
 * Assertions read the request body the production Relay orchestration layer actually sent through transport.fetch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  showToast: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../../../components/Toast', () => ({ showToast: (...args: unknown[]) => mocks.showToast(...args) }));
vi.mock('next/navigation', () => ({ useRouter: () => ({ replace: vi.fn() }) }));
vi.mock('next-intl', () => ({ useTranslations: () => (key: string) => key }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { act, renderHook } from '@testing-library/react';
import { SEND_BLOCKED, useStreamChat } from '../../../hooks/useStreamChat';
import { generationParameterProfileFingerprint, saveGenerationParameterOverrides, valueOverride } from '../generation-parameter-settings';
import { activeGenerationParameterIds } from '../generation-parameter-lifecycle';
import { chatUserMaxOutputFor } from './chat-context';

const provider = {
  id: 'relay-max', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'anthropic_messages', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'anthropic_messages', relayResolvedAuthMode: 'x_api_key',
} as unknown as Provider;

function modelWith(window: { contextLength: number; maxOutputTokens?: number }): AIModel {
  return {
    id: 'max-ctx-model', name: 'max-ctx-model', capabilities: ['text', 'reasoning'], reasoningModeAvailable: true,
    isAvailable: true, isDefault: true, priceTier: '', ...window,
  } as AIModel;
}

const GENERATION_METADATA = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-10-15T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: { max_output_tokens: { group: 'budget', valueSchema: 'integer', portability: 'portable' } },
      templates: {
        openai_chat_completions: { transport: 'openai_chat_completions', wire: { max_output_tokens: 'max_tokens' } },
      },
    },
  },
  providers: {},
  providerConfigs: [],
};

const sentBodies: Array<Record<string, unknown>> = [];
/**
 * The relay thinking tier has to pass the capability evidence gate; the thinking cases merge the tier at the service boundary into the options the production path produced,
 * and oWire is still written by the plan of sendMessage.
 */
let forcedReasoning: ReasoningMode | null = null;
const ok = () => new Response([
  'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
  'event: message_stop\ndata: {"type":"message_stop"}',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
const okOpenAIChat = () => new Response([
  'data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}',
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
  'data: [DONE]',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
let respond: () => Response = ok;

function newStore(model: AIModel, storeProvider: Provider = provider) {
  const conv = {
    id: 'conv-max', title: 'T', hasCustomTitle: false, providerID: storeProvider.id, modelID: model.id, providerKind: storeProvider.kind, previewText: '',
    estimatedCost: 0, isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [storeProvider], conversations: [conv as never] });
  mocks.store = store;
  return store;
}

async function sendAndCapture(model: AIModel, reasoningMode: ReasoningMode | null = null): Promise<Record<string, unknown>> {
  forcedReasoning = reasoningMode;
  const store = newStore(model);
  const conv = store.getState().conversations[0];
  await sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming('conv-max', chunk), te: (key: string) => key,
  }, { text: 'hello', prevMessages: conv.messages, conversation: conv, provider, model, reasoningMode: 'automatic' }).done;
  expect(sentBodies.length).toBeGreaterThan(0);
  return sentBodies[sentBodies.length - 1];
}

beforeEach(() => {
  localStorage.clear();
  sentBodies.length = 0;
  forcedReasoning = null;
  respond = ok;
  mocks.showToast.mockReset();
  __resetMetadataClientForTest();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string | null, options: StreamOptions) =>
    // The baseURL of an official connection is filled in by service according to the kind; here only the Relay orchestration layer is borrowed to get the outbound request body.
    sendRelayStream(apiKey, modelID, messages, baseURL ?? 'https://api.official.example/v1', forcedReasoning ? { ...options, reasoning: forcedReasoning } : options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
          return respond();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('context pipeline max_tokens', () => {
  it('max_tokens_equals_o_wire', async () => {
    // W=16000: R = min(max(8192, 1600), 8000) = 8000 -> oWire = min(8192, 8000) = 8000.
    const body = await sendAndCapture(modelWith({ contextLength: 16000, maxOutputTokens: 8192 }));
    expect(body.max_tokens).toBe(8000);
  });

  it('max_tokens_model_default_8192', async () => {
    // The model gives no maxOutputTokens: the O chain falls to 8192; with W=128000, R=12800 -> oWire = 8192.
    const body = await sendAndCapture(modelWith({ contextLength: 128000 }));
    expect(body.max_tokens).toBe(8192);
  });

  it('max_tokens_thinking_guard', async () => {
    const window = { contextLength: 16000, maxOutputTokens: 8192 };
    // deep budget 16384 >= oWire 8000 -> 16384 + 4096.
    const deep = await sendAndCapture(modelWith(window), 'deep');
    expect(deep.thinking).toEqual({ type: 'enabled', budget_tokens: 16384 });
    expect(deep.max_tokens).toBe(16384 + 4096);
    // fast budget 2048 < oWire 8000 -> still oWire, not raised to 8192.
    sentBodies.length = 0;
    const fast = await sendAndCapture(modelWith(window), 'fast');
    expect(fast.thinking).toEqual({ type: 'enabled', budget_tokens: 2048 });
    expect(fast.max_tokens).toBe(8000);
  });

  it('max_tokens_user_setting_budgeted', async () => {
    // Panel max output 4000 (user level of the O chain), model 8192, W=16000: R = min(max(4000, 1600), 8000) = 4000, U = 12000.
    // A message of about 9000 tokens would be rejected when computed with the model's 8192 (U = 8000); the rejection pre-check and assemble use the same O, so it is sent as usual.
    // The panel value has to pass the production evidence gate: use an official connection whose model carries a catalog generation profile (max_output_tokens supported),
    // and the metadata fixture gives the wire name of max_output_tokens for the openai_chat_completions template. Without evidence on a relay the panel value is not sent.
    await __seedMetadataCacheForTest({ data: GENERATION_METADATA, timestamp: Date.now() });
    await initMetadata();
    respond = okOpenAIChat;
    const model = {
      ...modelWith({ contextLength: 16000, maxOutputTokens: 8192 }),
      transport: 'openai_chat_completions',
      generationProfile: {
        template: 'openai_chat_completions',
        parameters: [{ id: 'max_output_tokens', group: 'budget', support: 'supported', source: 'authoritative_metadata' }],
      },
    } as unknown as AIModel;
    // The entry resolves this turn's model from the model list of the connection in the store: the connection has to carry this model.
    const hookProvider = {
      id: 'official-max', kind: 'openAI', status: { kind: 'connected' }, models: [model], catalogModels: [],
      apiKey: 'sk-official', apiKeyPreview: '••',
    } as unknown as Provider;
    saveGenerationParameterOverrides(
      { providerId: hookProvider.id, modelId: model.id, profileFingerprint: generationParameterProfileFingerprint(hookProvider, model) },
      { max_output_tokens: valueOverride(4000) },
    );
    const store = newStore(model, hookProvider);
    const conv = store.getState().conversations[0];
    const { result } = renderHook(() => useStreamChat({
      provider: hookProvider, currentModel: model, conversation: conv, messages: conv.messages, reasoningMode: 'automatic', onSendFailed: vi.fn(),
    }));
    let outcome: unknown;
    await act(async () => {
      outcome = await result.current.send('y'.repeat(18000), conv.messages, conv);
    });
    expect(outcome).not.toBe(SEND_BLOCKED);
    expect(mocks.showToast).not.toHaveBeenCalled();
    expect(sentBodies).toHaveLength(1);
    expect(sentBodies[0].max_tokens).toBe(4000);
  });

  it('dormant_max_output_not_in_window', async () => {
    // The relay has no generation evidence: the max output 2000 stored at conversation level is dormant, neither sent nor put into the window.
    const model = modelWith({ contextLength: 16000, maxOutputTokens: 8192 });
    const values = { max_output_tokens: valueOverride(2000) };
    saveGenerationParameterOverrides({
      providerId: provider.id, modelId: model.id, conversationId: 'conv-max',
      profileFingerprint: generationParameterProfileFingerprint(provider, model),
    }, values);
    expect(activeGenerationParameterIds(provider, model, values).has('max_output_tokens')).toBe(false);
    expect(chatUserMaxOutputFor({ provider, model, conversationId: 'conv-max', reasoningMode: 'automatic' })).toBeNull();
    const body = await sendAndCapture(model);
    // The window is computed with the model's 8192 (same as max_tokens_equals_o_wire): oWire = 8000, not 2000.
    expect(body.max_tokens).toBe(8000);
  });
});
