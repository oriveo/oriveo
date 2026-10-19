// @vitest-environment jsdom

/**
 * Persistence: when an assistant message finishes, ChatMessage.stopReason is written from the stream outcome.
 * The cases go through the production sendMessage path (real stream-runner + real readStream) and assert the messages in the store.
 */

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamEvent } from '@oriveo/core/providers/types';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { createAppStore } from '../../store/app-store';
import { sendMessage } from '../operations';
import { stopStream } from '../stop-stream';
import { createSSEStream } from '@oriveo/core/providers/sse-parser';
import { abortAllStreams, registerStream, __resetActiveStreamsForTests } from '../active-streams';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
}));

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

/** Emits the given events in order; when error is set, the stream ends with a transport-layer error after the events. */
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
