import { beforeEach, describe, expect, it, vi } from 'vitest';
import { sendLibraryAgentLeg, sendStreamProxy } from '../proxy-client';
import type { StreamEvent } from '../types';
import * as metadataClient from '../../metadata/metadata-client';
import {
  __resetMetadataClientForTest,
  initMetadata,
} from '../../metadata/metadata-client';

const { mockBuildFreeRequestHeaders, mockResolveFreeBackendURL } = vi.hoisted(() => ({
  mockBuildFreeRequestHeaders: vi.fn(),
  mockResolveFreeBackendURL: vi.fn(),
}));

vi.mock('../../free/api', () => ({
  buildFreeRequestHeaders: (...args: unknown[]) => mockBuildFreeRequestHeaders(...args),
  resolveFreeBackendURL: (...args: unknown[]) => mockResolveFreeBackendURL(...args),
}));

async function collectEvents(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const reader = stream.getReader();
  const events: StreamEvent[] = [];

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }

  return events;
}

describe('proxy-client', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    localStorage.clear();
    __resetMetadataClientForTest();
    mockBuildFreeRequestHeaders.mockReset();
    mockResolveFreeBackendURL.mockReset();
    mockBuildFreeRequestHeaders.mockResolvedValue({
      'Content-Type': 'application/json',
      'X-Oriveo-Free-Session': 'guest-session-token',
    });
    mockResolveFreeBackendURL.mockReturnValue('https://api.test.com');
  });

  describe('Grok subscription outbound', () => {
    it('declares authMode only at the top level of the request body and keeps the local marker out of the options passed to the builder', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response('data: [DONE]\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }),
      );

      const { stream } = sendStreamProxy(
        'grok',
        'access-token',
        'grok-4.6',
        [{ role: 'user', content: 'hi' }],
        undefined,
        { grokSubscriptionAuth: true },
      );
      await collectEvents(stream);

      const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(String(init.body)) as Record<string, unknown>;
      expect(body.authMode).toBe('subscription');
      expect(body.apiKey).toBe('access-token');
      expect((body.options as Record<string, unknown> | undefined)?.grokSubscriptionAuth)
        .toBeUndefined();
    });

    it('sends the subscription identity on the library model leg too, without falling back to API key routing', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response('data: [DONE]\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }),
      );

      const { stream } = sendLibraryAgentLeg(
        'grok',
        'subscription-access-token',
        'grok-4.6',
        [{ role: 'user', content: 'search my library' }],
        [],
        undefined,
        { grokSubscriptionAuth: true },
        'none',
      );
      await collectEvents(stream);

      const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(String(init.body)) as Record<string, unknown>;
      expect(body).toMatchObject({
        providerKind: 'grok',
        apiKey: 'subscription-access-token',
        authMode: 'subscription',
      });
      expect((body.options as Record<string, unknown> | undefined)?.grokSubscriptionAuth)
        .toBeUndefined();
    });

    it('classifies a 403 in subscription mode as an unsupported subscription tier, not an invalid key', async () => {
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response('{"error":"Forbidden"}', {
          status: 403,
          headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
        }),
      );

      const { stream } = sendStreamProxy(
        'grok',
        'access-token',
        'grok-4.6',
        [{ role: 'user', content: 'hi' }],
        undefined,
        { grokSubscriptionAuth: true },
      );
      const events = await collectEvents(stream);
      const error = events.find((event) => event.type === 'error');
      expect(error?.errorKind).toBe('grokSubscriptionIneligible');
    });

    it('forces one metadata refresh on 426, since the snapshot TTL is 24h and a config change would otherwise take a day to take effect', async () => {
      const refreshSpy = vi.spyOn(metadataClient, 'refreshMetadata').mockResolvedValue(undefined);
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response('{"error":"client version too old"}', {
          status: 426,
          headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
        }),
      );

      const { stream } = sendStreamProxy(
        'grok',
        'access-token',
        'grok-4.6',
        [{ role: 'user', content: 'hi' }],
        undefined,
        { grokSubscriptionAuth: true },
      );
      const events = await collectEvents(stream);

      expect(events.find((event) => event.type === 'error')?.errorKind)
        .toBe('grokSubscriptionUnavailable');
      expect(refreshSpy).toHaveBeenCalledTimes(1);
    });

    it('leaves 403 handling in API key mode exactly as it was', async () => {
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(
        new Response('{"error":"Forbidden"}', {
          status: 403,
          headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'provider' },
        }),
      );

      const { stream } = sendStreamProxy(
        'grok',
        'xai-key',
        'grok-4.3',
        [{ role: 'user', content: 'hi' }],
      );
      const events = await collectEvents(stream);
      const error = events.find((event) => event.type === 'error');
      expect(error?.errorKind).toBe('invalidKey');
    });
  });

  it('parses text, images and usage from an OpenAI Responses SSE stream', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'event: response.output_text.delta',
        'data: {"delta":"Hello"}',
        '',
        'event: response.output_image.done',
        'data: {"result":"aGVsbG8="}',
        '',
        'event: response.completed',
        'data: {"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":4}}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      'https://api.openai.com/v1',
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'delta', content: 'Hello' },
      { type: 'image', url: 'data:image/png;base64,aGVsbG8=' },
      {
        type: 'usage',
        usage: {
          prompt_tokens: 3,
          completion_tokens: 4,
          total_tokens: 7,
          breakdown: {
            promptTokens: 3,
            cachedInputTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            cacheReadObserved: false,
            completionTokens: 4,
            reasoningTokens: 0,
          },
        },
      },
      { type: 'done' },
    ]);
  });

  it('uses only server-selected continuation headers to capture a completed Responses id', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response([
      'event: response.completed',
      'data: {"type":"response.completed","response":{"id":"resp_exact","status":"completed"}}',
      '',
      'data: [DONE]',
      '',
    ].join('\n'), { status: 200, headers: {
      'Content-Type': 'text/event-stream',
      'X-Oriveo-Continuation-Kind': 'previous_id',
      'X-Oriveo-Continuation-Protocol': 'openai_responses',
      'X-Oriveo-Continuation-Parser': 'openai_responses_reasoning_v1',
    } }));
    const { stream } = sendStreamProxy('openAI', 'sk_test', 'gpt-5', [{ role: 'user', content: 'hello' }]);
    await expect(collectEvents(stream)).resolves.toContainEqual({
      type: 'continuation', continuation: { kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_exact' } },
    });
  });

  it('parses a real non-streaming JSON completion through the same StreamEvent pipeline', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      choices: [{ message: { content: 'non-stream answer' } }],
      usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 },
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    const { stream } = sendStreamProxy('openAI', 'sk_test', 'gpt-5', [{ role: 'user', content: 'hello' }], 'https://api.openai.com/v1', { continuation: undefined });
    await expect(collectEvents(stream)).resolves.toEqual(expect.arrayContaining([
      { type: 'delta', content: 'non-stream answer' },
      expect.objectContaining({ type: 'usage', usage: expect.objectContaining({ total_tokens: 5 }) }),
      { type: 'done' },
    ]));
  });

  it('dispatches a parameter hint to the UI when the proxy reports a successful self-heal', async () => {
    const notice = vi.fn();
    window.addEventListener('oriveo:unsupported-param-self-healed', notice);
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      'data: [DONE]\n\n',
      {
        status: 200,
        headers: {
          'Content-Type': 'text/event-stream',
          'X-Oriveo-Self-Heal-Param': 'reasoning_effort',
        },
      },
    ));

    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      'https://api.openai.com/v1',
    );

    await collectEvents(stream);
    expect(notice).toHaveBeenCalledTimes(1);
    expect((notice.mock.calls[0]?.[0] as CustomEvent<{ param: string }>).detail.param)
      .toBe('reasoning_effort');
    window.removeEventListener('oriveo:unsupported-param-self-healed', notice);
  });

  it('keeps diagnostic sidecar fields out of the chat stream body', async () => {
    const calls: Array<{ url: string; init?: RequestInit }> = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      calls.push({ url, init });
      if (url === '/api/chat/stream') {
        return new Response('data: [DONE]\n\n', {
          status: 200,
          headers: {
            'Content-Type': 'text/event-stream',
            'X-Oriveo-Self-Heal-Param': 'reasoning_effort',
          },
        });
      }
      throw new Error(`Unexpected fetch: ${url}`);
    });

    await initMetadata();
    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      'https://api.openai.com/v1',
      { reasoning: 'deep' },
    );

    await expect(collectEvents(stream)).resolves.toEqual([{ type: 'done' }]);

    const chat = calls.find((call) => call.url === '/api/chat/stream');
    const chatBody = JSON.parse(String(chat?.init?.body)) as Record<string, unknown>;
    expect(chatBody).not.toHaveProperty('modelRef');
    expect(chatBody).not.toHaveProperty('model_ref');
    expect(chatBody).not.toHaveProperty('install_nonce');
  });

  it('accumulates url_citation annotations from OpenAI and Grok Responses web search into a citations event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'event: response.output_text.delta',
        'data: {"delta":"References"}',
        '',
        'event: response.output_text.annotation.added',
        'data: {"annotation":{"type":"url_citation","url":"https://example.com/a","title":"Source A","start_index":0,"end_index":4}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    ));

    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      'https://api.openai.com/v1',
    );

    const events = await collectEvents(stream);
    expect(events).toContainEqual({ type: 'delta', content: 'References' });
    const citationsEvent = events.find((e) => e.type === 'citations') as
      | Extract<StreamEvent, { type: 'citations' }>
      | undefined;
    expect(citationsEvent).toBeDefined();
    expect(citationsEvent?.citations[0]).toMatchObject({
      url: 'https://example.com/a',
      title: 'Source A',
    });
  });

  it('turns a Responses stream failure into an error event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'event: response.failed',
        'data: {"error":{"message":"rate limited"}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      'https://api.openai.com/v1',
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'error', error: 'rate limited', errorKind: 'upstream', source: 'provider' },
      { type: 'done' },
    ]);
  });

  it('turns Gemini finishReason=SAFETY into an error event and drops the parts and usage in the same chunk', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hello"}]}}]}',
        '',
        'data: {"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"SAFETY"}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":1,"totalTokenCount":6}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'gemini',
      'AIza_test',
      'gemini-2.5-flash',
      [{ role: 'user', content: 'hello' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'delta', content: 'Hello' },
      {
        type: 'error',
        error: 'Gemini stopped the response (finishReason=SAFETY).',
        errorKind: 'upstream',
        source: 'provider',
      },
      { type: 'done' },
    ]);
  });

  it('turns Gemini promptFeedback.blockReason into an error event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"promptFeedback":{"blockReason":"PROHIBITED_CONTENT"}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'gemini',
      'AIza_test',
      'gemini-2.5-flash',
      [{ role: 'user', content: 'hello' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      {
        type: 'error',
        error: 'Gemini blocked the prompt (blockReason=PROHIBITED_CONTENT).',
        errorKind: 'upstream',
        source: 'provider',
      },
      { type: 'done' },
    ]);
  });

  it('lets a normal Gemini finishReason=STOP complete without false positives', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"candidates":[{"content":{"parts":[{"text":"Hi"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":4,"totalTokenCount":7}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'gemini',
      'AIza_test',
      'gemini-2.5-flash',
      [{ role: 'user', content: 'hello' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'delta', content: 'Hi' },
      {
        type: 'usage',
        usage: {
          prompt_tokens: 3,
          completion_tokens: 4,
          total_tokens: 7,
          breakdown: {
            promptTokens: 3,
            cachedInputTokens: 0,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            cacheReadObserved: false,
            completionTokens: 4,
            reasoningTokens: 0,
          },
        },
      },
      { type: 'done' },
    ]);
  });

  it('turns a top-level Gemini error chunk mid-stream into an error event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"error":{"code":500,"message":"Internal error encountered.","status":"INTERNAL"}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'gemini',
      'AIza_test',
      'gemini-2.5-flash',
      [{ role: 'user', content: 'hello' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'error', error: 'Internal error encountered.', errorKind: 'upstream', source: 'provider' },
      { type: 'done' },
    ]);
  });

  // The MiniMax adapter emits unified reasoning and model events, which parseProxyChunk must recognise.
  it('parses MiniMax unified reasoning and model events', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"type":"reasoning","content":"thinking..."}',
        '',
        'data: {"type":"delta","content":"answer"}',
        '',
        'data: {"type":"model","modelID":"abab6.5s-chat"}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'miniMax',
      'sk_test',
      'abab6.5s-chat',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'reasoning', content: 'thinking...' },
      { type: 'delta', content: 'answer' },
      { type: 'model', modelID: 'abab6.5s-chat' },
      { type: 'done' },
    ]);
  });

  // Anthropic extended thinking sends thinking_delta, which must become a reasoning event.
  it('turns an Anthropic thinking_delta into a reasoning event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'event: content_block_delta',
        'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"let me think"}}',
        '',
        'event: content_block_delta',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"the answer"}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'anthropic',
      'sk_test',
      'claude-opus-4-1',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'reasoning', content: 'let me think' },
      { type: 'delta', content: 'the answer' },
      { type: 'done' },
    ]);
  });

  // Anthropic reports input_tokens in message_start, so merging across chunks must not record 0; message_delta carries the breakdown.
  it('merges Anthropic input_tokens across chunks and reports the cache breakdown', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'event: message_start',
        'data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":0}}}}',
        '',
        'event: content_block_delta',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}',
        '',
        'event: message_delta',
        'data: {"type":"message_delta","usage":{"output_tokens":45}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'anthropic',
      'sk_test',
      'claude-opus-4-1',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'delta', content: 'hello' },
      {
        type: 'usage',
        usage: {
          prompt_tokens: 120,
          completion_tokens: 45,
          total_tokens: 165,
          breakdown: {
            promptTokens: 120,
            cachedInputTokens: 30,
            cacheCreation5mTokens: 10,
            cacheCreation1hTokens: 0,
            cacheReadObserved: true,
            cacheWriteObserved: true,
            completionTokens: 45,
            reasoningTokens: 0,
          },
        },
      },
      { type: 'done' },
    ]);
  });

  // An in-stream Anthropic event:error must pass its message through and not evaporate into a truncated empty response.
  it('turns an in-stream Anthropic event:error into an error event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'event: error',
        'data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'anthropic',
      'sk_test',
      'claude-opus-4-1',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'error', error: 'Overloaded', errorKind: 'upstream', source: 'provider' },
      { type: 'done' },
    ]);
  });

  // Groq, Together and OpenRouter put the reasoning delta in delta.reasoning, without a _content suffix.
  it('turns an OpenAI-compatible delta.reasoning into a reasoning event', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"choices":[{"delta":{"reasoning":"step one"}}]}',
        '',
        'data: {"choices":[{"delta":{"content":"done"}}]}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'groq',
      'sk_test',
      'openai/gpt-oss-120b',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'reasoning', content: 'step one' },
      { type: 'delta', content: 'done' },
      { type: 'done' },
    ]);
  });

  // OpenAI-compatible usage must be turned into a breakdown of the cache discount fields, including Moonshot's top-level cached_tokens.
  it('folds Moonshot top-level cached_tokens into the breakdown', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"choices":[{"delta":{"content":"hi"}}]}',
        '',
        'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"cached_tokens":40}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'moonshot',
      'sk_test',
      'kimi-k2',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'delta', content: 'hi' },
      {
        type: 'usage',
        usage: {
          prompt_tokens: 100,
          completion_tokens: 20,
          total_tokens: 120,
          breakdown: {
            // A top-level cached_tokens=40 is deducted from prompt (the Moonshot-specific field path).
            promptTokens: 60,
            cachedInputTokens: 40,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            cacheReadObserved: true,
            completionTokens: 20,
            reasoningTokens: 0,
          },
        },
      },
      { type: 'done' },
    ]);
  });

  // OpenAI reports it as prompt_tokens_details.cached_tokens.
  it('folds OpenAI prompt_tokens_details.cached_tokens into the breakdown', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      [
        'data: {"choices":[{"delta":{"content":"hi"}}]}',
        '',
        'data: {"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":50,"total_tokens":250,"prompt_tokens_details":{"cached_tokens":80}}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'),
      {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      },
    ));

    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-4o',
      [{ role: 'user', content: 'hi' }],
    );

    await expect(collectEvents(stream)).resolves.toEqual([
      { type: 'delta', content: 'hi' },
      {
        type: 'usage',
        usage: {
          prompt_tokens: 200,
          completion_tokens: 50,
          total_tokens: 250,
          breakdown: {
            promptTokens: 120,
            cachedInputTokens: 80,
            cacheCreation5mTokens: 0,
            cacheCreation1hTokens: 0,
            cacheReadObserved: true,
            completionTokens: 50,
            reasoningTokens: 0,
          },
        },
      },
      { type: 'done' },
    ]);
  });
  // The server route shares one process across users and never learns a negative cache by contract, so the local partition identity has no reason to go out.
  it('does not send the local negative-cache identity to our own server with a proxy request', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      'data: [DONE]\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    ));

    const { stream } = sendStreamProxy(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      'https://api.openai.com/v1',
      {
        reasoning: 'deep',
        capabilityIdentity: {
          partitionId: 'uid-1',
          connectionInstanceId: 'openai-conn-1',
          connectionGeneration: 'gen-1',
          credentialEpoch: 'epoch-1',
          metadataRevision: 'W/"metadata-1"',
          generationRevision: 'W/"generation-1"',
        },
      },
    );
    await collectEvents(stream);

    const raw = String((fetchMock.mock.calls[0]?.[1] as RequestInit).body);
    const sent = JSON.parse(raw) as { options?: Record<string, unknown> };
    expect(sent.options?.reasoning).toBe('deep');
    expect(sent.options).not.toHaveProperty('capabilityIdentity');
    expect(raw).not.toContain('uid-1');
  });

  // The library agentic leg and the main chat use two different outbound points, so stripping must be asserted on each; testing sendStreamProxy alone is not enough.
  it('does not send the local negative-cache identity from the library leg either', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      'data: [DONE]\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    ));

    const { stream } = sendLibraryAgentLeg(
      'openAI',
      'sk_test',
      'gpt-5',
      [{ role: 'user', content: 'hello' }],
      [],
      'https://api.openai.com/v1',
      {
        reasoning: 'deep',
        capabilityIdentity: {
          partitionId: 'uid-1',
          connectionInstanceId: 'openai-conn-1',
          connectionGeneration: 'gen-1',
          credentialEpoch: 'epoch-1',
          metadataRevision: 'W/"metadata-1"',
          generationRevision: 'W/"generation-1"',
        },
      },
    );
    await collectEvents(stream);

    const raw = String((fetchMock.mock.calls[0]?.[1] as RequestInit).body);
    const sent = JSON.parse(raw) as { options?: Record<string, unknown> };
    expect(sent.options?.reasoning).toBe('deep');
    expect(sent.options).not.toHaveProperty('capabilityIdentity');
    expect(raw).not.toContain('uid-1');
  });
  // A custom request field rejected at compile time means the request was never sent. That is neither
  // a network failure nor an upstream rejection, and letting it fall into the 502/network bucket would
  // show "try again later" when a hundred retries give the same result.
  it('maps a fail-closed custom-field 400 to its own kind instead of the network fallback', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      JSON.stringify({
        error: 'customRequestFieldsRejected',
        errorKind: 'customRequestFieldsRejected',
        reason: 'unknown_owned_path',
      }),
      { status: 400, headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'oriveo' } },
    ));

    const handle = sendStreamProxy('openAI', 'sk_test', 'gpt-5', [{ role: 'user', content: 'hello' }]);
    await expect(collectEvents(handle.stream)).resolves.toEqual([{
      type: 'error',
      error: 'unknown_owned_path',
      errorKind: 'customRequestFieldsRejected',
      source: 'oriveo',
    }]);
    // The recovery card offers "retry without the custom fields", which is the only action that can send the message right away.
    expect(handle.getCapabilityCustomRetryEligible()).toBe(true);
  });

  // 400 is shared by a dozen causes, so guessing from the status code alone would report an oversized attachment as a bad custom field.
  it('does not treat a shape-mismatch 400 as a custom-field error', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      JSON.stringify({ error: 'Attachment too large' }),
      { status: 400, headers: { 'Content-Type': 'application/json', 'X-Oriveo-Error-Source': 'oriveo' } },
    ));

    const handle = sendStreamProxy('openAI', 'sk_test', 'gpt-5', [{ role: 'user', content: 'hello' }]);
    const events = await collectEvents(handle.stream);
    expect(events.every((event) => event.type !== 'error' || event.errorKind !== 'customRequestFieldsRejected')).toBe(true);
    expect(handle.getCapabilityCustomRetryEligible()).toBe(false);
  });
});
