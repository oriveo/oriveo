// @vitest-environment jsdom
//
// Pins the end-to-end rule that the UI must show feedback during a long thinking window that
// contains nothing but heartbeats.
//
// Background: upstreams such as DeepSeek send only `reasoning_content: ""` heartbeats while
// thinking at length, and emit the actual reasoning in one go once thinking ends; the first
// non-empty reasoning chunk was measured at 279s. The parser layer forwards the empty string,
// but three downstream gates further on only count non-empty text (readStream, stream-batcher,
// MessageBubble), so on the production path the heartbeat was swallowed again and the screen
// stayed blank for minutes.
//
// A suite that tests each layer in isolation goes green without holding that chain together, so
// this one drives the production parser (`createProxyChunkParser`) through the real `readStream`,
// the real `runStreamPipeline` and the real store, and asserts on the piece of store state
// MessageBubble actually subscribes to.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { createAppStore } from '../../store/app-store';
import {
  makeSelectStreamingReasoningActive,
  makeSelectStreamingReasoningText,
} from '../../store/selectors';
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

// stream-batcher reads the module-level vanilla store directly; the tests swap in a store built per case.
let currentStore: ReturnType<typeof createAppStore>;
vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => currentStore,
}));

const CONV_ID = 'conv-1';
const MSG_ID = 'assistant-1';

function byokProvider(): Provider {
  return {
    id: 'p-1',
    kind: 'deepSeek',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-…',
  } as unknown as Provider;
}

function model(): AIModel {
  return {
    id: 'deepseek-reasoner',
    name: 'DeepSeek Reasoner',
    capabilities: ['text'],
    reasoningModeAvailable: true,
    isAvailable: true,
    isDefault: true,
    priceTier: '$0.55 / 1M input',
  } as unknown as AIModel;
}

/**
 * Turn realistically shaped upstream SSE data lines into StreamEvents with the production parser,
 * then wrap them in a stream. Hand-writing `{ type: 'reasoning', content: '' }` is avoided on
 * purpose, because a hand-made event cannot catch a regression in the parser layer.
 */
function streamFromUpstreamChunks(dataLines: string[]) {
  const parse = createProxyChunkParser('deepSeek');
  const events = dataLines.flatMap((line) => parse(undefined, line));
  return {
    events,
    stream: new ReadableStream({
      start(ctrl) {
        for (const event of events) ctrl.enqueue(event);
        ctrl.close();
      },
    }),
  };
}

async function runHeartbeatPipeline(dataLines: string[]) {
  const { events, stream } = streamFromUpstreamChunks(dataLines);
  mocks.sendStream.mockReturnValue({ stream, abort: vi.fn() });
  const result = await runStreamPipeline({
    store: currentStore as never,
    appendChunk: vi.fn(),
    conversationId: CONV_ID,
    messageId: MSG_ID,
    provider: byokProvider(),
    model: model(),
    chatHistory: [{ role: 'user', content: 'hi' }],
    initialText: '',
    relayStreamOptions: undefined,
    setAbortFn: vi.fn(),
  });
  return { events, result };
}

describe('Feedback during a long thinking window of pure heartbeats', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    __resetStreamBatcherForTests();
    mocks.createPartialFlushScheduler.mockReturnValue({ onChunk: vi.fn(), dispose: vi.fn() });
    currentStore = createAppStore();
    currentStore.setState({
      conversations: [
        {
          id: CONV_ID,
          messages: [{ id: MSG_ID, state: 'generating' }],
        },
      ] as never,
    });
    currentStore.getState().beginStreamingForConversation(CONV_ID, MSG_ID);
  });

  it('marks thinking as started in the store once the parser forwards a pure empty-string heartbeat, without pushing empty strings into the text pipeline', async () => {
    const heartbeat = '{"choices":[{"delta":{"reasoning_content":""}}]}';
    const { events } = await runHeartbeatPipeline([heartbeat, heartbeat, heartbeat]);

    // 1. Parser layer: each heartbeat produces one reasoning event whose content is an empty string
    expect(events).toEqual([
      { type: 'reasoning', content: '' },
      { type: 'reasoning', content: '' },
      { type: 'reasoning', content: '' },
    ]);

    // 2. State the UI subscribes to: MessageBubble lights up "Thinking..." from this boolean
    const state = currentStore.getState();
    expect(
      makeSelectStreamingReasoningActive(CONV_ID)(state),
      'streamingReasoningActive must not be false: MessageBubble drives the thinking indicator '
        + 'from it, and without it the user stares at a spinner for minutes with no way to tell '
        + 'thinking from a hang. Check `if (event.content)` in readStream and onReasoningChunk in stream-runner.',
    ).toBe(true);

    // 3. An empty string must not enter the text pipeline; appending it changes nothing and only wastes a rAF plus a store set
    expect(makeSelectStreamingReasoningText(CONV_ID)(state)).toBe('');
  });

  it('keeps accumulating once real reasoning content arrives after the heartbeats, with the marker still set', async () => {
    const { result } = await runHeartbeatPipeline([
      '{"choices":[{"delta":{"reasoning_content":""}}]}',
      '{"choices":[{"delta":{"reasoning_content":"Read the question first, "}}]}',
      '{"choices":[{"delta":{"reasoning_content":"then give the conclusion"}}]}',
    ]);

    const state = currentStore.getState();
    expect(makeSelectStreamingReasoningActive(CONV_ID)(state)).toBe(true);
    expect(result.reasoningText).toBe('Read the question first, then give the conclusion');
    expect(result.reasoningDurationMs).toBeTypeOf('number');
  });

  it('records no phantom duration when only empty heartbeats ever arrive, so there is no "Thought for Ns" without any thinking content', async () => {
    const { result } = await runHeartbeatPipeline([
      '{"choices":[{"delta":{"reasoning_content":""}}]}',
      '{"choices":[{"delta":{"content":"the answer"}}]}',
    ]);

    expect(result.reasoningText).toBe('');
    expect(result.reasoningDurationMs).toBeUndefined();
  });

  it('produces no event and does not light up thinking when the reasoning field is absent', async () => {
    const { events } = await runHeartbeatPipeline(['{"choices":[{"delta":{"content":"the answer"}}]}']);

    expect(events.some((e) => e.type === 'reasoning')).toBe(false);
    expect(makeSelectStreamingReasoningActive(CONV_ID)(currentStore.getState())).toBe(false);
  });
});
