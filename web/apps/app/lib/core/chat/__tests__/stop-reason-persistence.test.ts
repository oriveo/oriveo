// @vitest-environment jsdom

/**
 * Persistence: when an assistant message finishes, ChatMessage.stopReason is written from the stream outcome.
 * The cases go through the production sendMessage path (real stream-runner + real readStream) and assert the messages in the store.
 */

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider, Skill } from '@oriveo/shared';
import type { StreamEvent } from '@oriveo/core/providers/types';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { createAppStore } from '../../store/app-store';
import { sendMessage } from '../operations';
import { stopStream } from '../stop-stream';
import { createSSEStream } from '@oriveo/core/providers/sse-parser';
import { abortAllStreams, registerStream, __resetActiveStreamsForTests } from '../active-streams';
import { enqueueUsageEvent } from '../../usage/usage-reporter';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  /** Set = merged into the production prompt context (knowledge retrievals already run); null = unchanged. */
  retrieval: { value: null as Record<string, unknown> | null },
  sendLibraryAgentLeg: vi.fn(),
  /** Set = the external search send context (web search tool path); null = the production loader. */
  searchContext: { value: null as unknown },
}));

vi.mock('../../providers/proxy-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../providers/proxy-client')>()),
  sendLibraryAgentLeg: (...args: unknown[]) => mocks.sendLibraryAgentLeg(...args),
}));

vi.mock('../external-search-send', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../external-search-send')>();
  return {
    ...actual,
    loadExternalSearchSendContext: (...args: Parameters<typeof actual.loadExternalSearchSendContext>) =>
      mocks.searchContext.value === null ? actual.loadExternalSearchSendContext(...args) : Promise.resolve(mocks.searchContext.value),
  };
});

vi.mock('../../../search/search-settings-data', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../search/search-settings-data')>()),
  forwardSearch: vi.fn(async () => ({
    ok: true, latencyMs: 300, results: [{ title: 'Web A', url: 'https://a.example/', snippet: 'a' }],
  })),
}));

vi.mock('../../../search/search-service-store', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../search/search-service-store')>()),
  readSearchServiceKey: async () => 'tv-key-0000',
}));

vi.mock('../prompt-injection', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../prompt-injection')>();
  return {
    ...actual,
    buildChatContextSources: async (...args: Parameters<typeof actual.buildChatContextSources>) => {
      const sources = await actual.buildChatContextSources(...args);
      return mocks.retrieval.value === null
        ? sources
        : { ...sources, promptContext: { ...sources.promptContext, ...mocks.retrieval.value } };
    },
  };
});

// The system-interrupt case needs active-streams to persist into this test's store; the other cases keep the production implementation.
const systemStoreRef = vi.hoisted(() => ({ current: undefined as ReturnType<typeof createAppStore> | undefined }));
// No importOriginal: the real module would loop back to active-streams through bootstrap and get the unmocked version.
vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: () => undefined,
  getVanillaStore: () => {
    if (!systemStoreRef.current) throw new Error('Store not initialized');
    return systemStoreRef.current;
  },
  tryGetVanillaStore: () => systemStoreRef.current ?? null,
}));

vi.mock('../../providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../../../utils/chat-stream-utils', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../utils/chat-stream-utils')>()),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));

vi.mock('../../../utils/stream-image-utils', () => ({
  processImageAttachments: async (text: string) => ({ finalText: text, processedAttachments: [] }),
  backfillStorageRefs: vi.fn(async () => undefined),
}));

// Pin rhoHi so stop estimates are exact: n = 0 keeps rhoHi = rho = FIXED_RHO_HI.
const FIXED_RHO_HI = vi.hoisted(() => 0.4);
vi.mock('../../../infra/storage/context-ledger-store', async (importOriginal) => {
  const { RhoCalibration } = await import('@oriveo/core/context/calibration');
  return {
    ...(await importOriginal<typeof import('../../../infra/storage/context-ledger-store')>()),
    getRhoCalibration: async () => RhoCalibration.fromJSON({ n: 0, rho: FIXED_RHO_HI, seeds: [] }),
  };
});

vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn(async () => false) }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../infra/storage/partition', () => ({ getActiveUID: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));

vi.mock('../../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../../metadata/metadata-client')>(
    '../../metadata/metadata-client',
  );
  return {
    ...actual,
    getMetadataRevision: () => undefined,
    resolveGenerationProfileRef: vi.fn(() => undefined),
    resolveCatalogModel: vi.fn(),
    getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  };
});

function openAIProvider(): Provider {
  return {
    id: 'openai-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
  };
}

function makeModel(id: string): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: 'free',
    promptPrice: 0,
    completionPrice: 0,
  };
}

function makeConversation(provider: Provider, model: AIModel, messages: ChatMessage[] = []): Conversation {
  return {
    id: 'conv-1',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: provider.id,
    modelID: model.id,
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt: '2026-10-15T00:00:00.000Z',
  };
}

const AUTO_SKILL: Skill = {
  id: 'skill-auto', name: 'Gamma', systemPrompt: 'Use gamma rules.', whenToUse: 'When the user asks about gamma',
  autoInvoke: true, description: '', icon: '', color: '#4A90D9', modelCapabilityHint: 'any', starterMessages: [],
  knowledgeFiles: [], knowledgeBase: null, useMemory: true, isPinned: false, pinOrder: 0, source: 'user',
  sortOrder: 0, usageCount: 0, createdAt: '2026-10-01T00:00:00Z', updatedAt: '2026-10-01T00:00:00Z',
};

/**
 * Sends through sendMessage with a priced model and an auto skill (a manifest goes out), lets the stream emit
 * `events`, then stops the reply the way the stop button does and waits for the send to settle.
 */
// Exact stop estimate of sendAndStop with one 'Hello' delta at rhoHi = FIXED_RHO_HI:
// output = ceil(utf8Bytes('Hello') * rhoHi) = ceil(5 * 0.4) = 2; input = the request's budget estimatedInput.
const STOP_INPUT_ESTIMATE = 230;
const STOP_OUTPUT_ESTIMATE = Math.ceil(5 * FIXED_RHO_HI);
const STOP_SKILL_MANIFEST_TOKENS = 220;
const STOP_GENERATION_COST = STOP_INPUT_ESTIMATE * 0.000_001 + STOP_OUTPUT_ESTIMATE * 0.000_002;

async function sendAndStop(
  events: StreamEvent[],
  options: { providerModels?: AIModel[] } = {},
): Promise<ChatMessage> {
  const provider: Provider = { ...openAIProvider(), endpointSource: 'custom', models: options.providerModels ?? [] };
  const model: AIModel = { ...makeModel('gpt-4.1'), priceTier: '$', promptPrice: 0.000_001, completionPrice: 0.000_002 };
  const conversation = makeConversation(provider, model);
  const store = createAppStore({ providers: [provider], conversations: [conversation] });
  store.setState({ userSkills: [AUTO_SKILL] });
  let streamController: ReadableStreamDefaultController<StreamEvent> | undefined;
  const stream = new ReadableStream<StreamEvent>({
    start(controller) {
      streamController = controller;
      for (const event of events) controller.enqueue(event);
    },
  });
  mocks.sendStream.mockReturnValue({ stream, abort: () => streamController?.close() });
  const handle = sendMessage(
    { store, appendChunk: (chunk: string) => store.getState().appendStreamingText(conversation.id, chunk), te: (key: string) => key },
    { text: 'hello', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic' },
  );
  await vi.waitFor(() => expect(mocks.sendStream).toHaveBeenCalled());
  const shown = events.filter((event) => event.type === 'delta').map((event) => (event as { content: string }).content).join('');
  if (shown) await vi.waitFor(() => expect(store.getState().streamingTexts[conversation.id]).toBe(shown));
  const current = store.getState().conversations.find((c) => c.id === conversation.id)!;
  stopStream(store, current, current.messages, store.getState().streamingTexts[conversation.id] ?? '', handle.abort, { msgId: handle.msgId });
  await handle.done;
  const assistant = store.getState().conversations.find((c) => c.id === conversation.id)?.messages.find((m) => m.id === handle.msgId);
  if (!assistant) throw new Error('assistant message missing');
  return assistant;
}

interface ScriptedLeg {
  events: StreamEvent[];
  /** The leg the user stops: it stays open until aborted. */
  open?: boolean;
}

function scriptedLeg(leg: ScriptedLeg) {
  let streamController: ReadableStreamDefaultController<StreamEvent> | undefined;
  let closed = !leg.open;
  const stream = new ReadableStream<StreamEvent>({
    start(controller) {
      streamController = controller;
      for (const event of leg.events) controller.enqueue(event);
      if (!leg.open) controller.close();
    },
  });
  return {
    stream,
    abort: () => {
      if (closed) return;
      closed = true;
      streamController?.close();
    },
  };
}

const PROPOSE_CALL: StreamEvent = {
  type: 'tool_calls',
  toolCalls: [{
    index: 0, id: 'call_propose', type: 'function', name: 'propose_memory',
    arguments: JSON.stringify({ proposition: 'The user says hello.', kind: 'fact', scope: 'global', sourceQuote: 'hello' }),
  }],
} as StreamEvent;
const WEB_SEARCH_CALL: StreamEvent = {
  type: 'tool_calls',
  toolCalls: [{ index: 0, id: 'call_web', type: 'function', name: 'web_search', arguments: JSON.stringify({ query: 'hello' }) }],
} as StreamEvent;
/** Usage the finished leg reports. */
const FINISHED_LEG_USAGE: StreamEvent = { type: 'usage', usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 } };
const DONE: StreamEvent = { type: 'done' } as StreamEvent;

const SEARCH_MODEL = {
  id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true,
  priceTier: '$', promptPrice: 0.000_001, completionPrice: 0.000_002, contextLength: 20000, maxOutputTokens: 1000,
} as AIModel;
const SEARCH_PROVIDER = {
  id: 'relay-ctx', kind: 'relay', status: { kind: 'connected' }, models: [SEARCH_MODEL], catalogModels: [], apiKey: 'sk-relay',
  apiKeyPreview: 'sk-...', baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const SEARCH_CONTEXT = {
  state: { route: { path: 'external_tool' }, source: { method: 'external', serviceId: 'svc-tv', notice: null, nextStored: null, changed: false } },
  data: {
    uid: 'guest', catalog: { available: true, entries: [], withdrawn: [] }, connections: [],
    snapshot: {
      services: [{
        record: { id: 'svc-tv', kind: 'preset', serviceId: 'tavily', name: 'Tavily', regionId: 'global', boundHost: 'api.tavily.com', connectionRef: null, createdAt: 1, updatedAt: 1 },
        name: 'Tavily', keySource: 'own', hasKey: true, keyTail: '0000',
        row: { status: 'ready', label: 'preset', keySource: 'own', connectionName: null }, resultCount: 5,
      }],
      defaultId: 'svc-tv',
    },
  },
};

/**
 * Sends through sendMessage with a priced model, answers successive chat requests with `sendLegs` and tool / tail
 * legs with `agentLegs`, waits until the open leg showed `shown`, then stops the reply the way the stop button does.
 */
async function stopMultiLegTurn(options: {
  sendLegs?: ScriptedLeg[];
  agentLegs?: ScriptedLeg[];
  shown: string;
  webSearch?: boolean;
}): Promise<ChatMessage> {
  const provider: Provider = options.webSearch ? SEARCH_PROVIDER : { ...openAIProvider(), endpointSource: 'custom' };
  const model: AIModel = options.webSearch
    ? SEARCH_MODEL
    : { ...makeModel('gpt-4.1'), priceTier: '$', promptPrice: 0.000_001, completionPrice: 0.000_002 };
  const conversation = makeConversation(provider, model);
  const store = createAppStore({ providers: [provider], conversations: [conversation] });
  systemStoreRef.current = store;
  for (const leg of options.sendLegs ?? []) mocks.sendStream.mockImplementationOnce(() => scriptedLeg(leg));
  for (const leg of options.agentLegs ?? []) mocks.sendLibraryAgentLeg.mockImplementationOnce(() => scriptedLeg(leg));
  mocks.searchContext.value = options.webSearch ? SEARCH_CONTEXT : null;
  try {
    const handle = sendMessage(
      { store, appendChunk: (chunk: string) => store.getState().appendStreamingText(conversation.id, chunk), te: (key: string) => key },
      {
        text: 'hello', prevMessages: [], conversation, provider, model,
        // Thinking off: an unverified protocol with thinking on falls back to presearch, not the tool loop.
        ...(options.webSearch ? { webSearchEnabled: true, reasoningMode: 'fast' as const } : { reasoningMode: 'automatic' as const }),
      },
    );
    await vi.waitFor(() => expect(store.getState().streamingTexts[conversation.id] ?? '').toContain(options.shown));
    const current = store.getState().conversations.find((c) => c.id === conversation.id)!;
    stopStream(store, current, current.messages, store.getState().streamingTexts[conversation.id] ?? '', handle.abort, { msgId: handle.msgId });
    await handle.done;
    const assistant = store.getState().conversations.find((c) => c.id === conversation.id)?.messages.find((m) => m.id === handle.msgId);
    if (!assistant) throw new Error('assistant message missing');
    return assistant;
  } finally {
    mocks.searchContext.value = null;
    systemStoreRef.current = undefined;
  }
}

/** The stopped leg's own estimate: the same request stopped as the only leg after showing the same text. */
function expectFinishedLegPlusEstimate(assistant: ChatMessage, stoppedAlone: ChatMessage): void {
  expect(assistant).toMatchObject({ state: 'interrupted', stopReason: 'interrupted' });
  expect(stoppedAlone.inputTokens).toBeGreaterThan(0);
  expect(stoppedAlone.outputTokens).toBeGreaterThan(0);
  expect(assistant.inputTokens).toBe(100 + (stoppedAlone.inputTokens ?? 0));
  expect(assistant.outputTokens).toBe(20 + (stoppedAlone.outputTokens ?? 0));
}

/** Emits the given events in order; when error is non-empty, the stream ends with a transport-layer error after the events. */
function eventStream(events: StreamEvent[], error?: unknown): ReadableStream<StreamEvent> {
  // Pull one at a time: controller.error discards queued events that were not read yet, so the error must be raised only after all events have been read.
  let index = 0;
  return new ReadableStream<StreamEvent>({
    pull(controller) {
      if (index < events.length) controller.enqueue(events[index++]);
      else if (error) controller.error(error);
      else controller.close();
    },
  });
}

async function sendWith(provider: Provider, stream: ReadableStream<StreamEvent>): Promise<ChatMessage> {
  const model = makeModel('gpt-4.1');
  const conversation = makeConversation(provider, model);
  const store = createAppStore({ providers: [provider], conversations: [conversation] });
  mocks.sendStream.mockReturnValue({ stream, abort: vi.fn() });
  const handle = sendMessage(
    // Like useStreamChat, write the text into the stream dictionary (production writes the global store through the rAF batcher; here it writes this test's store directly).
    { store, appendChunk: (chunk: string) => store.getState().appendStreamingText(conversation.id, chunk), te: (key: string) => key },
    { text: 'hello', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic' },
  );
  await handle.done;
  const messages = store.getState().conversations.find((c) => c.id === conversation.id)?.messages ?? [];
  const assistant = messages.filter((m) => m.role === 'assistant').at(-1);
  if (!assistant) throw new Error('assistant message missing');
  return assistant;
}

function byteStream(text: string): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(encoder.encode(text));
      controller.close();
    },
  });
}

describe('StopReasonPersistence', () => {
  beforeEach(() => {
    mocks.sendStream.mockReset();
    mocks.buildChatHistory.mockReset();
    mocks.sendLibraryAgentLeg.mockReset();
    mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hello' }]);
  });

  it('delivered_length_from_raw_sse', async () => {
    // The raw SSE bytes are parsed by the production createSSEStream + proxy-chunk-parser, then sendMessage finishes the turn.
    const raw = [
      `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: 'Hello' } }] })}`,
      `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'length' }] })}`,
      'data: [DONE]',
      '',
    ].join('\n\n');
    const response = new Response(byteStream(raw), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
    const stream = createSSEStream(response, createProxyChunkParser('openAI'));
    const assistant = await sendWith(openAIProvider(), stream);
    expect(assistant).toMatchObject({ state: 'delivered', text: 'Hello', stopReason: 'length' });
  });

  it('delivered_length', async () => {
    const assistant = await sendWith(openAIProvider(), eventStream([
      { type: 'delta', content: 'Hello' },
      { type: 'done', finish: { family: 'openai_chat', ended: 'clean', finishRaw: 'length' } },
    ]));
    expect(assistant).toMatchObject({ state: 'delivered', text: 'Hello', stopReason: 'length' });
  });

  it('user_stop_interrupted', () => {
    const provider = openAIProvider();
    const model = makeModel('gpt-4.1');
    const generating: ChatMessage = {
      id: 'a-1',
      role: 'assistant',
      text: '',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'generating',
    };
    const conversation = makeConversation(provider, model, [generating]);
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    stopStream(store, conversation, conversation.messages, 'Half an answer', vi.fn(), { msgId: 'a-1' });
    const message = store.getState().conversations[0].messages.find((m) => m.id === 'a-1');
    expect(message).toMatchObject({ state: 'interrupted', text: 'Half an answer', stopReason: 'interrupted' });
  });

  it('user_stop_records_estimated_usage', async () => {
    // The stopped reply bills what it showed: estimated tokens, a local estimate cost,
    // the skill list overhead and one usage report; the state stays interrupted.
    vi.mocked(enqueueUsageEvent).mockClear();
    const assistant = await sendAndStop([{ type: 'delta', content: 'Hello' }]);
    expect(assistant).toMatchObject({ state: 'interrupted', text: 'Hello', stopReason: 'interrupted', costSource: 'localEstimate' });
    expect(assistant.inputTokens).toBe(STOP_INPUT_ESTIMATE);
    expect(assistant.outputTokens).toBe(STOP_OUTPUT_ESTIMATE);
    expect(assistant.estimatedCost).toBeCloseTo(STOP_GENERATION_COST, 12);
    expect(assistant.skillManifestTokens).toBe(STOP_SKILL_MANIFEST_TOKENS);
    expect(enqueueUsageEvent).toHaveBeenCalledTimes(1);
    expect(vi.mocked(enqueueUsageEvent).mock.calls[0][0].usage).toMatchObject({
      prompt_tokens: assistant.inputTokens,
      completion_tokens: assistant.outputTokens,
    });
  });

  it('user_stop_after_search_includes_retrieval_cost', async () => {
    // A knowledge retrieval that ran before the stop is a finished leg: its cost joins
    // the stopped reply's estimate and its usage is reported under its skill, as on a completed reply.
    const retrievalUsage = { prompt_tokens: 40, total_tokens: 40 };
    mocks.retrieval.value = {
      retrievalUsage,
      retrievalCost: 0.0025,
      retrievalModelId: 'text-embedding-3-small',
      skillRetrievals: [{ skillId: 'skill-kb', usage: retrievalUsage, cost: 0.0025, modelId: 'text-embedding-3-small' }],
    };
    vi.mocked(enqueueUsageEvent).mockClear();
    try {
      const assistant = await sendAndStop([{ type: 'delta', content: 'Hello' }], {
        providerModels: [makeModel('text-embedding-3-small')],
      });
      expect(assistant).toMatchObject({ state: 'interrupted', costSource: 'localEstimate' });
      expect(assistant.inputTokens).toBe(STOP_INPUT_ESTIMATE);
      expect(assistant.outputTokens).toBe(STOP_OUTPUT_ESTIMATE);
      expect(assistant.estimatedCost).toBeCloseTo(STOP_GENERATION_COST + 0.0025, 12);
      const events = vi.mocked(enqueueUsageEvent).mock.calls.map((call) => call[0]);
      expect(events).toHaveLength(2);
      expect(events).toEqual(expect.arrayContaining([
        expect.objectContaining({ skillId: 'skill-kb', source: 'skill_knowledge_retrieval', estimatedCost: 0.0025 }),
        expect.objectContaining({ usage: expect.objectContaining({ completion_tokens: assistant.outputTokens }) }),
      ]));
    } finally {
      mocks.retrieval.value = null;
    }
  });

  it('user_stop_before_output_records_nothing', async () => {
    vi.mocked(enqueueUsageEvent).mockClear();
    const assistant = await sendAndStop([]);
    expect(assistant).toMatchObject({ state: 'interrupted', stopReason: 'interrupted' });
    expect(assistant.inputTokens).toBeUndefined();
    expect(assistant.outputTokens).toBeUndefined();
    expect(assistant.skillManifestTokens).toBeUndefined();
    expect(assistant.costSource).not.toBe('localEstimate');
    expect(enqueueUsageEvent).not.toHaveBeenCalled();
  });

  it('user_stop_before_output_after_search_records_retrieval', async () => {
    // Nothing shown and no finished model leg, but a knowledge retrieval already ran: it is a
    // finished leg, so its cost lands on the message and its usage is reported; no model tokens are written.
    const retrievalUsage = { prompt_tokens: 40, total_tokens: 40 };
    mocks.retrieval.value = {
      retrievalUsage,
      retrievalCost: 0.0025,
      retrievalModelId: 'text-embedding-3-small',
      skillRetrievals: [{ skillId: 'skill-kb', usage: retrievalUsage, cost: 0.0025, modelId: 'text-embedding-3-small' }],
    };
    vi.mocked(enqueueUsageEvent).mockClear();
    try {
      const assistant = await sendAndStop([], { providerModels: [makeModel('text-embedding-3-small')] });
      expect(assistant).toMatchObject({ state: 'interrupted', stopReason: 'interrupted', costSource: 'localEstimate' });
      expect(assistant.estimatedCost).toBeCloseTo(0.0025, 10);
      expect(assistant.inputTokens).toBeUndefined();
      expect(assistant.outputTokens).toBeUndefined();
      const events = vi.mocked(enqueueUsageEvent).mock.calls.map((call) => call[0]);
      expect(events).toHaveLength(1);
      expect(events[0]).toMatchObject({ skillId: 'skill-kb', source: 'skill_knowledge_retrieval', estimatedCost: 0.0025 });
    } finally {
      mocks.retrieval.value = null;
    }
  });

  it('user_stop_after_memory_tail_first_leg_keeps_its_usage', async () => {
    // The first leg ended with propose_memory and reported usage; the tail is stopped.
    const stoppedAlone = await stopMultiLegTurn({ sendLegs: [{ events: [{ type: 'delta', content: 'Tail' }], open: true }], shown: 'Tail' });
    const assistant = await stopMultiLegTurn({
      sendLegs: [{ events: [{ type: 'delta', content: 'First. ' }, PROPOSE_CALL, FINISHED_LEG_USAGE, DONE] }],
      agentLegs: [{ events: [{ type: 'delta', content: 'Tail' }], open: true }],
      shown: 'Tail',
    });
    expect(mocks.sendLibraryAgentLeg).toHaveBeenCalledTimes(1);
    expect(assistant.text).toContain('First.');
    expectFinishedLegPlusEstimate(assistant, stoppedAlone);
  });

  it('user_stop_after_thinking_resend_first_leg_keeps_its_usage', async () => {
    // A reasoning first leg called propose_memory with no text and no continuation, so the
    // request was resent without tools; the resend is stopped.
    const stoppedAlone = await stopMultiLegTurn({ sendLegs: [{ events: [{ type: 'delta', content: 'Answer' }], open: true }], shown: 'Answer' });
    const assistant = await stopMultiLegTurn({
      sendLegs: [
        { events: [{ type: 'reasoning', content: 'Thinking it over.' }, PROPOSE_CALL, FINISHED_LEG_USAGE, DONE] },
        { events: [{ type: 'delta', content: 'Answer' }], open: true },
      ],
      shown: 'Answer',
    });
    expect(mocks.sendStream).toHaveBeenCalledTimes(3);
    expectFinishedLegPlusEstimate(assistant, stoppedAlone);
  });

  it('user_stop_during_search_tool_loop_keeps_finished_leg_usage', async () => {
    // The web_search leg finished with cumulative usage; the answer leg is stopped.
    const stoppedAlone = await stopMultiLegTurn({
      agentLegs: [{ events: [{ type: 'delta', content: 'Partial' }], open: true }],
      shown: 'Partial',
      webSearch: true,
    });
    const assistant = await stopMultiLegTurn({
      agentLegs: [
        { events: [WEB_SEARCH_CALL, FINISHED_LEG_USAGE, DONE] },
        { events: [{ type: 'delta', content: 'Partial' }], open: true },
      ],
      shown: 'Partial',
      webSearch: true,
    });
    expect(mocks.sendLibraryAgentLeg).toHaveBeenCalledTimes(3);
    expectFinishedLegPlusEstimate(assistant, stoppedAlone);
  });

  it('system_interrupt_logout_incomplete', () => {
    // Logout / partition switch goes through abortAllStreams: recorded as a transport-layer interruption -- incomplete when there is text, error when there is none (not a user stop).
    const provider = openAIProvider();
    const model = makeModel('gpt-4.1');
    const generating = (id: string): ChatMessage => ({
      id,
      role: 'assistant',
      text: '',
      providerID: provider.id,
      providerKind: provider.kind,
      providerName: 'OpenAI',
      modelID: model.id,
      modelName: model.name,
      estimatedCost: 0,
      state: 'generating',
    });
    const withText = { ...makeConversation(provider, model, [generating('a-1')]), id: 'conv-text' };
    const empty = { ...makeConversation(provider, model, [generating('a-2')]), id: 'conv-empty' };
    const store = createAppStore({ providers: [provider], conversations: [withText, empty] });
    systemStoreRef.current = store;
    try {
      __resetActiveStreamsForTests();
      store.getState().beginStreamingForConversation('conv-text', 'a-1');
      store.getState().beginStreamingForConversation('conv-empty', 'a-2');
      registerStream({ conversationId: 'conv-text', msgId: 'a-1', abort: vi.fn(), startedAt: Date.now() });
      registerStream({ conversationId: 'conv-empty', msgId: 'a-2', abort: vi.fn(), startedAt: Date.now() });
      store.getState().appendStreamingText('conv-text', 'Half an answer');

      abortAllStreams();

      const message = (convId: string, msgId: string) =>
        store.getState().conversations.find((c) => c.id === convId)?.messages.find((m) => m.id === msgId);
      expect(message('conv-text', 'a-1')).toMatchObject({ text: 'Half an answer', stopReason: 'incomplete' });
      expect(message('conv-empty', 'a-2')).toMatchObject({ stopReason: 'error' });
    } finally {
      __resetActiveStreamsForTests();
      systemStoreRef.current = undefined;
    }
  });

  it('transport_error_after_text', async () => {
    const assistant = await sendWith(openAIProvider(), eventStream(
      [{ type: 'delta', content: 'Partial answer' }],
      new TypeError('Failed to fetch'),
    ));
    expect(assistant).toMatchObject({ state: 'failed', stopReason: 'incomplete' });
  });

  it('transport_error_before_text', async () => {
    const assistant = await sendWith(openAIProvider(), eventStream([], new TypeError('Failed to fetch')));
    expect(assistant).toMatchObject({ state: 'failed', stopReason: 'error' });
  });
});
