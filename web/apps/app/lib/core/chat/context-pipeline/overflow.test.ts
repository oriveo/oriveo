import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Overflow recovery, rho write-back, manifest.
 * - overflow with no body text yet -> after the fallback (checkpoint) the same assistant message is automatically resent once; still overflowing / body text already emitted -> context_window_exceeded;
 * - 401 / 429 / 5xx do not recover;
 * - a successful text-only request with usage writes a rho sample; a predicted P̂ < U that still overflows writes back an overflow miss;
 * - one manifest per chat request.
 * Assertions read the request body the production Relay orchestration layer actually sent through transport.fetch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '@oriveo/core/providers/types';
import { toProviderError } from '@oriveo/core/providers/errors';
import { CONTEXT_BUDGET_CONSTANTS } from '@oriveo/core/context/budget';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { getContextManifests, getRhoCalibration, putRhoCalibration } from '../../../infra/storage/context-ledger-store';
import { RhoCalibration } from '@oriveo/core/context/calibration';
import { listContextCheckpoints, putContextCheckpoint } from '../../../infra/storage/context-checkpoint-store';
import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';

// W=20000, O=1000 -> R=2000, U=B=18000; the 0.90 line is 16200, the tail budget 4500.
const model = {
  id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  contextLength: 20000, maxOutputTokens: 1000,
} as AIModel;
const provider = {
  id: 'relay-ctx', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;

const CHECKPOINT_OPEN = '<oriveo-context-checkpoint v="1"';
const OVERFLOW_BODY = JSON.stringify({
  error: {
    message: "This model's maximum context length is 20000 tokens. However, your messages resulted in 21000 tokens.",
    type: 'invalid_request_error',
    code: 'context_length_exceeded',
  },
});

const ANTHROPIC_OVERFLOW_BODY = JSON.stringify({
  type: 'error',
  error: { type: 'invalid_request_error', message: 'input length and `max_tokens` exceed context limit: 19500 + 1000 > 20000' },
});
const anthropicOk = () => new Response([
  'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}',
  'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}',
  'event: message_stop\ndata: {"type":"message_stop"}',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });

/** An Anthropic stream ends normally (HTTP 200) with stop_reason=model_context_window_exceeded; if text is given, some body text is emitted first. */
const anthropicInStreamOverflow = (text?: string) => () => new Response([
  ...(text
    ? [`event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"${text}"}}`]
    : []),
  'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"}}',
  'event: message_stop\ndata: {"type":"message_stop"}',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
const relayAnthropicProvider = {
  ...provider,
  relayRequested: { transport: 'anthropic_messages', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'anthropic_messages', relayResolvedAuthMode: 'x_api_key',
} as unknown as Provider;

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
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
const VALID_SUMMARY = ['## Goal', 'g', '## Key Facts & Decisions', 'k', '## Work Produced', 'w', '## Open Threads', 'o',
  '## Style & Language', 's'].join('\n');
const textReply = (text: string) => () => sse([JSON.stringify({ choices: [{ delta: { content: text } }] }), '[DONE]']);
const contentThenOverflowFrame = () => sse([
  '{"choices":[{"delta":{"content":"partial answer"}}]}',
  OVERFLOW_BODY,
]);

function history(count: number, chars: number): ChatMessage[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `m-${String(i).padStart(3, '0')}`,
    role: i % 2 === 0 ? 'user' : 'assistant',
    text: `${i % 2 === 0 ? 'question' : 'answer'} ${i} ${'x'.repeat(chars)}`,
    state: 'delivered',
    createdAt: new Date(Date.UTC(2026, 9, 15, 0, 0, i)).toISOString(),
  }) as ChatMessage);
}

// The Ledger persists across cases in fake-indexeddb: each case uses its own conversation id, and rho is reset in beforeEach.
let conversationId = 'conv-ovf-0';
let conversationSeq = 0;

function newStore(messages: ChatMessage[], storeProvider: Provider = provider) {
  const conv = {
    id: conversationId, title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '', estimatedCost: 0,
    isDraft: false, messages, draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
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
const chatMessagesOf = (body: { messages: WireMessage[] }) => body.messages.filter((m) => m.role !== 'system');

async function send(store: ReturnType<typeof createAppStore>, text: string, sendProvider: Provider = provider) {
  const conv = conversationOf(store);
  await sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
  }, {
    text, prevMessages: conv.messages, conversation: conv, provider: sendProvider, model, reasoningMode: 'automatic',
  }).done;
}

function relayDeps() {
  return {
    transport: {
      fetch: async (_url: string, init: { body?: unknown }) => {
        sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
        const next = responses.shift() ?? ok;
        return next();
      },
    },
    buildFetchArgs: (url: string, headers: Record<string, string>) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

const GEMINI_OVERFLOW_BODY = JSON.stringify({
  error: { code: 400, message: 'The input token count (21000) exceeds the maximum number of tokens allowed (20000).', status: 'INVALID_ARGUMENT' },
});
let officialResponses: Array<'ok' | { status: number; body: string } | { events: StreamEvent[] }> = [];

/** Official connection (no relay outbound protocol): sendStream records the messages the production send path handed it and fails or emits ok according to the script. */
function officialProvider(kind: 'anthropic' | 'gemini'): Provider {
  return {
    ...provider, kind, baseURLText: '', relayRequested: undefined, relayResolvedTransport: undefined, relayResolvedAuthMode: undefined,
  } as unknown as Provider;
}
function officialStream(messages: WireMessage[]): { stream: ReadableStream<StreamEvent>; abort: () => void } {
  sentBodies.push({ messages });
  const next = officialResponses.shift() ?? 'ok';
  const stream = new ReadableStream<StreamEvent>({
    start(controller) {
      if (next !== 'ok' && 'events' in next) {
        for (const event of next.events) controller.enqueue(event);
        controller.close();
        return;
      }
      if (next !== 'ok') {
        controller.error(toProviderError(next.status, next.body));
        return;
      }
      controller.enqueue({ type: 'delta', content: 'ok' });
      controller.enqueue({ type: 'done' });
      controller.close();
    },
  });
  return { stream, abort: () => undefined };
}

function assistantOf(store: ReturnType<typeof createAppStore>) {
  const assistants = conversationOf(store).messages.filter((m) => m.role === 'assistant' && !m.id.startsWith('m-'));
  expect(assistants).toHaveLength(1);
  return assistants[0];
}

beforeEach(async () => {
  conversationSeq += 1;
  conversationId = `conv-ovf-${conversationSeq}`;
  await putRhoCalibration(provider.id, model.id, RhoCalibration.initial());
  localStorage.clear();
  sentBodies.length = 0;
  responses = [];
  __resetMetadataClientForTest();
  officialResponses = [];
  mocks.sendStream.mockReset().mockImplementation((kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    kind === 'relay'
      ? sendRelayStream(apiKey, modelID, messages, baseURL, options, relayDeps() as never)
      : officialStream(messages));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('context pipeline overflow recovery, rho write-back and manifest', () => {
  it('overflow_recovers_once_with_checkpoint', async () => {
    // About 13k tokens (the last message is an assistant reply): below the 0.90 line (no fallback on the first send), above the tail budget (after an overflow the fallback can produce a checkpoint).
    const earlier = history(16, 1600);
    const store = newStore(earlier);
    responses = [httpError(400, OVERFLOW_BODY), ok];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(2);
    const first = chatMessagesOf(sentBodies[0]);
    expect(first.some((m) => textOf(m).includes(CHECKPOINT_OPEN))).toBe(false);
    const second = chatMessagesOf(sentBodies[1]);
    expect(second.length).toBeLessThan(first.length);
    expect(second[0].role).toBe('user');
    expect(textOf(second[0]).startsWith(`${CHECKPOINT_OPEN} covers="m-000..`)).toBe(true);
    expect(textOf(second[second.length - 1])).toBe('latest question');

    // The same assistant message ends; this turn's user message is saved only once.
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.text).toBe('ok');
    expect(assistant.stopReason).not.toBe('context_window_exceeded');
    const stored = conversationOf(store).messages;
    expect(stored.filter((m) => m.role === 'user' && m.text === 'latest question')).toHaveLength(1);
    expect(stored.some((m) => (m.text ?? '').includes(CHECKPOINT_OPEN))).toBe(false);
    // The default mode runs the fallback through the coordinator and saves 1 row.
    const rows = await listContextCheckpoints(conversationId);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('fallback');
    expect(textOf(second[0]).startsWith(`${rows[0].text}\n\n`)).toBe(true);
  });

  it('overflow_ai_summary_compacts_then_retries_once', async () => {
    const earlier = history(16, 1600);
    const store = newStore(earlier);
    store.setState({ preferences: { ...store.getState().preferences, contextAISummaryEnabled: true } });
    responses = [httpError(400, OVERFLOW_BODY), textReply(VALID_SUMMARY), ok];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(3);
    const summaryChat = chatMessagesOf(sentBodies[1]);
    expect(textOf(summaryChat[summaryChat.length - 1])).toContain('CONTEXT CHECKPOINT');
    const retryChat = chatMessagesOf(sentBodies[2]);
    expect(retryChat[0].role).toBe('user');
    expect(textOf(retryChat[0]).startsWith(CHECKPOINT_OPEN)).toBe(true);
    expect(textOf(retryChat[0])).toContain('<summary>');
    expect(textOf(retryChat[retryChat.length - 1])).toBe('latest question');
    const rows = await listContextCheckpoints(conversationId);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe('summary');
    expect(textOf(retryChat[0]).startsWith(`${rows[0].text}\n\n`)).toBe(true);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.text).toBe('ok');
  });

  it('overflow_noop_with_stored_row_falls_back_on_full_history', async () => {
    // W unknown: the coordinator cannot get U -> noop; the fallback must reselect the tail from the full history without library rows applied, and not wrap the old library row into the new checkpoint again.
    const unknownWindow = { ...model, contextLength: undefined, maxOutputTokens: undefined } as unknown as AIModel;
    const unknownProvider = { ...provider, models: [unknownWindow] } as unknown as Provider;
    const earlier = history(16, 1600);
    const coversTo = earlier[5].id;
    const storedText = `${CHECKPOINT_OPEN} covers="m-000..${coversTo}">stored</oriveo-context-checkpoint>`;
    await putContextCheckpoint({
      conversationId,
      checkpointId: ContextCheckpoint.checkpointId(conversationId, coversTo, ContextCheckpoint.constants.packerVersion),
      kind: 'fallback',
      coversFrom: earlier[0].id,
      coversTo,
      coversDigest: ContextCheckpoint.coversDigest(earlier.slice(0, 6).map((m) => ({ id: m.id, text: m.text ?? '' }))),
      messagesCovered: 6,
      userMessageIds: [],
      text: storedText,
      summary: null,
      language: null,
      model: model.id,
      packerVersion: ContextCheckpoint.constants.packerVersion,
      createdAt: 1,
      cost: null,
    });
    const store = newStore(earlier, unknownProvider);
    responses = [httpError(400, OVERFLOW_BODY), ok];
    const conv = conversationOf(store);
    await sendMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
    }, {
      text: 'latest question', prevMessages: conv.messages, conversation: conv, provider: unknownProvider, model: unknownWindow,
      reasoningMode: 'automatic',
    }).done;

    expect(sentBodies).toHaveLength(2);
    // The first send applied a library row.
    expect(textOf(chatMessagesOf(sentBodies[0])[0]).startsWith(`${storedText}\n\n`)).toBe(true);
    const second = chatMessagesOf(sentBodies[1]);
    const joined = second.map(textOf).join('\n');
    expect(textOf(second[0]).startsWith(`${CHECKPOINT_OPEN} covers="m-000..`)).toBe(true);
    expect(joined).not.toContain(storedText);
    expect(joined.split(CHECKPOINT_OPEN)).toHaveLength(2);
    expect(textOf(second[second.length - 1])).toBe('latest question');
    expect(assistantOf(store).state).toBe('delivered');
    // The first send records its checkpointId when applying a library row; after an overflow the in-memory fallback reprojection does not.
    const manifests = await getContextManifests(conversationId);
    expect(manifests.map((m) => m.checkpointId)).toEqual([
      ContextCheckpoint.checkpointId(conversationId, coversTo, ContextCheckpoint.constants.packerVersion),
      undefined,
    ]);
  });

  it('stored_checkpoint_send_writes_manifest_checkpoint_id', async () => {
    // The send applies a library row (runChatOutbound) -> the manifest carries that row's checkpointId; after compaction is cleared, usage judges cleared_since by it.
    const earlier = history(6, 100);
    const coversTo = earlier[3].id;
    const checkpointId = ContextCheckpoint.checkpointId(conversationId, coversTo, ContextCheckpoint.constants.packerVersion);
    const storedText = `${CHECKPOINT_OPEN} covers="m-000..${coversTo}">stored</oriveo-context-checkpoint>`;
    await putContextCheckpoint({
      conversationId,
      checkpointId,
      kind: 'fallback',
      coversFrom: earlier[0].id,
      coversTo,
      coversDigest: ContextCheckpoint.coversDigest(earlier.slice(0, 4).map((m) => ({ id: m.id, text: m.text ?? '' }))),
      messagesCovered: 4,
      userMessageIds: [],
      text: storedText,
      summary: null,
      language: null,
      model: model.id,
      packerVersion: ContextCheckpoint.constants.packerVersion,
      createdAt: 1,
      cost: null,
    });
    const store = newStore(earlier);
    responses = [ok];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(1);
    expect(textOf(chatMessagesOf(sentBodies[0])[0]).startsWith(`${storedText}\n\n`)).toBe(true);
    const manifests = await getContextManifests(conversationId);
    expect(manifests.map((m) => m.checkpointId)).toEqual([checkpointId]);
  });

  it('overflow_fallback_without_tail_start_keeps_unanswered_merge', async () => {
    // W unknown: the coordinator returns noop, and the overflow resend goes through overflowFallbackChatContextAssembly. The plan history has no user message (only one big assistant message)
    // -> the fallback cannot give a tail start; the unanswered u-016 after it (a-017 failed) was originally merged into the current message, and the envelope must still be there on resend.
    const unknownWindow = { ...model, contextLength: undefined, maxOutputTokens: undefined } as unknown as AIModel;
    const unknownProvider = { ...provider, models: [unknownWindow] } as unknown as Provider;
    // The plan history has only one assistant message (no user message to serve as the tail start).
    const earlier = [{ ...history(2, 0)[1], id: 'm-000', text: `answer 0 ${'x'.repeat(40000)}` } as ChatMessage];
    const unanswered = {
      ...history(1, 0)[0], id: 'u-016', text: 'unanswered question', createdAt: new Date(Date.UTC(2026, 9, 15, 0, 1, 0)).toISOString(),
    } as ChatMessage;
    const failed = {
      ...history(2, 0)[1], id: 'a-017', text: 'partial', state: 'failed', createdAt: new Date(Date.UTC(2026, 9, 15, 0, 1, 1)).toISOString(),
    } as ChatMessage;
    const store = newStore([...earlier, unanswered, failed], unknownProvider);
    responses = [httpError(400, OVERFLOW_BODY), ok];
    const conv = conversationOf(store);
    await sendMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
    }, {
      text: 'latest question', prevMessages: conv.messages, conversation: conv, provider: unknownProvider, model: unknownWindow,
      reasoningMode: 'automatic',
    }).done;

    expect(sentBodies).toHaveLength(2);
    const firstLast = textOf(chatMessagesOf(sentBodies[0]).at(-1)!);
    expect(firstLast).toContain('<oriveo-unanswered>');
    const retry = chatMessagesOf(sentBodies[1]);
    expect(textOf(retry[0]).startsWith(`${CHECKPOINT_OPEN} covers="m-000..m-000"`)).toBe(true);
    const last = textOf(retry[retry.length - 1]);
    expect(last).toContain('<oriveo-unanswered>');
    expect(last).toContain('unanswered question');
    expect(last.endsWith('\n\nlatest question')).toBe(true);
  });

  it('overflow_fallback_keeps_latest_checkpoint_summary', async () => {
    // W unknown -> the coordinator returns noop and the overflow resend goes through the deterministic fallback; the non-empty summary (after trim) of the current library row is still carried into the new checkpoint.
    const unknownWindow = { ...model, contextLength: undefined, maxOutputTokens: undefined } as unknown as AIModel;
    const unknownProvider = { ...provider, models: [unknownWindow] } as unknown as Provider;
    const earlier = history(16, 1600);
    const coversTo = earlier[5].id;
    await putContextCheckpoint({
      conversationId,
      checkpointId: ContextCheckpoint.checkpointId(conversationId, coversTo, ContextCheckpoint.constants.packerVersion),
      kind: 'summary',
      coversFrom: earlier[0].id,
      coversTo,
      coversDigest: ContextCheckpoint.coversDigest(earlier.slice(0, 6).map((m) => ({ id: m.id, text: m.text ?? '' }))),
      messagesCovered: 6,
      userMessageIds: [],
      text: `${CHECKPOINT_OPEN} covers="m-000..${coversTo}">stored</oriveo-context-checkpoint>`,
      summary: '  old summary kept  ',
      language: null,
      model: model.id,
      packerVersion: ContextCheckpoint.constants.packerVersion,
      createdAt: 1,
      cost: null,
    });
    const store = newStore(earlier, unknownProvider);
    responses = [httpError(400, OVERFLOW_BODY), ok];
    const conv = conversationOf(store);
    await sendMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
    }, {
      text: 'latest question', prevMessages: conv.messages, conversation: conv, provider: unknownProvider, model: unknownWindow,
      reasoningMode: 'automatic',
    }).done;

    expect(sentBodies).toHaveLength(2);
    const retryCheckpoint = textOf(chatMessagesOf(sentBodies[1])[0]);
    expect(retryCheckpoint.startsWith(`${CHECKPOINT_OPEN} covers="m-000..`)).toBe(true);
    expect(retryCheckpoint).toContain('<summary>old summary kept</summary>\n</oriveo-context-checkpoint>');
    expect(assistantOf(store).state).toBe('delivered');
  });

  it('fallback_keeps_directive_user', async () => {
    // The deterministic fallback marks isDirective via the recognizer; the earliest directive-type user message goes into the checkpoint's user-messages first.
    // The history is long enough that earlier ordinary user messages do not fit (W unknown -> the coordinator returns noop, goes through fallbackChatContextAssembly).
    const unknownWindow = { ...model, contextLength: undefined, maxOutputTokens: undefined } as unknown as AIModel;
    const unknownProvider = { ...provider, models: [unknownWindow] } as unknown as Provider;
    const earlier = history(60, 6000);
    earlier[0] = { ...earlier[0], text: 'From now on, reply in English.' } as ChatMessage;
    const store = newStore(earlier, unknownProvider);
    responses = [httpError(400, OVERFLOW_BODY), ok];
    const conv = conversationOf(store);
    await sendMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
    }, {
      text: 'latest question', prevMessages: conv.messages, conversation: conv, provider: unknownProvider, model: unknownWindow,
      reasoningMode: 'automatic',
    }).done;

    expect(sentBodies).toHaveLength(2);
    const retryCheckpoint = textOf(chatMessagesOf(sentBodies[1])[0]);
    expect(retryCheckpoint.startsWith(`${CHECKPOINT_OPEN} covers="m-000..`)).toBe(true);
    expect(retryCheckpoint).toContain('<msg id="m-000">From now on, reply in English.</msg>');
    // Ordinary messages that are also early user messages are squeezed out by the budget; the earliest directive-type one is still there.
    expect(retryCheckpoint).not.toContain('<msg id="m-002">');
  });

  it('anthropic_in_stream_overflow_recovers_once', async () => {
    // In-stream stop_reason=model_context_window_exceeded with no body text yet -> same recovery as an HTTP overflow, resend once.
    const store = newStore(history(16, 1600), relayAnthropicProvider);
    responses = [anthropicInStreamOverflow(), anthropicOk];
    await send(store, 'latest question', relayAnthropicProvider);

    expect(sentBodies).toHaveLength(2);
    expect(chatMessagesOf(sentBodies[0]).some((m) => textOf(m).includes(CHECKPOINT_OPEN))).toBe(false);
    expect(textOf(chatMessagesOf(sentBodies[1])[0]).startsWith(CHECKPOINT_OPEN)).toBe(true);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.text).toBe('ok');
    expect(assistant.stopReason).not.toBe('context_window_exceeded');
    const manifests = await getContextManifests(conversationId);
    expect(manifests.map((m) => m.stopReason)).toEqual(['context_window_exceeded', 'stop']);
  });

  it('anthropic_in_stream_overflow_twice_recovers_only_once', async () => {
    const store = newStore(history(16, 1600), relayAnthropicProvider);
    responses = [anthropicInStreamOverflow(), anthropicInStreamOverflow(), anthropicOk];
    await send(store, 'latest question', relayAnthropicProvider);

    expect(sentBodies).toHaveLength(2);
    const assistant = assistantOf(store);
    // The terminal state of a second overflow is failed, the same as an HTTP second overflow.
    expect(assistant.state).toBe('failed');
    expect(assistant.stopReason).toBe('context_window_exceeded');
    expect(assistant.errorTitle).toBeTruthy();
  });

  it('anthropic_in_stream_overflow_after_reasoning_no_retry', async () => {
    // Only thinking emitted, no body text: by the same criterion as an HTTP overflow it counts as "output started", no resend, stopReason records context_window_exceeded.
    // Official Anthropic connection: the stream emits a thinking delta first, then ends normally with model_context_window_exceeded.
    const anthropic = officialProvider('anthropic');
    const store = newStore(history(16, 1600), anthropic);
    officialResponses = [{
      events: [
        { type: 'reasoning', content: 'thinking about it' },
        { type: 'done', finish: { family: 'anthropic', ended: 'clean', finishRaw: 'model_context_window_exceeded' } },
      ],
    }, 'ok'];
    await send(store, 'latest question', anthropic);

    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.text ?? '').toBe('');
    expect(assistant.reasoningText).toBe('thinking about it');
    expect(assistant.stopReason).toBe('context_window_exceeded');
  });

  it('anthropic_in_stream_overflow_after_content_no_retry', async () => {
    // Body text already emitted: ends as before, no resend, stopReason records context_window_exceeded.
    const store = newStore(history(16, 1600), relayAnthropicProvider);
    responses = [anthropicInStreamOverflow('partial answer'), anthropicOk];
    await send(store, 'latest question', relayAnthropicProvider);

    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.text).toBe('partial answer');
    expect(assistant.stopReason).toBe('context_window_exceeded');
  });

  it('in_stream_overflow_twice_fails_like_http_overflow_twice', async () => {
    // Failure display of a second overflow (title / way out) is the same in-stream and over HTTP; the body is the upstream original on both sides (error body / finishRaw) and is not compared.
    const display = (message: ChatMessage) => ({
      state: message.state, stopReason: message.stopReason, errorTitle: message.errorTitle,
      errorKind: message.errorKind, errorSource: message.errorSource,
    });
    const httpStore = newStore(history(16, 1600), relayAnthropicProvider);
    responses = [httpError(400, ANTHROPIC_OVERFLOW_BODY), httpError(400, ANTHROPIC_OVERFLOW_BODY), anthropicOk];
    await send(httpStore, 'latest question', relayAnthropicProvider);
    const streamStore = newStore(history(16, 1600), relayAnthropicProvider);
    responses = [anthropicInStreamOverflow(), anthropicInStreamOverflow(), anthropicOk];
    await send(streamStore, 'latest question', relayAnthropicProvider);
    const http = display(assistantOf(httpStore));
    expect(http.state).toBe('failed');
    expect(http.stopReason).toBe('context_window_exceeded');
    expect(display(assistantOf(streamStore))).toEqual(http);
  });

  it('overflow_twice_records_context_window_exceeded', async () => {
    const earlier = history(16, 1600);
    const store = newStore(earlier);
    responses = [httpError(400, OVERFLOW_BODY), httpError(400, OVERFLOW_BODY), ok];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(2);
    expect(textOf(chatMessagesOf(sentBodies[1])[0]).startsWith(CHECKPOINT_OPEN)).toBe(true);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('failed');
    expect(assistant.stopReason).toBe('context_window_exceeded');
    expect(assistant.errorTitle).toBeTruthy();
  });

  it('relay_anthropic_overflow_uses_anthropic_family', async () => {
    // The same connection switches to the Anthropic protocol: the overflow body is only recognized by the anthropic mode (openai_compatible does not recognize it), so family has to follow this attempt's wire protocol.
    const anthropicProvider = {
      ...provider,
      relayRequested: { transport: 'anthropic_messages', resolvedAPIBaseURL: 'https://relay.example/v1' },
      relayResolvedTransport: 'anthropic_messages', relayResolvedAuthMode: 'x_api_key',
    } as unknown as Provider;
    const store = newStore(history(16, 1600), anthropicProvider);
    responses = [httpError(400, ANTHROPIC_OVERFLOW_BODY), anthropicOk];
    await send(store, 'latest question', anthropicProvider);

    expect(sentBodies).toHaveLength(2);
    expect(textOf(chatMessagesOf(sentBodies[1])[0]).startsWith(CHECKPOINT_OPEN)).toBe(true);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.text).toBe('ok');
  });

  it('official_anthropic_overflow_uses_anthropic_family', async () => {
    // An official Anthropic connection has no relay outbound protocol: family follows that vendor's native wire protocol, anthropic, and does not fall back to openai_chat.
    const store = newStore(history(16, 1600), officialProvider('anthropic'));
    officialResponses = [{ status: 400, body: ANTHROPIC_OVERFLOW_BODY }, 'ok'];
    await send(store, 'latest question', officialProvider('anthropic'));

    expect(sentBodies).toHaveLength(2);
    expect(textOf(chatMessagesOf(sentBodies[1])[0]).startsWith(CHECKPOINT_OPEN)).toBe(true);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.text).toBe('ok');
  });

  it('official_gemini_overflow_uses_gemini_family', async () => {
    // The Gemini overflow body is only recognized by the gemini mode (openai_compatible does not recognize it).
    const store = newStore(history(16, 1600), officialProvider('gemini'));
    officialResponses = [{ status: 400, body: GEMINI_OVERFLOW_BODY }, 'ok'];
    await send(store, 'latest question', officialProvider('gemini'));

    expect(sentBodies).toHaveLength(2);
    expect(textOf(chatMessagesOf(sentBodies[1])[0]).startsWith(CHECKPOINT_OPEN)).toBe(true);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.text).toBe('ok');
  });

  it('overflow_after_content_no_retry', async () => {
    const store = newStore(history(4, 100));
    responses = [contentThenOverflowFrame, ok];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('failed');
    expect(assistant.text).toBe('partial answer');
    expect(assistant.stopReason).toBe('context_window_exceeded');
  });

  it('rate_limit_429_not_recovered', async () => {
    const store = newStore(history(16, 1600));
    responses = [httpError(429, OVERFLOW_BODY), ok];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('failed');
    expect(assistant.stopReason).toBe('error');
    const rho = await getRhoCalibration(provider.id, model.id);
    expect(rho.rho).toBe(CONTEXT_BUDGET_CONSTANTS.rho0);
  });

  it('usage_writes_rho_sample', async () => {
    const store = newStore(history(4, 100));
    responses = [okWithUsage(300)];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(1);
    expect(assistantOf(store).state).toBe('delivered');
    const textBytes = sentBodies[0].messages
      .reduce((sum, m) => sum + new TextEncoder().encode(textOf(m)).length, 0);
    const calibration = await getRhoCalibration(provider.id, model.id);
    expect(calibration.n).toBe(1);
    expect(calibration.seeds).toHaveLength(1);
    expect(calibration.seeds[0]).toBeCloseTo(300 / textBytes, 10);
  });

  it('overflow_miss_raises_rho', async () => {
    // P̂ ≈ 13k < U=18000 but it overflowed: rho is multiplied by overflowMissFactor and written back.
    const store = newStore(history(16, 1600));
    responses = [httpError(400, OVERFLOW_BODY), ok];
    await send(store, 'latest question');

    const calibration = await getRhoCalibration(provider.id, model.id);
    expect(calibration.rho).toBeCloseTo(CONTEXT_BUDGET_CONSTANTS.rho0 * CONTEXT_BUDGET_CONSTANTS.overflowMissFactor, 10);
    expect(calibration.n).toBe(0);
  });

  it('manifest_appended_per_request', async () => {
    const store = newStore(history(16, 1600));
    responses = [httpError(400, OVERFLOW_BODY), okWithUsage(9000)];
    await send(store, 'latest question');

    expect(sentBodies).toHaveLength(2);
    const manifests = await getContextManifests(conversationId);
    expect(manifests).toHaveLength(2);
    const [failed, recovered] = manifests;
    for (const manifest of manifests) {
      expect(manifest.purpose).toBe('chat');
      // transport = this attempt's StopFamily.
      expect(manifest.transport).toBe('openai_chat');
      expect(manifest.model).toBe(model.id);
      expect(manifest.W).toBe(20000);
      expect(manifest.O).toBe(1000);
      expect(manifest.B).toBe(18000);
      expect(manifest.estimatedInput).toBeGreaterThan(0);
      expect(manifest.unansweredMerged).toBe(0);
      expect(typeof manifest.reminder).toBe('boolean');
    }
    expect(failed.requestId).not.toBe(recovered.requestId);
    expect(failed.stopReason).toBe('context_window_exceeded');
    expect(failed.observedInput).toBeUndefined();
    expect(failed.basis).toBe('estimated');
    expect(recovered.basis).toBe('observed');
    expect(failed.tailFrom).toBeUndefined();
    // The stopReason of the resend matches the saved assistant message (stopReasonFromFinish) and is not an overflow.
    expect(recovered.stopReason).toBe(assistantOf(store).stopReason);
    expect(recovered.stopReason).not.toBe('context_window_exceeded');
    expect(recovered.observedInput).toBe(9000);
    // The request after the fallback is sent from the first tail message: tailFrom is the start of the original text after the message holding the checkpoint in the second request body.
    expect(recovered.tailFrom).toMatch(/^m-\d{3}$/);
    expect(recovered.estimatedInput).toBeLessThan(failed.estimatedInput);
  });

  it('http_error_carries_status_and_raw_body', async () => {
    const rateLimited = toProviderError(429, OVERFLOW_BODY);
    expect(rateLimited.status).toBe(429);
    expect(rateLimited.httpStatus).toBe(429);
    expect(rateLimited.rawBody).toBe(OVERFLOW_BODY);
    // The original keeps only the first 32 KB of UTF-8, without cutting a multi-byte character.
    const long = 'é'.repeat(20000);
    const truncated = toProviderError(400, long).rawBody ?? '';
    expect(new TextEncoder().encode(truncated).length).toBe(32 * 1024);
    expect(long.startsWith(truncated)).toBe(true);
    const unauthorized = toProviderError(401, '{"error":{"message":"bad key"}}');
    expect(unauthorized.httpStatus).toBe(401);
    expect(unauthorized.rawBody).toBe('{"error":{"message":"bad key"}}');

    // Production stream: a relay HTTP error event carries the same two items.
    responses = [httpError(400, OVERFLOW_BODY)];
    const handle = sendRelayStream('sk-relay', model.id, [{ role: 'user', content: 'hi' }] as never, 'https://relay.example/v1', {
      relayTransport: 'openai_chat_completions',
    } as StreamOptions, relayDeps() as never);
    const reader = handle.stream.getReader();
    let error: Extract<StreamEvent, { type: 'error' }> | undefined;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value.type === 'error') error = value;
    }
    expect(error?.httpStatus).toBe(400);
    expect(error?.rawBody).toBe(OVERFLOW_BODY);
  });
});
