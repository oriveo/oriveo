// @vitest-environment jsdom
/**
 * Remaining coverage for "retry without the additional request body": Relay HTTP 400, in-stream error frames
 * that were not classified before any content arrived (official parser / Relay orchestrator), and how this
 * exit ranks against the web search / thinking exits. Runs through the production sendMessage chain with a
 * real readStream; the stream comes from the production Relay orchestrator or the production proxy parser.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamHandle, StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
}));

// The batch writer targets the global store; point it at this test's store.
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
vi.mock('../../metadata/metadata-client', async () => ({
  ...await vi.importActual<typeof import('../../metadata/metadata-client')>('../../metadata/metadata-client'),
  getMetadataRevision: () => undefined,
  getCapabilityRuntime: () => null,
  resolveGenerationProfileRef: vi.fn(() => undefined),
  resolveCatalogModel: vi.fn(),
  getDeclaredReasoningLevels: vi.fn(() => []),
  getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => null),
}));

import { createAppStore } from '../../store/app-store';
import { continueAnswering, retryMessage, sendMessage } from '../operations';
import { additionalBodyScope, loadAdditionalBody, saveAdditionalBody } from '../additional-body-settings';
import { batchAppendStreaming } from '../stream-batcher';
import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { adaptGeminiInteractionsResponse } from '@oriveo/core/providers/response-adapters/gemini-interactions';
import { RELAY_REDACTED_PLACEHOLDER } from '@oriveo/shared/relay/endpoint-policy';
import { sendStreamProxy } from '../../providers/proxy-client';

const provider = {
  id: 'p-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••test',
} as unknown as Provider;
const model = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: 'standard',
} as AIModel;

function conversation(): Conversation {
  return {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'gpt-4', previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
  } as Conversation;
}

function optionsOf(args: unknown[]): StreamOptions | undefined {
  return args.find((arg): arg is StreamOptions => Boolean(arg && typeof arg === 'object' && !Array.isArray(arg) && 'reasoningMode' in arg))
    ?? args.at(-1) as StreamOptions | undefined;
}

const sentBodies: Record<string, unknown>[] = [];

/** Production Relay orchestrator (Chat Completions, SSE); the upstream response comes from respond. */
function relayHandle(args: unknown[], respond: () => Response): StreamHandle {
  return sendRelayStream('relay-secret-key', 'model-a', [{ role: 'user', content: 'hi' }], 'https://relay.example', {
    ...optionsOf(args),
    relayTransport: 'openai_chat_completions', relayAuthMode: 'bearer', relayStream: true,
  }, {
    transport: {
      fetch: async (_url, init) => {
        sentBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
        return respond();
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  });
}

const sse = (...frames: string[]) => new Response(frames.map((frame) => `${frame}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

/** Event stream decoded by the production official proxy parser; the additional-body facts come from the handle. */
function officialHandle(frames: Array<[string | null, string]>, extra: Partial<StreamHandle> = {}): StreamHandle {
  const parser = createProxyChunkParser('openAI');
  const events: StreamEvent[] = frames.flatMap(([eventType, data]) => {
    const parsed = parser(eventType, data);
    return parsed == null ? [] : Array.isArray(parsed) ? parsed : [parsed];
  });
  return {
    stream: new ReadableStream<StreamEvent>({ start(ctrl) { events.forEach((event) => ctrl.enqueue(event)); ctrl.close(); } }),
    abort: vi.fn(),
    getAdditionalBodyApplied: () => true,
    ...extra,
  };
}

async function send(omitAdditionalBody = false): Promise<ChatMessage> {
  const conv = conversation();
  const store = createAppStore({ providers: [provider], conversations: [conv] });
  mocks.store = store;
  // Same body entry point as useStreamChat (batched rAF writes to the store).
  await sendMessage({ store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (key: string) => key }, {
    text: 'hello', prevMessages: [], conversation: conv, provider, model, reasoningMode: 'automatic', omitAdditionalBody,
  }).done;
  return store.getState().conversations[0].messages.find((m) => m.role === 'assistant') as ChatMessage;
}

beforeEach(() => {
  localStorage.clear();
  sentBodies.length = 0;
  mocks.sendStream.mockReset();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  saveAdditionalBody(additionalBodyScope(provider, model, 'conv-1'), { raw: '{"top_k":3}', enabled: true });
});

describe('Relay', () => {
  it('HTTP 400 offers an exit; the real request body of the retry omits the additional fields', async () => {
    mocks.sendStream.mockImplementation((...args: unknown[]) => relayHandle(args, () => new Response('{"error":{"message":"bad"}}', { status: 400 })));
    const failed = await send();
    expect(sentBodies[0]).toMatchObject({ top_k: 3 });
    expect(failed.state).toBe('failed');
    expect(failed.additionalBodyRetryEligible).toBe(true);
    expect(failed.errorTitle).toBe('additionalBodyRejected.upstreamTitle');

    await send(true);
    expect(sentBodies[1]).not.toHaveProperty('top_k');
  });

  it('an in-stream error frame before content offers an exit; an empty stream, one after content, and a classified one do not', async () => {
    const run = async (...frames: string[]) => {
      mocks.sendStream.mockImplementation((...args: unknown[]) => relayHandle(args, () => sse(...frames)));
      return send();
    };
    expect((await run('data: {"error":{"message":"unknown field top_k"}}')).additionalBodyRetryEligible).toBe(true);
    expect((await run('data: [DONE]')).additionalBodyRetryEligible).toBeUndefined();
    const afterContent = await run('data: {"choices":[{"delta":{"content":"Hel"}}]}', 'data: {"error":{"message":"boom"}}');
    expect(afterContent.additionalBodyRetryEligible).toBeUndefined();
    expect(afterContent.state).toBe('failed');
    expect(afterContent.text).toBe('Hel');
    expect((await run('data: {"error":{"message":"You exceeded your current quota","type":"insufficient_quota"}}')).additionalBodyRetryEligible).toBeUndefined();
  });
});

describe('official stream (proxy parser)', () => {
  it('OpenAI top-level error / Responses event:error offers an exit before content and not after', async () => {
    mocks.sendStream.mockReturnValue(officialHandle([[null, '{"error":{"message":"Unrecognized request argument: top_k"}}']]));
    expect((await send()).additionalBodyRetryEligible).toBe(true);
    mocks.sendStream.mockReturnValue(officialHandle([['error', '{"type":"error","code":"invalid_request","message":"bad top_k"}']]));
    expect((await send()).additionalBodyRetryEligible).toBe(true);
    mocks.sendStream.mockReturnValue(officialHandle([
      [null, '{"choices":[{"delta":{"content":"Hi"}}]}'],
      [null, '{"error":{"message":"boom"}}'],
    ]));
    const after = await send();
    expect(after.additionalBodyRetryEligible).toBeUndefined();
    expect(after.text).toBe('Hi');
  });

  it('an error after content keeps the thinking and body already received on the failed message', async () => {
    mocks.sendStream.mockReturnValue(officialHandle([
      [null, '{"choices":[{"delta":{"reasoning_content":"thinking part"}}]}'],
      [null, '{"choices":[{"delta":{"content":"Hi"}}]}'],
      [null, '{"error":{"message":"boom"}}'],
    ]));
    const failed = await send();
    expect(failed.state).toBe('failed');
    expect(failed.text).toBe('Hi');
    expect(failed.reasoningText).toBe('thinking part');
    expect(failed.additionalBodyRetryEligible).toBeUndefined();
  });

  it('Gemini Interactions: an error frame rewritten by the server adapter offers an exit before content, and the redacted original goes into the technical detail', async () => {
    const upstream = sse(`data: ${JSON.stringify({ event_type: 'error', error: { message: 'Invalid argument top_k for key AIza-gemini-secret', code: 'invalid_argument' } })}`);
    const adapted = adaptGeminiInteractionsResponse(upstream);
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(adapted);
    mocks.sendStream.mockImplementation(() => ({
      ...sendStreamProxy('gemini', 'AIza-gemini-secret', 'gemini-3-pro', [{ role: 'user', content: 'hello' }]),
      getAdditionalBodyApplied: () => true,
    }));
    const failed = await send();
    vi.restoreAllMocks();
    expect(failed.additionalBodyRetryEligible).toBe(true);
    expect(failed.errorTechnicalDetail).toBe(`Invalid argument top_k for key ${RELAY_REDACTED_PLACEHOLDER}`);
    expect(failed.errorDetail ?? '').not.toContain('AIza-gemini-secret');
  });

  it('when the same failure is already located to a web search / thinking setting, the title and button keep the existing exit', async () => {
    mocks.sendStream.mockReturnValue(officialHandle([[null, '{"error":{"message":"bad"}}']], {
      getCapabilityCustomRetryEligible: () => true,
    }));
    const failed = await send();
    expect(failed.additionalBodyRetryEligible).toBeUndefined();
    expect(failed.errorTitle).not.toBe('additionalBodyRejected.upstreamTitle');
  });
});

describe('raw in-stream error frame: redacted and truncated into the body and the technical detail', () => {
  it('Relay: credentials never appear, output is at most 2 KB, and classified errors still keep the technical detail', async () => {
    const long = `quota exceeded for key relay-secret-key ${'\u9519'.repeat(1500)}`;
    mocks.sendStream.mockImplementation((...args: unknown[]) => relayHandle(args, () => sse(
      `data: ${JSON.stringify({ error: { message: long, type: 'insufficient_quota' } })}`,
    )));
    const failed = await send();
    for (const text of [failed.errorDetail ?? '', failed.errorTechnicalDetail ?? '']) {
      expect(text).not.toContain('relay-secret-key');
      expect(text).not.toContain('\uFFFD');
      expect(new TextEncoder().encode(text).length).toBeLessThanOrEqual(2048);
    }
    expect(failed.errorTechnicalDetail).toContain('quota exceeded for key ');
    expect(failed.additionalBodyRetryEligible).toBeUndefined();
  });
});


describe('continue answering', () => {
  it('an upstream rejection while continuing offers an exit and the raw frame; retrying with the omit flag sends no additional body while the stored one stays', async () => {
    const user = { id: 'u-1', role: 'user', text: 'hello', createdAt: '2026-10-08T00:00:00.000Z', state: 'delivered' } as ChatMessage;
    const partial = {
      id: 'a-1', role: 'assistant', text: 'Hel', createdAt: '2026-10-08T00:00:01.000Z', state: 'interrupted',
      providerID: 'p-1', providerKind: 'openAI', modelID: 'gpt-4', estimatedCost: 0,
    } as unknown as ChatMessage;
    const conv = { ...conversation(), messages: [user, partial] };
    const store = createAppStore({ providers: [provider], conversations: [conv] });
    mocks.store = store;
    const ctx = { store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (key: string) => key };
    mocks.sendStream.mockReturnValue(officialHandle([[null, '{"error":{"message":"Unrecognized request argument: top_k"}}']]));
    await continueAnswering(ctx, { messageId: 'a-1', conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic' })?.done;
    expect(optionsOf(mocks.sendStream.mock.calls[0])?.additionalBody?.raw).toBe('{"top_k":3}');
    const failed = store.getState().conversations[0].messages.find((m) => m.id === 'a-1')!;
    expect(failed.state).toBe('failed');
    expect(failed.additionalBodyRetryEligible).toBe(true);
    expect(failed.errorTitle).toBe('additionalBodyRejected.upstreamTitle');
    expect(failed.errorTechnicalDetail).toBe('Unrecognized request argument: top_k');

    mocks.sendStream.mockReturnValue(officialHandle([[null, '{"choices":[{"delta":{"content":"lo"}}]}']]));
    const state = store.getState().conversations[0];
    await retryMessage(ctx, {
      messageId: 'a-1', conversation: state, messages: state.messages, provider, model, reasoningMode: 'automatic', omitAdditionalBody: true,
    })?.done;
    expect(optionsOf(mocks.sendStream.mock.calls[1])?.additionalBody).toBeUndefined();
    expect(loadAdditionalBody(additionalBodyScope(provider, model, 'conv-1'))).toMatchObject({ raw: '{"top_k":3}', enabled: true });
  });
});
