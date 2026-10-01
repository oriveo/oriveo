// @vitest-environment jsdom
//
// Locks the end-to-end path behind "a web search that follows body text must not go silent".
//
// Frames enter through the production parser and run through the real readStream, the real
// runStreamPipeline and the real store. The assertions read `streamingActivities`, the value
// MessageBubble actually subscribes to, and no activity event is written by hand.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { createAppStore } from '../../store/app-store';
import { makeSelectStreamingActivity } from '../../store/selectors';
import { runStreamPipeline } from '../stream-runner';
import { __resetStreamBatcherForTests } from '../stream-batcher';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  createPartialFlushScheduler: vi.fn(),
  applyCitationsToMessage: vi.fn(),
}));

vi.mock('../../providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../partial-flush', () => ({
  createPartialFlushScheduler: (...args: unknown[]) => mocks.createPartialFlushScheduler(...args),
}));

vi.mock('../cost-fields', () => ({
  applyCitationsToMessage: (...args: unknown[]) => mocks.applyCitationsToMessage(...args),
}));

let currentStore: ReturnType<typeof createAppStore>;
vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => currentStore,
}));

const CONV_ID = 'conv-1';
const MSG_ID = 'assistant-1';

const text = (value: string) =>
  ['content_block_delta', JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: value } })] as const;
const thinking = (value: string) =>
  ['content_block_delta', JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: value } })] as const;
// Copied verbatim from a recording of a real Anthropic web-search stream.
const SEARCH_START = [
  'content_block_start',
  '{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01bug3W20DWB0LwoUvGoH0nW","name":"web_search","input":{}}}',
] as const;

async function runAnthropicPipeline(frames: ReadonlyArray<readonly [string, string]>) {
  const parse = createProxyChunkParser('anthropic');
  const events = frames.flatMap(([eventType, data]) => parse(eventType, data) ?? []);
  mocks.sendStream.mockReturnValue({
    stream: new ReadableStream({
      start(ctrl) {
        for (const event of events) ctrl.enqueue(event);
        ctrl.close();
      },
    }),
    abort: vi.fn(),
  });
  // Record every change of the value the UI subscribes to. The stream runs to completion
  // synchronously, so the final state alone cannot tell "set and then cleared" from "never set".
  const select = makeSelectStreamingActivity(CONV_ID);
  const seen = [select(currentStore.getState())];
  const unsubscribe = currentStore.subscribe((state) => {
    const next = select(state);
    if (next !== seen[seen.length - 1]) seen.push(next);
  });
  await runStreamPipeline({
    store: currentStore as never,
    appendChunk: vi.fn(),
    conversationId: CONV_ID,
    messageId: MSG_ID,
    provider: { id: 'p-1', kind: 'anthropic', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test' } as unknown as Provider,
    model: { id: 'claude-sonnet-5', name: 'Claude Sonnet 5', capabilities: ['text', 'web'], isAvailable: true } as unknown as AIModel,
    chatHistory: [{ role: 'user', content: 'hi' }],
    initialText: '',
    relayStreamOptions: undefined,
    setAbortFn: vi.fn(),
  });
  unsubscribe();
  return seen;
}

describe('stream activity: set and clear', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    __resetStreamBatcherForTests();
    mocks.createPartialFlushScheduler.mockReturnValue({ onChunk: vi.fn(), dispose: vi.fn() });
    currentStore = createAppStore();
    currentStore.setState({
      conversations: [{ id: CONV_ID, messages: [{ id: MSG_ID, state: 'generating' }] }] as never,
    });
    currentStore.getState().beginStreamingForConversation(CONV_ID, MSG_ID);
  });

  it('text -> search start -> text: the activity is set during the search and cleared when the model speaks again', async () => {
    const seen = await runAnthropicPipeline([text('Let me search this repository.'), SEARCH_START, text('The search results show...')]);
    expect(seen).toEqual([null, 'web_search', null]);
  });

  it('non-empty reasoning right after the search clears it too', async () => {
    const seen = await runAnthropicPipeline([SEARCH_START, thinking('Sorting through the search results')]);
    expect(seen).toEqual([null, 'web_search', null]);
  });

  it('stream ends mid-search: clearing the stream removes the activity with the conversation, and a late event cannot bring it back', async () => {
    const seen = await runAnthropicPipeline([text('Let me search.'), SEARCH_START]);
    expect(seen).toEqual([null, 'web_search']);

    currentStore.getState().clearStreamingForConversation(CONV_ID);
    expect(CONV_ID in currentStore.getState().streamingActivities).toBe(false);

    currentStore.getState().setStreamingActivity(CONV_ID, 'web_search');
    expect(CONV_ID in currentStore.getState().streamingActivities).toBe(false);
  });
});
