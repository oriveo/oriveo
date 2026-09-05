import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

// The unsupported-parameter self-heal telemetry fires `void refreshMetadata()` after a retry,
// which makes a real /api/metadata request and shows up as an extra third call in this suite's
// index-based fetchMock assertions. That behaviour has its own coverage in
// lib/core/providers/__tests__/unsupported-param-telemetry.test.ts, and here only the requests
// sent to the relay upstream matter, so the module is mocked out entirely.
vi.mock('../../unsupported-param-telemetry', () => ({
  reportUnsupportedParamDropped: vi.fn(),
}));

import * as relay from '../relay';

/**
 * Simulate a browser environment to cover the header and credential boundary of a browser
 * connecting directly to a relay.
 *
 * This suite runs under jsdom (apps/app/vitest.config.mts `environment: 'jsdom'`), so `window`
 * already exists and a placeholder is installed only when it is missing. A bare `{}` must never
 * be assigned unconditionally: it would also wipe `window.dispatchEvent`, and the
 * unsupported-param self-heal telemetry (unsupported-param-telemetry.ts) only checks
 * `typeof window !== 'undefined'` before calling `dispatchEvent`, so the self-heal retry path
 * would throw a TypeError that the caller catches as a `network` error event. The placeholder is
 * always removed again so a fake window cannot leak into later cases in this file.
 */
function withBrowserWindow(run: () => Promise<void>): Promise<void> {
  const original = Object.getOwnPropertyDescriptor(globalThis, 'window');
  if (!original) {
    Object.defineProperty(globalThis, 'window', {
      value: { dispatchEvent: () => true },
      configurable: true,
      writable: true,
    });
  }
  return run().finally(() => {
    if (original) return;
    // @ts-expect-error remove the window injected by the test
    delete globalThis.window;
  });
}

async function drainStream(
  handle: ReturnType<typeof relay.sendMessageStream>,
): Promise<void> {
  const reader = handle.stream.getReader();
  try {
    // Read only the first event; this test only cares whether fetch hit the intended relay
    await reader.read();
  } finally {
    handle.abort();
    try { reader.releaseLock(); } catch { /* noop */ }
  }
}

/**
 * The real upstream URL after routing: public endpoints go through /api/relay/forward with the
 * upstream address in a header, LAN endpoints are called directly so the request URL is the
 * upstream address. Endpoint path assertions all go through here.
 */
function upstreamURLOf(call: [string, RequestInit]): string {
  const [url, init] = call;
  if (url !== '/api/relay/forward') return url;
  return (init.headers as Record<string, string>)['X-Relay-Upstream-URL'];
}

/** Relay config the proxied request forwards to the server (apiKey, authMode, codex identity, custom headers). */
function proxyConfigOf(call: [string, RequestInit]): {
  transport?: string;
  authMode?: string;
  apiKey?: string;
  codexCompatIdentity?: boolean;
  customUserAgent?: string;
} {
  const init = call[1];
  return JSON.parse((init.headers as Record<string, string>)['X-Relay-Proxy-Config']);
}

async function collectEvents(
  handle: ReturnType<typeof relay.sendMessageStream>,
): Promise<Awaited<ReturnType<ReadableStream<unknown>['getReader']>> extends never ? never : unknown[]> {
  const reader = handle.stream.getReader();
  const events: unknown[] = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      events.push(value);
    }
  } finally {
    handle.abort();
    try { reader.releaseLock(); } catch { /* noop */ }
  }
  return events;
}

describe('Relay adapter - browser routing by address (public endpoints proxied, LAN endpoints direct)', () => {
  let fetchMock: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('rejects stored HTTP endpoints before any browser request', async () => {
    await withBrowserWindow(async () => {
      expect(() => relay.sendMessageStream(
        'sk-test',
        'gpt-4o',
        [{ role: 'user', content: 'hi' }],
        'http://192.168.1.20:8080/v1',
        { relayTransport: 'openai_chat_completions' },
      )).toThrow('Use an HTTPS endpoint');
      expect(fetchMock).not.toHaveBeenCalled();
    });
  });

  // The routing itself: public relay stations do not allow this origin through CORS, so they
  // must be proxied, and LAN endpoints are unreachable from the server, so they must be direct.
  // The test reuses the same isForbiddenIPv4/6 as the server-side SSRF guard, which avoids the
  // dead end of classifying an address as public, proxying it, and getting a 403.
  it.each([
    ['https://192.168.1.20/v1', 'private IPv4'],
    ['https://10.0.0.5/v1', 'private IPv4 in 10/8'],
    ['https://127.0.0.1/v1', 'loopback'],
    ['https://localhost/v1', 'localhost'],
    ['https://nas.local/v1', 'mDNS .local'],
    ['https://ollama/v1', 'bare hostname'],
    ['https://[::1]/v1', 'IPv6 loopback'],
  ])('%s (%s) connects directly from the browser instead of through the server proxy', async (baseURL) => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-4o',
        [{ role: 'user', content: 'hi' }],
        baseURL,
        { relayTransport: 'openai_chat_completions' },
      );
      await drainStream(handle);

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(url).not.toBe('/api/relay/forward');
      expect(url.startsWith(baseURL.replace('/v1', ''))).toBe(true);
      // On a direct connection the auth header goes on the request itself; when proxied it is folded into X-Relay-Proxy-Config
      expect((init.headers as Record<string, string>).Authorization).toBe('Bearer sk-test');
    });
  });

  it('connects directly to a public endpoint on a non-allowlisted SSRF port, since the proxy would 403 anyway and the upstream may allow CORS', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-4o',
        [{ role: 'user', content: 'hi' }],
        'https://relay.example.com:3000/v1',
        { relayTransport: 'openai_chat_completions' },
      );
      await drainStream(handle);

      const [url] = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(url).toBe('https://relay.example.com:3000/v1/chat/completions');
    });
  });

  it('openai_responses transport connects directly and sends no first-party credentials', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'yls-abc',
        'gpt-5',
        [{ role: 'user', content: 'hi' }],
        'https://code.ylsagi.com/codex',
        { relayTransport: 'openai_responses' },
      );
      await drainStream(handle);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      // Public relay station goes through the proxy; the auth and codex identity headers are generated by the forward route on the Node side
      expect(call[0]).toBe('/api/relay/forward');
      expect(upstreamURLOf(call)).toBe('https://code.ylsagi.com/codex/responses');
      const config = proxyConfigOf(call);
      expect(config.transport).toBe('openai_responses');
      expect(config.authMode).toBe('bearer');
      expect(config.apiKey).toBe('yls-abc');
      expect(call[1].credentials).toBe('omit');
    });
  });

  it('anthropic_messages transport passes through the upstream URL and x-api-key', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-ant-test',
        'claude-sonnet-4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'anthropic_messages' },
      );
      await drainStream(handle);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1/messages');
      const config = proxyConfigOf(call);
      expect(config.authMode).toBe('x_api_key');
      expect(config.apiKey).toBe('sk-ant-test');
      expect(call[1].credentials).toBe('omit');
    });
  });

  it('anthropic_messages transport appends /v1 when the base URL has no version path', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-ant-test',
        'claude-sonnet-4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com',
        { relayTransport: 'anthropic_messages' },
      );
      await drainStream(handle);

      expect(upstreamURLOf(fetchMock.mock.calls[0] as [string, RequestInit]))
        .toBe('https://proxy.example.com/v1/messages');
    });
  });

  it('anthropic_messages does not guess /v1 when discovery gave an exact API root', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-ant-test',
        'claude-sonnet-4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/resolved-prefix',
        {
          relayTransport: 'anthropic_messages',
          relayResolvedAPIBaseURLIsExact: true,
        },
      );
      await drainStream(handle);

      expect(upstreamURLOf(fetchMock.mock.calls[0] as [string, RequestInit]))
        .toBe('https://proxy.example.com/resolved-prefix/messages');
    });
  });

  it('gemini_generate_content transport goes through the proxy and passes the x_goog_api_key auth mode through', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'g-test',
        'gemini-2.5-pro',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1beta',
        { relayTransport: 'gemini_generate_content' },
      );
      await drainStream(handle);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse');
      const config = proxyConfigOf(call);
      expect(config.authMode).toBe('x_goog_api_key');
      expect(config.apiKey).toBe('g-test');
    });
  });

  it('gemini_generate_content transport appends /v1beta when the base URL has no version path', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'g-test',
        'gemini-2.5-pro',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com',
        { relayTransport: 'gemini_generate_content' },
      );
      await drainStream(handle);

      expect(upstreamURLOf(fetchMock.mock.calls[0] as [string, RequestInit]))
        .toBe('https://proxy.example.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse');
    });
  });

  it('openai_responses transport uses output_text for assistant history and input_text for user and system', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'yls-key',
        'gpt-5',
        [
          { role: 'system', content: 'be helpful' },
          { role: 'user', content: 'hi' },
          { role: 'assistant', content: 'Hi!' },
          { role: 'user', content: [{ type: 'text', text: 'again' }] },
          { role: 'assistant', content: [{ type: 'text', text: 'sure' }] },
        ],
        'https://code.ylsagi.com/codex',
        { relayTransport: 'openai_responses' },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string);
      expect(body.input[0].content[0].type).toBe('input_text'); // system
      expect(body.input[1].content[0].type).toBe('input_text'); // user string
      expect(body.input[2].content[0].type).toBe('output_text'); // assistant string
      expect(body.input[3].content[0].type).toBe('input_text'); // user parts
      expect(body.input[4].content[0].type).toBe('output_text'); // assistant parts
    });
  });

  it('openai_chat_completions transport connects directly and attaches Authorization', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'yls-xyz',
        'gpt-4o',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'openai_chat_completions' },
      );
      await drainStream(handle);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1/chat/completions');
      const config = proxyConfigOf(call);
      expect(config.authMode).toBe('bearer');
      expect(config.apiKey).toBe('yls-xyz');
    });
  });

  it('openai_chat_completions transport passes xhigh through at reasoning=max instead of downgrading to high', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'yls-xyz',
        'gpt-5.4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'openai_chat_completions',
          reasoning: 'max',
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string);
      expect(body.reasoning_effort).toBe('xhigh');
    });
  });

  it('openai_chat_completions transport makes a non-streaming request at stream=false and parses the final JSON', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            choices: [
              {
                message: {
                  content: 'final answer',
                },
              },
            ],
            usage: {
              prompt_tokens: 3,
              completion_tokens: 4,
              total_tokens: 7,
            },
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      );

      const handle = relay.sendMessageStream(
        'yls-xyz',
        'gpt-5.4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'openai_chat_completions',
          relayStream: false,
        },
      );

      await expect(collectEvents(handle)).resolves.toEqual([
        { type: 'delta', content: 'final answer' },
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

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1/chat/completions');
      const body = JSON.parse(call[1].body as string);
      expect(body.stream).toBe(false);
      expect(body.stream_options).toBeUndefined();
    });
  });

  it('openai_responses transport keeps the original setting and rethrows when xhigh hits a 4xx', async () => {
    await withBrowserWindow(async () => {
      fetchMock
        .mockResolvedValueOnce(
          new Response(
            JSON.stringify({ error: { message: 'unsupported reasoning effort' } }),
            {
              status: 400,
              headers: { 'Content-Type': 'application/json' },
            },
          ),
        );

      const handle = relay.sendMessageStream(
        'yls-xyz',
        'gpt-5.4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'openai_responses',
          reasoning: 'max',
        },
      );

      const events = await collectEvents(handle) as Array<{ type: string }>;
      expect(events.some((event) => event.type === 'error')).toBe(true);
      expect(fetchMock).toHaveBeenCalledTimes(1);
      const firstBody = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
      expect(firstBody.reasoning).toEqual({ effort: 'xhigh', summary: 'auto' });
    });
  });

  it('openai_responses transport parses output[].result images and output_text at stream=false', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            output: [
              {
                type: 'message',
                content: [{ type: 'output_text', text: 'final response' }],
              },
              {
                type: 'image_generation_call',
                result: 'aGVsbG8=',
              },
            ],
            usage: {
              input_tokens: 5,
              output_tokens: 6,
            },
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      );

      const handle = relay.sendMessageStream(
        'yls-xyz',
        'gpt-5.4',
        [{ role: 'user', content: 'draw' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'openai_responses',
          relayStream: false,
          supportsImageGen: true,
        },
      );

      await expect(collectEvents(handle)).resolves.toEqual([
        { type: 'delta', content: 'final response' },
        { type: 'image', url: 'data:image/png;base64,aGVsbG8=' },
        {
          type: 'usage',
          usage: {
            prompt_tokens: 5,
            completion_tokens: 6,
            total_tokens: 11,
            breakdown: {
              promptTokens: 5,
              cachedInputTokens: 0,
              cacheCreation5mTokens: 0,
              cacheCreation1hTokens: 0,
              cacheReadObserved: false,
              completionTokens: 6,
              reasoningTokens: 0,
            },
          },
        },
        { type: 'done' },
      ]);

      const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
      expect(body.stream).toBe(false);
    });
  });

  it('anthropic_messages transport makes a non-streaming request at stream=false and parses the final JSON', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            content: [{ type: 'text', text: 'anthropic final' }],
            usage: {
              input_tokens: 8,
              output_tokens: 9,
            },
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      );

      const handle = relay.sendMessageStream(
        'sk-ant-test',
        'claude-sonnet-4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'anthropic_messages',
          relayStream: false,
        },
      );

      await expect(collectEvents(handle)).resolves.toEqual([
        { type: 'delta', content: 'anthropic final' },
        {
          type: 'usage',
          usage: {
            prompt_tokens: 8,
            completion_tokens: 9,
            total_tokens: 17,
            breakdown: {
              promptTokens: 8,
              cachedInputTokens: 0,
              cacheCreation5mTokens: 0,
              cacheCreation1hTokens: 0,
              cacheReadObserved: false,
              cacheWriteObserved: false,
              completionTokens: 9,
              reasoningTokens: 0,
            },
          },
        },
        { type: 'done' },
      ]);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1/messages');
      const body = JSON.parse(call[1].body as string);
      expect(body.stream).toBe(false);
    });
  });

  it('gemini_generate_content transport switches to generateContent at stream=false and parses the final JSON', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            candidates: [
              {
                content: {
                  parts: [
                    { text: 'gemini final' },
                    { inlineData: { mimeType: 'image/png', data: 'd29ybGQ=' } },
                  ],
                },
              },
            ],
            usageMetadata: {
              promptTokenCount: 4,
              candidatesTokenCount: 5,
              totalTokenCount: 9,
            },
          }),
          {
            status: 200,
            headers: { 'Content-Type': 'application/json' },
          },
        ),
      );

      const handle = relay.sendMessageStream(
        'g-test',
        'gemini-2.5-pro',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1beta',
        {
          relayTransport: 'gemini_generate_content',
          relayStream: false,
        },
      );

      await expect(collectEvents(handle)).resolves.toEqual([
        { type: 'delta', content: 'gemini final' },
        { type: 'image', url: 'data:image/png;base64,d29ybGQ=' },
        {
          type: 'usage',
          usage: {
            prompt_tokens: 4,
            completion_tokens: 5,
            total_tokens: 9,
            breakdown: {
              promptTokens: 4,
              cachedInputTokens: 0,
              cacheCreation5mTokens: 0,
              cacheCreation1hTokens: 0,
              cacheReadObserved: false,
              completionTokens: 5,
              reasoningTokens: 0,
            },
          },
        },
        { type: 'done' },
      ]);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1beta/models/gemini-2.5-pro:generateContent');
      expect(proxyConfigOf(call).apiKey).toBe('g-test');
      const body = JSON.parse(call[1].body as string);
      expect(body.contents).toBeDefined();
    });
  });

  it('gemini_generate_content transport appends /v1beta at stream=false when the base URL has no version path', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(
        new Response(JSON.stringify({ candidates: [] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        }),
      );

      const handle = relay.sendMessageStream(
        'g-test',
        'gemini-2.5-pro',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com',
        {
          relayTransport: 'gemini_generate_content',
          relayStream: false,
        },
      );
      await collectEvents(handle);

      expect(upstreamURLOf(fetchMock.mock.calls[0] as [string, RequestInit]))
        .toBe('https://proxy.example.com/v1beta/models/gemini-2.5-pro:generateContent');
    });
  });

  it('Gemini SSE still delivers, in order, text produced before an upstream error', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(new Response([
        'data: {"candidates":[{"content":{"parts":[{"text":"partial answer"}]}}]}',
        '',
        'data: {"error":{"message":"upstream stream failed"}}',
        '',
        'data: [DONE]',
        '',
      ].join('\n'), {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }));

      const handle = relay.sendMessageStream(
        'g-test',
        'gemini-2.5-pro',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1beta',
        { relayTransport: 'gemini_generate_content' },
      );

      await expect(collectEvents(handle)).resolves.toEqual([
        { type: 'delta', content: 'partial answer' },
        {
          type: 'error',
          error: 'upstream stream failed',
          errorKind: 'upstream',
          source: 'provider',
        },
        { type: 'done' },
      ]);
    });
  });

  it('openai_responses transport adds the image_generation tool by default and lets it coexist with web_search under the default protocol name', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5',
        [{ role: 'user', content: 'hi' }],
        'https://relay.example.com/v1',
        {
          relayTransport: 'openai_responses',
          supportsWebSearch: true,
          relayImageToolModelID: 'gpt-image-2',
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as { tools?: Array<Record<string, unknown>> };
      expect(Array.isArray(body.tools)).toBe(true);
      expect(body.tools).toHaveLength(2);
      // image_generation and web_search are not mutually exclusive and must coexist; the default protocol name is web_search, without _preview
      expect(body.tools).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ type: 'image_generation', model: 'gpt-image-2' }),
          expect.objectContaining({ type: 'web_search' }),
        ]),
      );
    });
  });

  it('openai_responses transport adds only image_generation when supportsWebSearch or a tool model is absent', async () => {
    // The Codex transport always adds the image_generation tool and lets the model decide whether to call it
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5',
        [{ role: 'user', content: 'hi' }],
        'https://relay.example.com/v1',
        {
          relayTransport: 'openai_responses',
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as { tools?: Array<Record<string, unknown>> };
      expect(body.tools).toEqual([{ type: 'image_generation' }]);
    });
  });

  it('openai_responses transport adds image_generation plus web_search without _preview when only supportsWebSearch is true', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5',
        [{ role: 'user', content: 'hi' }],
        'https://relay.example.com/v1',
        {
          relayTransport: 'openai_responses',
          supportsWebSearch: true,
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as { tools?: Array<Record<string, unknown>> };
      // image_generation is always added while web_search is gated on supportsWebSearch; the default protocol name web_search follows the OpenAI recommendation
      expect(body.tools).toEqual([
        { type: 'image_generation' },
        { type: 'web_search' },
      ]);
    });
  });

  it('openai_responses transport with relayWebSearchToolName=web_search_preview uses the legacy protocol name', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5',
        [{ role: 'user', content: 'hi' }],
        'https://relay.example.com/v1',
        {
          relayTransport: 'openai_responses',
          supportsWebSearch: true,
          relayWebSearchToolName: 'web_search_preview',
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as { tools?: Array<Record<string, unknown>> };
      expect(body.tools).toEqual([
        { type: 'image_generation' },
        { type: 'web_search_preview' },
      ]);
    });
  });

  it('openai_responses transport with relayWebSearchToolName=disabled adds no web_search tool even when search is on', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5',
        [{ role: 'user', content: 'hi' }],
        'https://relay.example.com/v1',
        {
          relayTransport: 'openai_responses',
          supportsWebSearch: true,
          relayWebSearchToolName: 'disabled',
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as { tools?: Array<Record<string, unknown>> };
      // image_generation only, with no web_search variant
      expect(body.tools).toEqual([{ type: 'image_generation' }]);
    });
  });

  it('gemini_generate_content transport injects the googleSearch tool when supportsWebSearch is true', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'g-test',
        'gemini-2.5-pro',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1beta',
        {
          relayTransport: 'gemini_generate_content',
          supportsWebSearch: true,
        },
      );
      await drainStream(handle);

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
      const body = JSON.parse(init.body as string) as { tools?: Array<Record<string, unknown>> };
      expect(body.tools).toEqual([{ googleSearch: {} }]);
    });
  });

  it('openai_chat_completions transport does not scan the body or silently retry when an upstream 400 names the rejected parameter', async () => {
    await withBrowserWindow(async () => {
      fetchMock
        .mockResolvedValueOnce(new Response(
          '{"error":{"message":"Unrecognized request argument supplied: reasoning_effort"}}',
          { status: 400 },
        ));

      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-4o',
        [{ role: 'user', content: 'hi' }],
        'https://relay.test/v1',
        {
          relayTransport: 'openai_chat_completions',
          relayReasoningEffort: 'medium',
        },
      );

      const events = await collectEvents(handle) as Array<{ type: string }>;
      expect(events.some((event) => event.type === 'error')).toBe(true);
      expect(fetchMock).toHaveBeenCalledTimes(1);

      const firstBody = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string);
      expect(firstBody.reasoning_effort).toBe('medium');
    });
  });
});

/**
 * imagesEndpoint routing: an image model on the chat_completions or auto transport skips the
 * chat protocol and posts straight to /images/generations.
 */
describe('Relay adapter - imagesEndpoint routing', () => {
  let fetchMock: ReturnType<typeof vi.spyOn>;

  function imagesResponse(body: unknown): Response {
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  beforeEach(() => {
    fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      imagesResponse({ data: [{ b64_json: 'iVBORw0KGgo=' }] }),
    );
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('image model plus chat_completions calls /images/generations and turns b64 into a data URL', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-image-1',
        [{ role: 'user', content: 'draw an orange tabby cat' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'openai_chat_completions', supportsImageGen: true },
      );
      const events = await collectEvents(handle);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1/images/generations');
      const body = JSON.parse(call[1].body as string);
      expect(body.model).toBe('gpt-image-1');
      expect(body.prompt).toBe('draw an orange tabby cat');
      expect(events).toContainEqual({ type: 'image', url: 'data:image/png;base64,iVBORw0KGgo=' });
    });
  });

  it('passes size, quality and n through but skips response_format for gpt-image-* because the upstream returns 400', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-image-1',
        [{ role: 'user', content: 'a red cube' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'openai_chat_completions',
          supportsImageGen: true,
          relayImageSize: '1024x1536',
          relayImageQuality: 'high',
          relayImageCount: 2,
          relayImageResponseFormat: 'b64_json',
        },
      );
      await collectEvents(handle);

      const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
      expect(body.size).toBe('1024x1536');
      expect(body.quality).toBe('high');
      expect(body.n).toBe(2);
      expect(body.response_format).toBeUndefined();
    });
  });

  it('sends response_format only for models that are not dedicated image models', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'dall-e-3',
        [{ role: 'user', content: 'a red cube' }],
        'https://proxy.example.com/v1',
        {
          relayTransport: 'openai_chat_completions',
          supportsImageGen: true,
          relayImageResponseFormat: 'b64_json',
        },
      );
      await collectEvents(handle);

      const body = JSON.parse((fetchMock.mock.calls[0] as [string, RequestInit])[1].body as string);
      expect(body.response_format).toBe('b64_json');
    });
  });

  it('passes a data[].url response through unchanged for the attachment pipeline to download', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValueOnce(
        imagesResponse({ data: [{ url: 'https://cdn.example.com/a.png' }] }),
      );
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-image-1',
        [{ role: 'user', content: 'cat' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'openai_chat_completions', supportsImageGen: true },
      );
      const events = await collectEvents(handle);

      expect(events).toContainEqual({ type: 'image', url: 'https://cdn.example.com/a.png' });
    });
  });

  it('reports an error and sends no request when no prompt is available', async () => {
    await withBrowserWindow(async () => {
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-image-1',
        [{ role: 'assistant', content: 'the previous answer' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'openai_chat_completions', supportsImageGen: true },
      );
      const events = await collectEvents(handle);

      expect(fetchMock).not.toHaveBeenCalled();
      expect(events).toContainEqual(
        expect.objectContaining({ type: 'error', error: 'Image generation requires a text prompt.' }),
      );
    });
  });

  it('image generation on the Responses transport still uses the inline tool rather than the images endpoint', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValue(
        new Response('data: [DONE]\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }),
      );
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5.4-mini',
        [{ role: 'user', content: 'draw an orange tabby cat' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'openai_responses', supportsImageGen: true },
      );
      await drainStream(handle);

      const call = fetchMock.mock.calls[0] as [string, RequestInit];
      expect(upstreamURLOf(call)).toBe('https://proxy.example.com/v1/responses');
      expect(JSON.parse(call[1].body as string).tools).toContainEqual(
        expect.objectContaining({ type: 'image_generation' }),
      );
    });
  });

  it('non-image models use the normal chat protocol and are not hijacked by the image route', async () => {
    await withBrowserWindow(async () => {
      fetchMock.mockResolvedValue(
        new Response('data: [DONE]\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        }),
      );
      const handle = relay.sendMessageStream(
        'sk-test',
        'gpt-5.4',
        [{ role: 'user', content: 'hi' }],
        'https://proxy.example.com/v1',
        { relayTransport: 'openai_chat_completions' },
      );
      await drainStream(handle);

      expect(upstreamURLOf(fetchMock.mock.calls[0] as [string, RequestInit]))
        .toBe('https://proxy.example.com/v1/chat/completions');
    });
  });
});

describe('Relay adapter - Responses image event compatibility', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('turns a partial_image-only stream into a final image attachment at response.completed', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        [
          'event: response.image_generation_call.partial_image',
          'data: {"type":"response.image_generation_call.partial_image","item_id":"ig_123","partial_image_b64":"aGVsbG8="}',
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
      ),
    );

    const handle = relay.sendMessageStream(
      'yls-test',
      'gpt-5.4',
      [{ role: 'user', content: 'draw' }],
      'https://code.ylsagi.com/codex',
      {
        relayTransport: 'openai_responses',
        supportsImageGen: true,
        relayImageToolModelID: 'gpt-image-2',
      },
    );

    await expect(collectEvents(handle)).resolves.toEqual([
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

  it('event: error (moderation_blocked) maps to an error event carrying an i18nKey', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        [
          'event: error',
          'data: {"type":"error","error":{"code":"moderation_blocked","message":"Triggered safety system."}}',
          '',
          'data: [DONE]',
          '',
        ].join('\n'),
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        },
      ),
    );

    const handle = relay.sendMessageStream(
      'yls-test',
      'gpt-5.4',
      [{ role: 'user', content: 'draw mickey' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses', supportsImageGen: true },
    );

    const events = (await collectEvents(handle)) as Array<{
      type: string;
      error?: string;
      errorKind?: string;
      i18nKey?: string;
    }>;
    const errorEvent = events.find((e) => e.type === 'error');
    expect(errorEvent).toBeDefined();
    expect(errorEvent?.errorKind).toBe('moderation');
    expect(errorEvent?.i18nKey).toBe('moderation');
    expect(errorEvent?.error).toMatch(/safety system/i);
  });

  it('event: response.failed triggers the same error mapping', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        [
          'event: response.failed',
          'data: {"type":"response.failed","response":{"error":{"code":"image_generation_user_error","message":"tool failed"}}}',
          '',
          'data: [DONE]',
          '',
        ].join('\n'),
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        },
      ),
    );

    const handle = relay.sendMessageStream(
      'yls-test',
      'gpt-5.4',
      [{ role: 'user', content: 'draw' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses', supportsImageGen: true },
    );

    const events = (await collectEvents(handle)) as Array<{
      type: string;
      errorKind?: string;
      i18nKey?: string;
    }>;
    const errorEvent = events.find((e) => e.type === 'error');
    expect(errorEvent?.errorKind).toBe('imageGenUser');
    expect(errorEvent?.i18nKey).toBe('imageGenUser');
  });

  it('an unknown error code passes the upstream message through with errorKind=upstream', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        [
          'event: error',
          'data: {"type":"error","error":{"code":"some_random_code","message":"upstream raw detail"}}',
          '',
          'data: [DONE]',
          '',
        ].join('\n'),
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        },
      ),
    );

    const handle = relay.sendMessageStream(
      'yls-test',
      'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );

    const events = (await collectEvents(handle)) as Array<{
      type: string;
      error?: string;
      errorKind?: string;
      i18nKey?: string;
    }>;
    const errorEvent = events.find((e) => e.type === 'error');
    expect(errorEvent?.errorKind).toBe('upstream');
    expect(errorEvent?.i18nKey).toBeUndefined();
    expect(errorEvent?.error).toBe('upstream raw detail');
  });

  it('item.content[].result on response.output_item.done is recognized as an image', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        [
          'event: response.output_item.done',
          'data: {"type":"response.output_item.done","item":{"id":"ig_456","type":"image_generation_call","content":[{"type":"output_image","result":"d29ybGQ="}]}}',
          '',
          'data: [DONE]',
          '',
        ].join('\n'),
        {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        },
      ),
    );

    const handle = relay.sendMessageStream(
      'yls-test',
      'gpt-5.4',
      [{ role: 'user', content: 'draw' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );

    await expect(collectEvents(handle)).resolves.toEqual([
      { type: 'image', url: 'data:image/png;base64,d29ybGQ=' },
      { type: 'done' },
    ]);
  });
});

describe('Relay adapter — model-control rejection is never silently retried (Codex / Responses)', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  function okSSEResponse(content = 'data: [DONE]\n\n'): Response {
    return new Response(content, {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    });
  }

  function jsonErrorResponse(status: number, payload: Record<string, unknown>): Response {
    return new Response(JSON.stringify({ error: payload }), {
      status,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  it('HTTP 4xx with an image_generation tool-unsupported signal keeps the original tools and rethrows', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(jsonErrorResponse(400, {
        code: 'unknown_parameter',
        message: 'Unknown parameter: \'tools[0].type\' (image_generation).',
        param: 'tools[0].type',
      }))
      .mockResolvedValueOnce(okSSEResponse());

    const handle = relay.sendMessageStream(
      'yls-test',
      'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    await drainStream(handle);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const firstBody = JSON.parse((fetchMock.mock.calls[0][1] as RequestInit).body as string) as { tools?: unknown };
    expect(firstBody.tools).toBeDefined();
  });

  it('HTTP 4xx with an image_generation tool_not_supported code is not retried automatically', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(jsonErrorResponse(400, {
        code: 'tool_not_supported',
        message: 'Tool not supported by this upstream.',
      }))
      .mockResolvedValueOnce(okSSEResponse());

    const handle = relay.sendMessageStream(
      'yls-test', 'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    await drainStream(handle);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('HTTP 400 with a Packy image endpoint model mismatch is not retried automatically', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(jsonErrorResponse(400, {
        message: 'unsupported model: gpt-5.5 (only gpt-image-2 is supported on this endpoint)',
      }))
      .mockResolvedValueOnce(okSSEResponse());

    const handle = relay.sendMessageStream(
      'packy-test', 'gpt-5.5',
      [{ role: 'user', content: 'hi' }],
      'https://www.packyapi.com/v1',
      { relayTransport: 'openai_responses' },
    );
    await drainStream(handle);

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('HTTP 4xx with an unrelated error such as model_not_found is not retried and passes the error through', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(jsonErrorResponse(404, {
        code: 'model_not_found',
        message: 'The model `gpt-9` does not exist.',
      }));

    const handle = relay.sendMessageStream(
      'yls-test', 'gpt-9',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    const events = (await collectEvents(handle)) as Array<{ type: string }>;
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(events.some((e) => e.type === 'error')).toBe(true);
  });

  it('HTTP 4xx with a vision error (image_url schema mismatch) does not trigger a retry', async () => {
    // Key counter-example: the error names only "image_url" and not "image_generation", so the tightened rule must not fire
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(jsonErrorResponse(400, {
        message: 'Invalid image_url field for this model.',
      }));

    const handle = relay.sendMessageStream(
      'yls-test', 'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    await collectEvents(handle);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('an image_generation error inside an SSE stream (HTTP 200) before any token is emitted rethrows without retrying', async () => {
    const streamErrorBody = [
      'event: response.failed',
      'data: {"type":"response.failed","response":{"error":{"code":"unknown_parameter","message":"image_generation tool not supported","param":"tools[0]"}}}',
      '',
      'data: [DONE]',
      '',
    ].join('\n');

    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(streamErrorBody, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }))
      .mockResolvedValueOnce(okSSEResponse('event: response.output_text.delta\ndata: {"delta":"hi"}\n\ndata: [DONE]\n\n'));

    const handle = relay.sendMessageStream(
      'yls-test', 'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    const events = (await collectEvents(handle)) as Array<{ type: string; content?: string }>;

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(events.some((e) => e.type === 'error')).toBe(true);
  });

  it('an image_generation error inside an SSE stream after a delta was emitted locks out retry and surfaces the error', async () => {
    // The stream emits a delta first and then the image_generation error: firstContentEmitted is true, so no retry
    const body = [
      'event: response.output_text.delta',
      'data: {"delta":"partial"}',
      '',
      'event: response.failed',
      'data: {"type":"response.failed","response":{"error":{"code":"unknown_parameter","message":"image_generation","param":"tools[0]"}}}',
      '',
      'data: [DONE]',
      '',
    ].join('\n');

    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(body, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }));

    const handle = relay.sendMessageStream(
      'yls-test', 'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    const events = (await collectEvents(handle)) as Array<{ type: string; content?: string }>;

    expect(fetchMock).toHaveBeenCalledTimes(1); // no retry
    expect(events.some((e) => e.type === 'delta' && e.content === 'partial')).toBe(true);
    expect(events.some((e) => e.type === 'error')).toBe(true); // the error is surfaced
  });

  it('the first 4xx surfaces immediately without consuming the prepared second response', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(jsonErrorResponse(400, {
        code: 'unknown_parameter',
        message: 'image_generation not supported',
        param: 'tools[0]',
      }))
      .mockResolvedValueOnce(jsonErrorResponse(400, {
        code: 'invalid_request',
        message: 'still broken',
      }));

    const handle = relay.sendMessageStream(
      'yls-test', 'gpt-5.4',
      [{ role: 'user', content: 'hi' }],
      'https://code.ylsagi.com/codex',
      { relayTransport: 'openai_responses' },
    );
    const events = (await collectEvents(handle)) as Array<{ type: string }>;

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(events.some((e) => e.type === 'error')).toBe(true);
  });
});
