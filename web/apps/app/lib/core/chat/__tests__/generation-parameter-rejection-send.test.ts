import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * A panel generation parameter rejected upstream (HTTP 400 before the stream starts, error body names exactly one item), through the production send chain:
 * sendMessage -> production Relay orchestration builds the real request body -> simulated upstream 400 -> no automatic retry, the failure message carries the located item;
 * after the user taps "Resend without this setting" the second request body lacks that field and the saved setting is unchanged.
 * The profile comes from production parsing (metadata fixture); no hand-written profile / StreamOptions.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { retryMessage, sendMessage } from '../operations';
import { beginCapabilityEvidenceIdentityIfAbsent } from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { batchAppendStreaming } from '../stream-batcher';
import { sendStreamProxy } from '../../providers/proxy-client';
import { relayGenerationProfile } from '../stream-options';
import { decideGenerationParameterRejection } from '../generation-parameter-rejection';
import {
  generationParameterProfileFingerprint,
  loadGenerationParameterOverrides,
  saveGenerationParameterOverrides,
  valueOverride,
} from '../generation-parameter-settings';

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
const scope = () => ({
  providerId: provider.id, modelId: model.id, conversationId: 'conv-1',
  profileFingerprint: generationParameterProfileFingerprint(provider, model),
});

const sentBodies: Record<string, unknown>[] = [];
let respond: () => Response;
const sse = (...frames: string[]) => new Response(frames.map((frame) => `${frame}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});
const rejected = (status: number, error: Record<string, unknown>) => () => new Response(JSON.stringify({ error }), {
  status, headers: { 'Content-Type': 'application/json' },
});
const PARAM_ERROR = { message: "Unsupported value: 'temperature' does not support 1.7 with this model.", type: 'invalid_request_error', param: 'temperature', code: 'unsupported_value' };

function newStore() {
  const conv = {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [provider], conversations: [conv as never] });
  mocks.store = store;
  return store;
}
const ctxOf = (store: ReturnType<typeof createAppStore>) => ({
  store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (key: string) => key,
});
const assistantOf = (store: ReturnType<typeof createAppStore>) =>
  store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;

async function send(store = newStore()) {
  const conv = store.getState().conversations[0];
  await sendMessage(ctxOf(store), { text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic' }).done;
  return { store, failed: assistantOf(store) };
}

beforeEach(async () => {
  localStorage.clear();
  sentBodies.length = 0;
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE, timestamp: Date.now() } as never);
  await initMetadata();
  // Relay panel parameters are admitted by the "connection + endpoint" identity, which production establishes when the connection loads.
  beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  // Production Relay orchestration builds the real request body; the upstream response comes from respond.
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
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
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('a 400 before the stream starts names exactly one panel parameter', () => {
  it('no automatic retry; the failure message carries the located item; "Resend without this setting" omits it for that one request only and storage is unchanged', async () => {
    respond = rejected(400, PARAM_ERROR);
    const { store, failed } = await send();
    expect(sentBodies).toHaveLength(1);
    expect(sentBodies[0]).toMatchObject({ temperature: 1.7, max_tokens: 256 });
    expect(failed.state).toBe('failed');
    expect(failed.generationParameterRejection).toEqual({ parameterId: 'temperature' });
    expect(failed.errorTechnicalDetail).toContain('temperature');
    expect(failed.additionalBodyRetryEligible).toBeUndefined();

    respond = () => sse('data: {"choices":[{"delta":{"content":"ok"}}]}', 'data: [DONE]');
    const conv = store.getState().conversations[0];
    await retryMessage(ctxOf(store), {
      messageId: failed.id, conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
      omitGenerationParameters: ['temperature'],
    })!.done;
    expect(sentBodies).toHaveLength(2);
    expect(sentBodies[1]).not.toHaveProperty('temperature');
    expect(sentBodies[1]).toMatchObject({ max_tokens: 256 });
    const resent = assistantOf(store);
    expect(resent.state).toBe('delivered');
    expect(resent.generationParameterRejection).toBeUndefined();
    expect(loadGenerationParameterOverrides(scope())).toEqual({ temperature: valueOverride(1.7), max_output_tokens: valueOverride(256) });

    // The next ordinary send carries the saved value as usual.
    await send(store);
    expect(sentBodies[2]).toMatchObject({ temperature: 1.7 });
  });

  it('the named item is the wire field name: max_tokens -> located to max_output_tokens', async () => {
    respond = rejected(400, { message: 'max_tokens is too large', param: 'max_tokens' });
    expect((await send()).failed.generationParameterRejection).toEqual({ parameterId: 'max_output_tokens' });
  });
});

describe('cases with no way out (none retry)', () => {
  it('a 400 that cannot be located / names something other than a panel parameter written this time', async () => {
    respond = rejected(400, { message: 'temperature looks wrong' });
    expect((await send()).failed.generationParameterRejection).toBeUndefined();
    respond = rejected(400, { message: 'bad', param: 'messages' });
    expect((await send()).failed.generationParameterRejection).toBeUndefined();
    respond = rejected(400, { message: 'bad', param: 'top_p' });
    expect((await send()).failed.generationParameterRejection).toBeUndefined();
    expect(sentBodies).toHaveLength(3);
  });

  it('a 422 offers nothing even when it names an item', async () => {
    respond = rejected(422, PARAM_ERROR);
    const { failed } = await send();
    expect(failed.state).toBe('failed');
    expect(failed.generationParameterRejection).toBeUndefined();
    expect(sentBodies).toHaveLength(1);
  });

  it('an error after body text has arrived offers nothing and the text is kept', async () => {
    respond = () => sse('data: {"choices":[{"delta":{"content":"Hel"}}]}', `data: ${JSON.stringify({ error: PARAM_ERROR })}`);
    const { failed } = await send();
    expect(failed.state).toBe('failed');
    expect(failed.text).toBe('Hel');
    expect(failed.generationParameterRejection).toBeUndefined();
    expect(sentBodies).toHaveLength(1);
  });

  it('the additional body wrote a same-named field: that wire value is not the panel\'s, so it is not located to a panel parameter', async () => {
    const { additionalBodyScope, saveAdditionalBody } = await import('../additional-body-settings');
    saveAdditionalBody(additionalBodyScope(provider, model, 'conv-1'), { raw: '{"temperature":5}', enabled: true });
    respond = rejected(400, PARAM_ERROR);
    const { failed } = await send();
    expect(sentBodies[0]).toMatchObject({ temperature: 5 });
    expect(failed.generationParameterRejection).toBeUndefined();
    expect(failed.additionalBodyRetryEligible).toBe(true);
  });
});

describe('official proxy path (proxy-client)', () => {
  it('upstream 400 passed through by the route: the error event carries structured fields, the handle reports what was written this time, and the decision locates the same item', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({ error: PARAM_ERROR }), {
      status: 400, headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
    }));
    try {
      const handle = sendStreamProxy('openAI', 'sk-test', 'gpt-4', [{ role: 'user', content: 'hi' }], undefined, {
        generationParameters: { temperature: valueOverride(1.7) },
        generationProfile: relayGenerationProfile(provider),
      } as StreamOptions);
      const reader = handle.stream.getReader();
      const events = [];
      for (let next = await reader.read(); !next.done; next = await reader.read()) events.push(next.value);
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const error = events.find((event) => event.type === 'error') as { status?: number; errorFields?: Record<string, string> };
      expect(error.errorFields).toEqual({ '/error/param': 'temperature' });
      const write = handle.getGenerationWrite!();
      expect(write.written).toEqual(['temperature']);
      expect(decideGenerationParameterRejection({
        status: error.status, streamStarted: false, sideEffects: false, errorFields: error.errorFields, ...write,
      })).toMatchObject({ action: 'user_confirmed_resend_without_located_setting', parameterId: 'temperature', retry: false });
    } finally {
      fetchSpy.mockRestore();
    }
  });
});
