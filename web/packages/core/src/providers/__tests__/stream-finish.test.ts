import { describe, expect, it } from 'vitest';
import type { ProviderKind } from '@oriveo/shared/pure-types';
import type { TransportResponse } from '../../ports';
import { StopReasonResolver } from '../../context/stop-reason';
import { createProxyChunkParser, type ContinuationCaptureConfig } from '../proxy-chunk-parser';
import { sendRelayStream, type RelayOrchestratorDeps } from '../relay-orchestrator';
import { adaptGeminiInteractionsResponse } from '../response-adapters/gemini-interactions';
import { createSSEStream } from '../sse-parser';
import type { StreamEvent } from '../types';

/**
 * Raw SSE bytes go through the production createSSEStream + createProxyChunkParser; done (or a terminal
 * frame that throws) carries a StreamFinish, and a dropped stream is no longer treated as clean.
 */

function responseOf(raw: string): TransportResponse {
  const bytes = new TextEncoder().encode(raw);
  let sent = false;
  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (!sent) { sent = true; ctrl.enqueue(bytes); } else ctrl.close();
    },
  });
  return { ok: true, status: 200, body, text: async () => '', headers: new Headers(), url: '' } as unknown as TransportResponse;
}

async function run(provider: ProviderKind, raw: string, capture?: ContinuationCaptureConfig): Promise<StreamEvent[]> {
  return collect(responseOf(raw), provider, capture);
}

async function collect(response: TransportResponse, provider: ProviderKind, capture?: ContinuationCaptureConfig): Promise<StreamEvent[]> {
  const reader = createSSEStream(response, createProxyChunkParser(provider, capture)).getReader();
  const events: StreamEvent[] = [];
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

function sse(frames: Array<[string | null, unknown]>, tail = ''): string {
  return frames.map(([event, data]) => `${event ? `event: ${event}\n` : ''}data: ${JSON.stringify(data)}\n\n`).join('') + tail;
}

function doneEvent(events: StreamEvent[]): Extract<StreamEvent, { type: 'done' }> {
  const done = events.find((event) => event.type === 'done');
  if (!done || done.type !== 'done') throw new Error('no done event');
  return done;
}

function errorEvent(events: StreamEvent[]): Extract<StreamEvent, { type: 'error' }> {
  const error = events.find((event) => event.type === 'error');
  if (!error || error.type !== 'error') throw new Error('no error event');
  return error;
}

const chatDelta = { model: 'gpt-x', choices: [{ index: 0, delta: { content: 'hi' } }] };

describe('StreamFinish', () => {
  it('openai_chat_done_with_length', async () => {
    const events = await run('openAI', sse([
      [null, chatDelta],
      [null, { choices: [{ index: 0, delta: {}, finish_reason: 'length' }] }],
    ], 'data: [DONE]\n\n'));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'openai_chat', ended: 'clean', finishRaw: 'length' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('length');
  });

  it('openai_chat_finish_without_done', async () => {
    const events = await run('openAI', sse([
      [null, chatDelta],
      [null, { choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] }],
    ]));
    expect(doneEvent(events).finish).toEqual({ family: 'openai_chat', ended: 'clean', finishRaw: 'stop' });
  });

  it('openai_chat_eof_without_marker', async () => {
    const events = await run('openAI', sse([[null, chatDelta]]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'openai_chat', ended: 'eof_without_marker' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('incomplete');
  });

  const responsesDelta: [string, unknown] = ['response.output_text.delta', { type: 'response.output_text.delta', delta: 'hi' }];

  it('responses_completed', async () => {
    const events = await run('openAI', sse([
      responsesDelta,
      ['response.completed', { type: 'response.completed', response: { status: 'completed', usage: { input_tokens: 3, output_tokens: 1 } } }],
    ]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'completed' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('stop');
  });

  it('responses_incomplete_max_output_tokens', async () => {
    const events = await run('openAI', sse([
      responsesDelta,
      ['response.incomplete', {
        type: 'response.incomplete',
        response: { status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } },
      }],
    ]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'incomplete:max_output_tokens' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('length');
  });

  it('responses_incomplete_without_reason', async () => {
    const events = await run('openAI', sse([
      responsesDelta,
      ['response.incomplete', { type: 'response.incomplete', response: { status: 'incomplete' } }],
    ]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'incomplete' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('incomplete');
  });

  it('responses_incomplete_keeps_usage', async () => {
    const events = await run('openAI', sse([
      responsesDelta,
      ['response.incomplete', {
        type: 'response.incomplete',
        response: {
          status: 'incomplete',
          incomplete_details: { reason: 'max_output_tokens' },
          usage: { input_tokens: 7, output_tokens: 5 },
        },
      }],
    ]));
    const usage = events.find((event) => event.type === 'usage');
    expect(usage).toMatchObject({ type: 'usage', usage: { prompt_tokens: 7, completion_tokens: 5, total_tokens: 12 } });
    expect(doneEvent(events).finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'incomplete:max_output_tokens' });
  });

  it('responses_incomplete_keeps_continuation_id', async () => {
    const events = await run('openAI', sse([
      responsesDelta,
      ['response.incomplete', {
        type: 'response.incomplete',
        response: { id: 'resp_incomplete_1', status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } },
      }],
    ]), { kind: 'previous_id', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1' });
    const continuation = events.find((event) => event.type === 'continuation');
    expect(continuation).toMatchObject({
      type: 'continuation',
      continuation: { kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_incomplete_1' } },
    });
    expect(doneEvent(events).finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'incomplete:max_output_tokens' });
  });

  it('responses_failed_carries_finish', async () => {
    const events = await run('openAI', sse([
      responsesDelta,
      ['response.failed', { type: 'response.failed', response: { status: 'failed', error: { code: 'server_error', message: 'boom' } } }],
    ]));
    const error = errorEvent(events);
    expect(error.finish).toEqual({ family: 'openai_responses', ended: 'clean', finishRaw: 'failed' });
    expect(StopReasonResolver.resolve(error.finish!.family, error.finish!.ended, error.finish!.finishRaw, true)).toBe('error');
  });

  it('responses_eof_without_marker', async () => {
    const events = await run('openAI', sse([responsesDelta]));
    expect(doneEvent(events).finish).toEqual({ family: 'openai_responses', ended: 'eof_without_marker' });
  });

  const anthropicHead: Array<[string, unknown]> = [
    ['message_start', { type: 'message_start', message: { usage: { input_tokens: 3 } } }],
    ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'hi' } }],
  ];
  const anthropicDelta = (stopReason: string): [string, unknown] =>
    ['message_delta', { type: 'message_delta', delta: { stop_reason: stopReason }, usage: { output_tokens: 1 } }];
  const messageStop: [string, unknown] = ['message_stop', { type: 'message_stop' }];

  it('anthropic_max_tokens', async () => {
    const events = await run('anthropic', sse([...anthropicHead, anthropicDelta('max_tokens'), messageStop]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'anthropic', ended: 'clean', finishRaw: 'max_tokens' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('length');
  });

  it('anthropic_context_window_exceeded', async () => {
    const events = await run('anthropic', sse([...anthropicHead, anthropicDelta('model_context_window_exceeded'), messageStop]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'anthropic', ended: 'clean', finishRaw: 'model_context_window_exceeded' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('context_window_exceeded');
  });

  it('anthropic_eof_before_message_stop', async () => {
    const events = await run('anthropic', sse([...anthropicHead, anthropicDelta('end_turn')]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'anthropic', ended: 'eof_without_marker', finishRaw: 'end_turn' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('incomplete');
  });

  const geminiText = { candidates: [{ content: { parts: [{ text: 'hi' }] } }] };

  it('gemini_max_tokens', async () => {
    const events = await run('gemini', sse([
      [null, geminiText],
      [null, { candidates: [{ content: { parts: [{ text: '!' }] }, finishReason: 'MAX_TOKENS' }] }],
    ]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'gemini', ended: 'clean', finishRaw: 'MAX_TOKENS' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('length');
  });

  it('gemini_eof_without_finish_reason', async () => {
    const events = await run('gemini', sse([[null, geminiText]]));
    expect(doneEvent(events).finish).toEqual({ family: 'gemini', ended: 'eof_without_marker' });
  });

  it('gemini_interactions_closed_is_eof', async () => {
    // The upstream SSE dropped before interaction.completed: the production adapter writes an interaction_stream_closed error frame.
    const upstream = new Response(new TextEncoder().encode(''), { headers: { 'Content-Type': 'text/event-stream' } });
    const adapted = adaptGeminiInteractionsResponse(upstream);
    const events = await collect(
      { ok: true, status: 200, body: adapted.body, text: async () => '', headers: new Headers(), url: '' } as unknown as TransportResponse,
      'gemini',
    );
    const error = errorEvent(events);
    expect(error.finish).toEqual({ family: 'gemini_interactions', ended: 'eof_without_marker' });
    expect(StopReasonResolver.resolve(error.finish!.family, error.finish!.ended, error.finish!.finishRaw, false)).toBe('incomplete');
  });

  async function interactionsEvents(status: string): Promise<StreamEvent[]> {
    const raw = sse([
      [null, { event_type: 'step.delta', delta: { type: 'text', text: 'hi' } }],
      [null, { event_type: 'interaction.completed', interaction: { status } }],
    ]);
    const adapted = adaptGeminiInteractionsResponse(new Response(raw, { headers: { 'Content-Type': 'text/event-stream' } }));
    return collect(
      { ok: true, status: 200, body: adapted.body, text: async () => '', headers: new Headers(), url: '' } as unknown as TransportResponse,
      'gemini',
    );
  }

  it.each([
    ['completed', 'stop'],
    ['incomplete', 'length'],
  ] as const)('gemini_interactions_%s_done_carries_status', async (status, expected) => {
    const { finish } = doneEvent(await interactionsEvents(status));
    expect(finish).toEqual({ family: 'gemini_interactions', ended: 'clean', finishRaw: status });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe(expected);
  });

  it.each([
    ['requires_action', 'tool'],
    ['failed', 'error'],
    ['cancelled', 'unknown'],
  ] as const)('gemini_interactions_%s_error_carries_status', async (status, expected) => {
    const events = await interactionsEvents(status);
    const error = errorEvent(events);
    expect(error.finish).toEqual({ family: 'gemini_interactions', ended: 'clean', finishRaw: status });
    expect(StopReasonResolver.resolve(error.finish!.family, error.finish!.ended, error.finish!.finishRaw, true)).toBe(expected);
  });

  it('gemini_blocked_carries_finish', async () => {
    const events = await run('gemini', sse([
      [null, geminiText],
      [null, { candidates: [{ finishReason: 'SAFETY' }] }],
    ]));
    const error = errorEvent(events);
    expect(error.finish).toEqual({ family: 'gemini', ended: 'clean', finishRaw: 'SAFETY' });
    expect(StopReasonResolver.resolve(error.finish!.family, error.finish!.ended, error.finish!.finishRaw, true)).toBe('content_filter');
  });

  it('gemini_prompt_block_carries_finish', async () => {
    const events = await run('gemini', sse([[null, { promptFeedback: { blockReason: 'SAFETY' } }]]));
    const error = errorEvent(events);
    expect(error.finish).toEqual({ family: 'gemini', ended: 'clean', finishRaw: 'blockReason:SAFETY' });
    expect(StopReasonResolver.resolve(error.finish!.family, error.finish!.ended, error.finish!.finishRaw, false)).toBe('content_filter');
  });

  async function llamaEvents(body: string, relayStream = true): Promise<StreamEvent[]> {
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async () => new Response(body, {
          status: 200,
          headers: { 'Content-Type': relayStream ? 'text/event-stream' : 'application/json' },
        }),
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    };
    const handle = sendRelayStream('key', 'model-a', [{ role: 'user', content: 'hello' }], 'https://relay.example', {
      relayTransport: 'llamacpp_native',
      relayAuthMode: 'bearer',
      relayStream,
    }, deps);
    const reader = handle.stream.getReader();
    const events: StreamEvent[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) return events;
      events.push(value);
    }
  }

  const llamaDelta: [null, unknown] = [null, { content: 'hi', stop: false }];

  it.each([
    ['eos', 'stop'],
    ['limit', 'length'],
  ] as const)('llama_cpp_stop_type_%s', async (stopType, expected) => {
    const events = await llamaEvents(sse([llamaDelta, [null, { content: '', stop: true, stop_type: stopType }]]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'llama_cpp', ended: 'clean', finishRaw: stopType });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe(expected);
  });

  it('llama_cpp_legacy_stopped_booleans', async () => {
    const events = await llamaEvents(sse([
      llamaDelta,
      [null, { content: '', stop: true, stopped_eos: false, stopped_word: false, stopped_limit: true }],
    ]));
    expect(doneEvent(events).finish).toEqual({ family: 'llama_cpp', ended: 'clean', finishRaw: 'limit' });
  });

  it('llama_cpp_eof_without_stop_chunk', async () => {
    const events = await llamaEvents(sse([llamaDelta]));
    const { finish } = doneEvent(events);
    expect(finish).toEqual({ family: 'llama_cpp', ended: 'eof_without_marker' });
    expect(StopReasonResolver.resolve(finish!.family, finish!.ended, finish!.finishRaw, true)).toBe('incomplete');
  });

  it('llama_cpp_json_carries_stop_type', async () => {
    const events = await llamaEvents(JSON.stringify({ content: 'hi', stop: true, stop_type: 'word' }), false);
    expect(doneEvent(events).finish).toEqual({ family: 'llama_cpp', ended: 'clean', finishRaw: 'word' });
  });
});
