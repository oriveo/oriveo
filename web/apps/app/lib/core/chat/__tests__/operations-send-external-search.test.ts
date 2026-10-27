import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * External web search tool path on the plain send path: the rejection check only considers the first leg, context overflow takes precedence over rejection,
 * and this turn's internal overflow resend reuses the web results already produced.
 * Runs the real sendMessage → runChatOutbound → generic ToolCallLoop; only the network layer (tool-loop leg sendLibraryAgentLeg,
 * Relay transport.fetch) and local search sources / forwarding are replaced. The overflow-resend request body is read from what the production Relay orchestration layer actually sends via transport.fetch.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '@oriveo/core/providers/types';
import { withProviderErrorRawBody } from '@oriveo/core/providers/errors';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  sendLibraryAgentLeg: vi.fn(),
  store: null as unknown,
  searchContext: vi.fn(async (_input: unknown): Promise<unknown> => null),
  forwardSearch: vi.fn(),
  searchKey: vi.fn(async (_uid: string, _id: string): Promise<string | null> => 'tv-key-0000'),
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../providers/proxy-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../providers/proxy-client')>()),
  sendLibraryAgentLeg: (...args: unknown[]) => mocks.sendLibraryAgentLeg(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../external-search-send', () => ({
  loadExternalSearchSendContext: (input: unknown) => mocks.searchContext(input),
}));
vi.mock('../../../search/search-settings-data', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../search/search-settings-data')>()),
  forwardSearch: (...args: unknown[]) => mocks.forwardSearch(...args),
}));
vi.mock('../../../search/search-service-store', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../search/search-service-store')>()),
  readSearchServiceKey: (uid: string, id: string) => mocks.searchKey(uid, id),
}));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { __resetToolsRejectedForTests } from '../external-search-turn';

// W=20000, O=1000: ~13k tokens of history is below the 0.90 line (first send has no fallback); after overflow the fallback can produce a checkpoint.
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

const OVERFLOW_BODY = JSON.stringify({
  error: {
    message: "This model's maximum context length is 20000 tokens. However, your messages resulted in 21000 tokens.",
    type: 'invalid_request_error',
    code: 'context_length_exceeded',
  },
});
const BAD_REQUEST_BODY = JSON.stringify({ error: { message: 'Invalid tool_call_id', type: 'invalid_request_error' } });

const view = {
  record: { id: 'svc-tv', kind: 'preset', serviceId: 'tavily', name: 'Tavily', regionId: 'global', boundHost: 'api.tavily.com', connectionRef: null, createdAt: 1, updatedAt: 1 },
  name: 'Tavily',
  keySource: 'own',
  hasKey: true,
  keyTail: '0000',
  row: { status: 'ready', label: 'preset', keySource: 'own', connectionName: null },
  resultCount: 5,
};
const searchContext = {
  state: { route: { path: 'external_tool' }, source: { method: 'external', serviceId: 'svc-tv', notice: null, nextStored: null, changed: false } },
  data: { uid: 'guest', catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view], defaultId: 'svc-tv' } },
};

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
const sse = (frames: string[]) => new Response(frames.map((f) => `data: ${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});

/** One tool-loop leg: emits StreamEvents from a script. */
function leg(events: StreamEvent[]) {
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        for (const event of events) controller.enqueue(event);
        controller.close();
      },
    }),
    abort: () => undefined,
  };
}
const webSearchCallLeg = () => leg([
  { type: 'tool_calls', toolCalls: [{ index: 0, id: 'call_web', type: 'function', name: 'web_search', arguments: JSON.stringify({ query: 'roadmap 2026' }) }] },
  { type: 'done' } as StreamEvent,
]);
/** HTTP error leg before any text: the raw error body is carried as a non-enumerable property (same shape as proxy-client). */
const httpErrorLeg = (status: number, body: string) => leg([
  withProviderErrorRawBody({
    type: 'error', error: 'upstream error', errorKind: 'invalid_request', source: 'provider', status, httpStatus: status,
  } as StreamEvent, body),
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

let conversationId = 'conv-web-0';
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
function assistantOf(store: ReturnType<typeof createAppStore>) {
  const assistants = conversationOf(store).messages.filter((m) => m.role === 'assistant' && !m.id.startsWith('m-'));
  expect(assistants).toHaveLength(1);
  return assistants[0];
}
function textOf(message: WireMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}

async function send(store: ReturnType<typeof createAppStore>, text: string) {
  const conv = conversationOf(store);
  await sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
  }, {
    text, prevMessages: conv.messages, conversation: conv, provider, model, reasoningMode: 'fast', webSearchEnabled: true,
  }).done;
}

beforeEach(() => {
  conversationSeq += 1;
  conversationId = `conv-web-${conversationSeq}`;
  localStorage.clear();
  sentBodies.length = 0;
  __resetMetadataClientForTest();
  __resetToolsRejectedForTests();
  mocks.searchContext.mockReset().mockResolvedValue(searchContext);
  mocks.forwardSearch.mockReset().mockResolvedValue({
    ok: true,
    latencyMs: 300,
    results: [
      { title: 'Web A', url: 'https://a.example/', snippet: 'a' },
      { title: 'Web B', url: 'https://b.example/', snippet: 'b' },
    ],
  });
  mocks.sendLibraryAgentLeg.mockReset();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url: string, init: { body?: unknown }) => {
          sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
          return sse(['{"choices":[{"delta":{"content":"Answer [1]"}}]}', '[DONE]']);
        },
      },
      buildFetchArgs: (url: string, headers: Record<string, string>) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    } as never));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('plain send · external search tool path', () => {
  it('second-leg 400 does not switch to pre-search: fails as a plain error, no new reply state, no tools_rejected recorded', async () => {
    const store = newStore([]);
    mocks.sendLibraryAgentLeg
      .mockImplementationOnce(webSearchCallLeg)
      .mockImplementationOnce(() => httpErrorLeg(400, BAD_REQUEST_BODY));
    await send(store, 'What is on the roadmap?');

    expect(mocks.sendLibraryAgentLeg).toHaveBeenCalledTimes(2);
    // Only the model's own web_search issued a search; there was no extra pre-search with the original text and no re-answer without tools.
    expect(mocks.forwardSearch).toHaveBeenCalledTimes(1);
    expect(mocks.forwardSearch.mock.calls[0][0]).toMatchObject({ query: 'roadmap 2026' });
    expect(mocks.sendStream).not.toHaveBeenCalled();
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('failed');
    expect(assistant.searchNotice).toBeUndefined();
  });

  it('first-leg 400 recognized as context overflow: goes through overflow recovery, not counted as tools rejection, no pre-search', async () => {
    const store = newStore(history(16, 1600));
    mocks.sendLibraryAgentLeg.mockImplementationOnce(() => httpErrorLeg(400, OVERFLOW_BODY));
    await send(store, 'What is on the roadmap?');

    expect(mocks.sendLibraryAgentLeg).toHaveBeenCalledTimes(1);
    expect(mocks.forwardSearch).not.toHaveBeenCalled();
    // Overflow recovery resent once (the request body actually sent by the Relay orchestration layer).
    expect(sentBodies).toHaveLength(1);
    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.searchNotice).toBeUndefined();
  });

  it('tool-path overflow resend: [D] carries the envelope rebuilt from this turn\'s sources via reuse, the executor is not called again, and persisted sources match the envelope numbering', async () => {
    const store = newStore(history(16, 1600));
    mocks.sendLibraryAgentLeg
      .mockImplementationOnce(webSearchCallLeg)
      .mockImplementationOnce(() => httpErrorLeg(400, OVERFLOW_BODY));
    await send(store, 'What is on the roadmap?');

    expect(mocks.sendLibraryAgentLeg).toHaveBeenCalledTimes(2);
    expect(mocks.forwardSearch).toHaveBeenCalledTimes(1);
    expect(sentBodies).toHaveLength(1);
    const wire = sentBodies[0].messages.map(textOf).join('\n');
    expect(wire).toContain('<oriveo-web provider="Tavily" query="roadmap 2026"');
    const ids = [...wire.matchAll(/<result id="(\d+)"/g)].map((m) => Number(m[1]));
    expect(ids).toEqual([1, 2]);
    // The resend does not register web_search.
    expect(JSON.stringify(sentBodies[0])).not.toContain('"web_search"');

    const assistant = assistantOf(store);
    expect(assistant.state).toBe('delivered');
    expect(assistant.citations?.filter((c) => c.source === 'external_search').map((c) => [c.index, c.url])).toEqual([
      [1, 'https://a.example/'], [2, 'https://b.example/'],
    ]);
    expect(assistant.capabilityResults).toEqual([expect.objectContaining({ source: 'external_search', state: 'observed', searchCount: 1 })]);
  });
});
