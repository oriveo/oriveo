import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Review blockers:
 * - when an image is generated on the chat path through a relay, the image prompt uses the user's original text without [D] / the checkpoint;
 * - rho samples and overflow misses are recorded only on single-leg chat requests: library retrieval legs / direct body text are skipped, and a context_window_exceeded finish records no sample;
 * - a user cancel that ends by throwing: the manifest records interrupted.
 * Assertions read the request bodies the production send path actually sent, the Ledger and the saved messages.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  runLibraryServerResearch: vi.fn(),
  readLibraryDirectContext: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../library-server-research', () => ({
  runLibraryServerResearch: (...args: unknown[]) => mocks.runLibraryServerResearch(...args),
}));
vi.mock('../library-direct-context', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../library-direct-context')>()),
  readLibraryDirectContext: (...args: unknown[]) => mocks.readLibraryDirectContext(...args),
}));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { sendStreamProxy } from '../../providers/proxy-client';
import { getContextManifests, getRhoCalibration, putRhoCalibration } from '../../../infra/storage/context-ledger-store';
import { RhoCalibration } from '@oriveo/core/context/calibration';

// W=20000, O=1000 -> U=B=18000; the 0.90 line is 16200.
const model = {
  id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  contextLength: 20000, maxOutputTokens: 1000,
} as AIModel;
const provider = {
  id: 'relay-review', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const anthropicProvider = {
  ...provider,
  relayRequested: { transport: 'anthropic_messages', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'anthropic_messages', relayResolvedAuthMode: 'x_api_key',
} as unknown as Provider;
const imageModel = {
  ...model, id: 'img-model', name: 'img-model', capabilities: ['text', 'imageGeneration'],
  relayCapabilityOverrides: { imageGeneration: { value: true } },
} as unknown as AIModel;

const OVERFLOW_BODY = JSON.stringify({
  error: {
    message: "This model's maximum context length is 20000 tokens. However, your messages resulted in 21000 tokens.",
    type: 'invalid_request_error',
    code: 'context_length_exceeded',
  },
});
interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
interface WireBody { messages?: WireMessage[]; prompt?: string }
const sentBodies: WireBody[] = [];
let responses: Array<() => Response> = [];

const sse = (frames: string[]) => new Response(frames.map((f) => `data: ${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});
const ok = () => sse(['{"choices":[{"delta":{"content":"ok"}}]}', '[DONE]']);
const okWithUsage = (promptTokens: number) => () => sse([
  '{"choices":[{"delta":{"content":"ok"}}]}',
  '{"choices":[{"delta":{},"finish_reason":"stop"}]}',
  `{"choices":[],"usage":{"prompt_tokens":${promptTokens},"completion_tokens":1,"total_tokens":${promptTokens + 1}}}`,
  '[DONE]',
]);
const httpError = (status: number, body: string) => () => new Response(body, {
  status, headers: { 'Content-Type': 'application/json' },
});
const anthropicWithUsage = (stopReason: string, inputTokens: number) => () => new Response([
  `event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"usage":{"input_tokens":${inputTokens},"output_tokens":1}}}`,
  'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
  `event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"${stopReason}"},"usage":{"output_tokens":1}}`,
  'event: message_stop\ndata: {"type":"message_stop"}',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
const imageOk = () => new Response(JSON.stringify({ data: [{ b64_json: 'iVBORw0KGgo=' }] }), {
  status: 200, headers: { 'Content-Type': 'application/json' },
});

function history(count: number, chars: number): ChatMessage[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `m-${String(i).padStart(3, '0')}`,
    role: i % 2 === 0 ? 'user' : 'assistant',
    text: `${i % 2 === 0 ? 'question' : 'answer'} ${i} ${'x'.repeat(chars)}`,
    state: 'delivered',
    createdAt: new Date(Date.UTC(2026, 9, 15, 0, 0, i)).toISOString(),
  }) as ChatMessage);
}

let conversationId = 'conv-review-0';
let conversationSeq = 0;

function newStore(messages: ChatMessage[], storeProvider: Provider = provider) {
  const conv = {
    id: conversationId, title: 'T', hasCustomTitle: false, providerID: storeProvider.id, modelID: model.id, providerKind: storeProvider.kind,
    previewText: '', estimatedCost: 0, isDraft: false, messages, draftText: '',
    updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [storeProvider], conversations: [conv as never] });
  mocks.store = store;
  return store;
}
const conversationOf = (store: ReturnType<typeof createAppStore>) => store.getState().conversations[0];

function textOf(message: WireMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}
const chatMessagesOf = (body: WireBody) => (body.messages ?? []).filter((m) => m.role !== 'system');

function startSend(
  store: ReturnType<typeof createAppStore>,
  text: string,
  sendProvider: Provider = provider,
  extra: Record<string, unknown> = {},
  sendModel: AIModel = model,
) {
  const conv = conversationOf(store);
  return sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
  }, {
    text, prevMessages: conv.messages, conversation: conv, provider: sendProvider, model: sendModel, reasoningMode: 'automatic',
    ...extra,
  } as never);
}
const send = async (...args: Parameters<typeof startSend>) => { await startSend(...args).done; };

function relayDeps() {
  return {
    transport: {
      fetch: async (_url: string, init: { body?: unknown }) => {
        sentBodies.push(JSON.parse(String(init.body)) as WireBody);
        const next = responses.shift() ?? ok;
        return next();
      },
    },
    buildFetchArgs: (url: string, headers: Record<string, string>) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

function assistantOf(store: ReturnType<typeof createAppStore>) {
  const assistants = conversationOf(store).messages.filter((m) => m.role === 'assistant' && !m.id.startsWith('m-'));
  expect(assistants).toHaveLength(1);
  return assistants[0];
}

beforeEach(async () => {
  conversationSeq += 1;
  conversationId = `conv-review-${conversationSeq}`;
  await putRhoCalibration(provider.id, model.id, RhoCalibration.initial());
  localStorage.clear();
  sentBodies.length = 0;
  responses = [];
  __resetMetadataClientForTest();
  mocks.runLibraryServerResearch.mockReset().mockResolvedValue({
    systemInstruction: 'Answer from the library evidence.', userContext: '<library-evidence>doc body</library-evidence>',
    citations: [], steps: [], warnings: [], documentCount: 1,
  });
  mocks.readLibraryDirectContext.mockReset().mockResolvedValue({
    systemInstruction: 'Answer from the named documents.', userContext: '<library-document>doc body</library-document>', citations: [],
  });
  mocks.sendStream.mockReset().mockImplementation((kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    kind === 'relay'
      ? sendRelayStream(apiKey, modelID, messages, baseURL, options, relayDeps() as never)
      : sendStreamProxy(kind as never, apiKey, modelID, messages, baseURL, options));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
  vi.restoreAllMocks();
});

describe('context pipeline review blockers', () => {
  it('relay_image_prompt_has_no_dynamic_block', async () => {
    const imageProvider = { ...provider, models: [imageModel] } as unknown as Provider;
    const store = newStore([], imageProvider);
    responses = [imageOk];
    await send(store, 'draw a red cat', imageProvider, { libraryServerResearch: { query: 'cats' } }, imageModel);

    const imageBodies = sentBodies.filter((body) => typeof body.prompt === 'string');
    expect(imageBodies).toHaveLength(1);
    expect(imageBodies[0].prompt).toBe('draw a red cat');
  });

  it('relay_image_prompt_has_no_checkpoint', async () => {
    const imageProvider = { ...provider, models: [imageModel] } as unknown as Provider;
    const store = newStore(history(4, 8200), imageProvider);
    responses = [imageOk];
    await send(store, 'draw a red cat', imageProvider, {}, imageModel);

    // Image generation goes through purpose imageGeneration: the history is not sent, so even a long history does not trigger the checkpoint fallback.
    const manifests = await getContextManifests(conversationId);
    expect(manifests.at(-1)?.purpose).toBe('imageGeneration');
    expect(manifests.at(-1)?.tailFrom).toBeUndefined();
    const imageBodies = sentBodies.filter((body) => typeof body.prompt === 'string');
    expect(imageBodies).toHaveLength(1);
    expect(imageBodies[0].prompt).toBe('draw a red cat');
  });

  it('rho_skipped_for_tool_or_library_legs', async () => {
    // Server-side retrieval leg: a successful finish with usage still writes no sample.
    let store = newStore(history(4, 100));
    responses = [okWithUsage(300)];
    await send(store, 'latest question', provider, { libraryServerResearch: { query: 'latest question' } });
    expect(assistantOf(store).state).toBe('delivered');
    expect((await getRhoCalibration(provider.id, model.id)).n).toBe(0);

    // Library direct body text: likewise not written.
    conversationId = `${conversationId}-direct`;
    store = newStore(history(4, 100));
    responses = [okWithUsage(300)];
    await send(store, 'latest question', provider, {
      libraryContextDocuments: [{ docId: 'doc-1', source: 'notion', title: 'Doc 1' }],
    });
    expect(assistantOf(store).state).toBe('delivered');
    expect((await getRhoCalibration(provider.id, model.id)).n).toBe(0);

    // A retrieval leg predicted no overflow but overflowed: rho is not raised.
    conversationId = `${conversationId}-overflow`;
    store = newStore(history(16, 1600));
    responses = [httpError(400, OVERFLOW_BODY), ok];
    await send(store, 'latest question', provider, { libraryServerResearch: { query: 'latest question' } });
    expect((await getRhoCalibration(provider.id, model.id)).rho).toBe(CONTEXT_BUDGET_CONSTANTS.rho0);

    // Control: the same connection's single-leg chat writes a sample as usual.
    conversationId = `${conversationId}-plain`;
    store = newStore(history(4, 100));
    responses = [okWithUsage(300)];
    await send(store, 'latest question');
    expect((await getRhoCalibration(provider.id, model.id)).n).toBe(1);
  });

  it('rho_skipped_on_context_window_exceeded', async () => {
    let store = newStore(history(4, 100), anthropicProvider);
    responses = [anthropicWithUsage('model_context_window_exceeded', 300)];
    await send(store, 'latest question', anthropicProvider);
    expect(assistantOf(store).stopReason).toBe('context_window_exceeded');
    expect((await getRhoCalibration(provider.id, model.id)).n).toBe(0);

    // Control: the same usage on a normal finish writes a sample.
    conversationId = `${conversationId}-clean`;
    store = newStore(history(4, 100), anthropicProvider);
    responses = [anthropicWithUsage('end_turn', 300)];
    await send(store, 'latest question', anthropicProvider);
    expect((await getRhoCalibration(provider.id, model.id)).n).toBe(1);
  });

  it('user_cancel_throw_records_interrupted', async () => {
    // Official connection: after the user stops, the underlying stream throws a network error (a cancel is often wrapped as a network error).
    const officialProvider = {
      ...provider, kind: 'anthropic', baseURLText: '', relayRequested: undefined, relayResolvedTransport: undefined, relayResolvedAuthMode: undefined,
    } as unknown as Provider;
    let started!: () => void;
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    mocks.sendStream.mockReset().mockImplementation(() => {
      let fail: (() => void) | null = null;
      const stream = new ReadableStream({
        start(controller) {
          fail = () => controller.error(new TypeError('Failed to fetch'));
          started();
        },
      });
      return { stream, abort: () => fail?.() };
    });
    const store = newStore(history(4, 100), officialProvider);
    const handle = startSend(store, 'latest question', officialProvider);
    await startedPromise;
    handle.abort();
    await handle.done;

    const manifests = await getContextManifests(conversationId);
    expect(manifests).toHaveLength(1);
    expect(manifests[0].stopReason).toBe('interrupted');
  });

  // The two ways the underlying stream ends after the user stops: throw / silent close; the assistant message and the manifest both record interrupted.
  async function sendThenUserAbort(onAbort: 'throw' | 'close') {
    const officialProvider = {
      ...provider, kind: 'anthropic', baseURLText: '', relayRequested: undefined, relayResolvedTransport: undefined, relayResolvedAuthMode: undefined,
    } as unknown as Provider;
    let started!: () => void;
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    mocks.sendStream.mockReset().mockImplementation(() => {
      let end: (() => void) | null = null;
      const stream = new ReadableStream({
        start(controller) {
          controller.enqueue({ type: 'delta', content: 'partial answer' });
          end = onAbort === 'throw'
            ? () => controller.error(new TypeError('Failed to fetch'))
            : () => controller.close();
          started();
        },
      });
      return { stream, abort: () => end?.() };
    });
    const store = newStore(history(4, 100), officialProvider);
    const handle = startSend(store, 'latest question', officialProvider);
    await startedPromise;
    handle.abort();
    await handle.done;
    return store;
  }

  it('user_abort_throw_message_interrupted', async () => {
    const store = await sendThenUserAbort('throw');
    expect(assistantOf(store).stopReason).toBe('interrupted');
    const manifests = await getContextManifests(conversationId);
    expect(manifests).toHaveLength(1);
    expect(manifests[0].stopReason).toBe('interrupted');
  });

  it('user_abort_silent_close_records_interrupted', async () => {
    const store = await sendThenUserAbort('close');
    expect(assistantOf(store).stopReason).toBe('interrupted');
    const manifests = await getContextManifests(conversationId);
    expect(manifests).toHaveLength(1);
    expect(manifests[0].stopReason).toBe('interrupted');
  });
});
