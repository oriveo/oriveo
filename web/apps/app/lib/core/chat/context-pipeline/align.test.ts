import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Cross-platform alignment: cases of the same name that Web was missing.
 * - retry_rejected_no_request: the retry entry goes through the same rejection pre-check; when blocked, no request is sent;
 * - manifest_written_on_user_cancel: a user cancel also writes a manifest (stopReason interrupted);
 * - overflow_no_checkpoint_no_retry: when the fallback produces no checkpoint -> no resend, context_window_exceeded is recorded;
 * - raw_body_not_in_telemetry_or_error_details: the raw error body stays out of telemetry / the failure card details / the saved messages.
 * Assertions read the request bodies the production Relay orchestration layer actually sent through transport.fetch and the Ledger the production code wrote.
 */
import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  showToast: vi.fn(),
  trackEvent: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../../../components/Toast', () => ({ showToast: (...args: unknown[]) => mocks.showToast(...args) }));
vi.mock('next/navigation', () => ({ useRouter: () => ({ replace: vi.fn() }) }));
vi.mock('next-intl', () => ({ useTranslations: () => (key: string) => key }));
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
}));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { stopStream } from '../stop-stream';
import { batchAppendStreaming } from '../stream-batcher';
import { useStreamChat } from '../../../hooks/useStreamChat';
import { getContextManifests } from '../../../infra/storage/context-ledger-store';

// W=20000, O=1000 -> R=2000, U=B=18000; the 0.90 line is 16200, the tail budget 4500.
const model = {
  id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  contextLength: 20000, maxOutputTokens: 1000,
} as AIModel;
const provider = {
  id: 'relay-align', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;

const OVERFLOW_BODY = JSON.stringify({
  error: {
    message: "This model's maximum context length is 20000 tokens. However, your messages resulted in 21000 tokens.",
    type: 'invalid_request_error',
    code: 'context_length_exceeded',
  },
});
const RAW_MARKER = 'raw-body-marker-Q7Z';

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
let responses: Array<(init: { signal?: AbortSignal }) => Response> = [];

const sse = (frames: string[]) => new Response(frames.map((f) => `data: ${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});
const ok = () => sse(['{"choices":[{"delta":{"content":"ok"}}]}', '[DONE]']);
const httpError = (status: number, body: string) => () => new Response(body, {
  status, headers: { 'Content-Type': 'application/json' },
});
/** Hangs after emitting some body text, until the request is cancelled. */
const hanging = (init: { signal?: AbortSignal }) => new Response(new ReadableStream<Uint8Array>({
  start(controller) {
    controller.enqueue(new TextEncoder().encode('data: {"choices":[{"delta":{"content":"partial"}}]}\n\n'));
    init.signal?.addEventListener('abort', () => controller.error(new DOMException('Aborted', 'AbortError')));
  },
}), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });

function history(count: number, chars: number): ChatMessage[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `m-${String(i).padStart(3, '0')}`,
    role: i % 2 === 0 ? 'user' : 'assistant',
    text: `${i % 2 === 0 ? 'question' : 'answer'} ${i} ${'x'.repeat(chars)}`,
    state: 'delivered',
    createdAt: new Date(Date.UTC(2026, 9, 15, 0, 0, i)).toISOString(),
  }) as ChatMessage);
}

let conversationId = 'conv-align-0';
const receivedChunks: string[] = [];
let conversationSeq = 0;

function newStore(messages: ChatMessage[]) {
  const conv = {
    id: conversationId, title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '', estimatedCost: 0,
    isDraft: false, messages, draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [provider], conversations: [conv as never] });
  mocks.store = store;
  return store;
}
const conversationOf = (store: ReturnType<typeof createAppStore>) => store.getState().conversations[0];

function startSend(store: ReturnType<typeof createAppStore>, text: string) {
  const conv = conversationOf(store);
  return sendMessage({
    store,
    appendChunk: (chunk: string) => {
      receivedChunks.push(chunk);
      batchAppendStreaming(conversationId, chunk);
    },
    te: (key: string) => key,
  }, {
    text, prevMessages: conv.messages, conversation: conv, provider, model, reasoningMode: 'automatic',
  });
}

function assistantOf(store: ReturnType<typeof createAppStore>) {
  const assistants = conversationOf(store).messages.filter((m) => m.role === 'assistant' && !m.id.startsWith('m-'));
  expect(assistants).toHaveLength(1);
  return assistants[0];
}

beforeEach(() => {
  conversationSeq += 1;
  conversationId = `conv-align-${conversationSeq}`;
  localStorage.clear();
  sentBodies.length = 0;
  receivedChunks.length = 0;
  responses = [];
  mocks.showToast.mockReset();
  mocks.trackEvent.mockReset();
  __resetMetadataClientForTest();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, relayDeps()));
});

function relayDeps() {
  return {
    transport: {
      fetch: async (_url: string, init: { body?: unknown; signal?: AbortSignal }) => {
        sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
        const next = responses.shift() ?? ok;
        return next(init);
      },
    },
    buildFetchArgs: (url: string, headers: Record<string, string>) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  } as never;
}

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('context pipeline three-platform alignment (contract item 8)', () => {
  it('retry_rejected_no_request', async () => {
    // The user message of the retried turn itself exceeds the window: the retry entry blocks it, sends no request and leaves the messages untouched.
    const failedAssistant = {
      id: 'a-failed', role: 'assistant', text: '', state: 'failed', createdAt: '2026-10-15T00:01:00.000Z',
    } as ChatMessage;
    const messages = [...history(2, 20), {
      id: 'u-long', role: 'user', text: 'y'.repeat(100_000), state: 'delivered', createdAt: '2026-10-15T00:00:59.000Z',
    } as ChatMessage, failedAssistant];
    const store = newStore(messages);
    const conv = conversationOf(store);
    const { result } = renderHook(() => useStreamChat({
      provider, currentModel: model, conversation: conv, messages: conv.messages, reasoningMode: 'automatic', onSendFailed: vi.fn(),
    }));
    await act(async () => {
      await result.current.retry('a-failed');
    });
    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(sentBodies).toHaveLength(0);
    expect(conversationOf(store).messages).toEqual(messages);
    expect(mocks.showToast).toHaveBeenCalledTimes(1);
    expect(mocks.showToast.mock.calls[0][0]).toBe('contextRejectMessageTooLong');
    expect(await getContextManifests(conversationId)).toHaveLength(0);
  });

  it('manifest_written_on_user_cancel', async () => {
    const store = newStore(history(4, 100));
    responses = [hanging];
    const handle = startSend(store, 'latest question');
    await vi.waitFor(() => expect(sentBodies).toHaveLength(1));
    await vi.waitFor(() => expect(receivedChunks.join('')).toContain('partial'));
    const conv = conversationOf(store);
    stopStream(store, conv, conv.messages, 'partial', handle.abort, { msgId: handle.msgId });
    await handle.done;

    expect(sentBodies).toHaveLength(1);
    expect(assistantOf(store).state).toBe('interrupted');
    const manifests = await getContextManifests(conversationId);
    expect(manifests).toHaveLength(1);
    expect(manifests[0].stopReason).toBe('interrupted');
    expect(manifests[0].transport).toBe('openai_chat');
    expect(manifests[0].model).toBe(model.id);
    expect(manifests[0].basis).toBe('estimated');
  });

  it('overflow_no_checkpoint_no_retry', async () => {
    // The history is already within the tail budget: the fallback produces no checkpoint, no resend.
    const store = newStore(history(4, 100));
    responses = [httpError(400, OVERFLOW_BODY), ok];
    await startSend(store, 'latest question').done;

    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('failed');
    expect(assistant.stopReason).toBe('context_window_exceeded');
    const manifests = await getContextManifests(conversationId);
    expect(manifests).toHaveLength(1);
    expect(manifests[0].stopReason).toBe('context_window_exceeded');
    expect(manifests[0].transport).toBe('openai_chat');
    expect(manifests[0].basis).toBe('estimated');
    expect(manifests[0].tailFrom).toBeUndefined();
  });

  it('raw_body_not_in_telemetry_or_error_details', async () => {
    const store = newStore(history(4, 100));
    const body = JSON.stringify({ error: { message: 'bad request', type: 'invalid_request_error' }, debug: RAW_MARKER });
    responses = [httpError(400, body)];
    await startSend(store, 'latest question').done;

    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('failed');
    expect(mocks.trackEvent).toHaveBeenCalled();
    expect(JSON.stringify(mocks.trackEvent.mock.calls)).not.toContain(RAW_MARKER);
    expect(JSON.stringify(conversationOf(store).messages)).not.toContain(RAW_MARKER);
    expect(JSON.stringify(await getContextManifests(conversationId))).not.toContain(RAW_MARKER);

    // Error event of the production stream: unfolding / serializing cannot carry the raw body away, and the overflow check can still read it by name.
    responses = [httpError(400, body)];
    const handle = sendRelayStream('sk-relay', model.id, [{ role: 'user', content: 'hi' }] as never, 'https://relay.example/v1', {
      relayTransport: 'openai_chat_completions',
    } as StreamOptions, relayDeps());
    const events: StreamEvent[] = [];
    const reader = handle.stream.getReader();
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      events.push(value);
    }
    const error = events.find((event): event is Extract<StreamEvent, { type: 'error' }> => event.type === 'error');
    expect(error?.httpStatus).toBe(400);
    expect(error?.rawBody).toBe(body);
    expect(JSON.stringify(events)).not.toContain(RAW_MARKER);
    expect(JSON.stringify({ ...error })).not.toContain(RAW_MARKER);
  });
});
