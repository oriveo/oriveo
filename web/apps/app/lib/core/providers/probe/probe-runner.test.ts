import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  hasRelayConnectedEvidence,
  probeRelayEndpoint,
  SENTINEL_PROBE_MODEL_ID,
} from './probe-runner';

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

describe('probeRelayEndpoint', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it('uses the production resolver, preserves first catalog order, deduplicates, and verifies the real chat path', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      if (url === 'https://relay.local/v1/models') {
        expect(init?.method).toBe('GET');
        return json({ data: [{ id: 'gpt-b' }, { id: 'gpt-a' }, { id: 'gpt-b' }] });
      }
      if (url === 'https://relay.local/v1/chat/completions') {
        expect(init?.method).toBe('POST');
        expect(JSON.parse(String(init?.body))).toMatchObject({ model: 'gpt-b', max_tokens: 1 });
        return json({ choices: [{ message: { content: 'ok' } }] });
      }
      throw new Error(`unexpected request: ${url}`);
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey: 'sk-relay',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('verified');
    expect(result.detection).toMatchObject({
      transport: 'openai_chat_completions',
      apiBaseURL: 'https://relay.local/v1',
      modelIDs: ['gpt-b', 'gpt-a'],
      generationVerified: true,
    });
    expect(result.detection?.catalogModels.map((model) => model.id)).toEqual(['gpt-b', 'gpt-a']);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('continues after 2xx HTML and accepts the next valid catalog', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url === 'https://relay.local/v1/models') return new Response('<html>app</html>', { status: 200 });
      if (url === 'https://relay.local/v1beta/models') return json({ data: [{ id: 'gpt-ok' }] });
      if (url === 'https://relay.local/v1beta/chat/completions') return json({ choices: [] });
      throw new Error(`unexpected request: ${url}`);
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local',
      apiKey: 'sk-relay',
      forcedTransport: 'openai_chat_completions',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('verified');
    expect(result.detection?.apiBaseURL).toBe('https://relay.local/v1beta');
    expect(result.attempts[0]).toMatchObject({ statusCode: 200, failure: 'invalid_response' });
  });

  it('prioritizes Gemini for an explicit v1beta URL even when the key has no AIza prefix', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(String(input)).toBe('https://relay.local/v1beta/models');
      expect(new Headers(init?.headers).get('x-goog-api-key')).toBe('custom-relay-key');
      expect(new Headers(init?.headers).get('Authorization')).toBeNull();
      return json({ models: [] });
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1beta',
      apiKey: 'custom-relay-key',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('needs_manual_model');
    expect(result.detection?.transport).toBe('gemini_generate_content');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('accepts and deduplicates string entries in a bare catalog array', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('/models')) return json(['model-b', 'model-a', 'model-b']);
      if (url.endsWith('/chat/completions')) return json({ choices: [] });
      throw new Error(`unexpected request: ${url}`);
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey: 'sk-relay',
      forcedTransport: 'openai_chat_completions',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('verified');
    expect(result.detection?.modelIDs).toEqual(['model-b', 'model-a']);
  });

  it('returns the empty-catalog exit without pretending the connection is verified', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(json({ data: [] }));

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey: 'sk-relay',
      retryBackoffMs: [],
    });

    expect(result).toMatchObject({ state: 'needs_manual_model' });
    expect(result.detection).toMatchObject({ generationVerified: false, modelIDs: [] });
  });

  it('falls back to the serial Responses generation probe and treats 400 as protocol evidence', async () => {
    const calls: Array<{ url: string; method?: string; body?: string }> = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      calls.push({ url, method: init?.method, body: String(init?.body ?? '') });
      if (url.endsWith('/models')) return new Response('missing', { status: 404 });
      if (url === 'https://relay.local/codex/v1/responses') {
        return json({ error: { message: 'unknown model' } }, 400);
      }
      return new Response('missing', { status: 404 });
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/codex/v1/responses',
      apiKey: 'sk-relay',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('needs_manual_model');
    expect(result.detection).toMatchObject({
      transport: 'openai_responses',
      apiBaseURL: 'https://relay.local/codex/v1',
      generationVerified: false,
      detectionEvidence: 'generation_probe',
    });
    const probe = calls.find((call) => call.url.endsWith('/responses'));
    expect(probe?.method).toBe('POST');
    expect(JSON.parse(probe?.body ?? '{}').model).toBe(SENTINEL_PROBE_MODEL_ID);
    expect(result.diagnostic).toBe('unknown model');
  });

  it('rejects an HTML fallback page returned with 2xx from a generation route', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('/models')) return new Response('missing', { status: 404 });
      if (url.endsWith('/responses')) {
        return new Response('<!doctype html><html>relay console</html>', {
          status: 200,
          headers: { 'Content-Type': 'text/html' },
        });
      }
      return new Response('missing', { status: 404 });
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/codex/v1/responses',
      apiKey: 'sk-relay',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('failed');
    expect(result.failure).toBe('invalid_response');
    expect(result.attempts.some((attempt) => attempt.failure === 'invalid_response')).toBe(true);
  });

  it.each([
    ['SSE', 'data: {"choices":[]}\n\ndata: [DONE]\n\n', 'text/event-stream'],
    ['opaque non-HTML', 'OK', 'text/plain'],
    ['empty', '', undefined],
  ])('accepts a compatible %s 2xx generation response', async (_name, body, contentType) => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('/models')) return new Response('missing', { status: 404 });
      if (url.endsWith('/responses')) {
        return new Response(body, {
          status: 200,
          headers: contentType ? { 'Content-Type': contentType } : undefined,
        });
      }
      return new Response('missing', { status: 404 });
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/codex/v1/responses',
      apiKey: 'sk-relay',
      modelHint: 'gpt-relay',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('verified');
    expect(result.detection?.generationVerified).toBe(true);
    expect(result.detection?.catalogEvidenceSucceeded).toBe(false);
    expect(hasRelayConnectedEvidence(result.detection)).toBe(true);
  });

  it.each([401, 403, 429, 500])('stops immediately on blocking HTTP %s without rotating protocol', async (status) => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      json({ error: { message: `blocked-${status}` } }, status),
    );

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local',
      apiKey: 'sk-relay',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('failed');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('retries a transient request twice with the contract backoff sequence', async () => {
    const backoffs: number[] = [];
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(json({ data: [] }));

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey: 'sk-relay',
      sleep: async (duration) => { backoffs.push(duration); },
    });

    expect(result.state).toBe('needs_manual_model');
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(backoffs).toEqual([400, 1_200]);
    expect(result.retriedRequestCount).toBe(2);
  });

  it('times out each stalled browser-direct request after 12 seconds', async () => {
    vi.useFakeTimers();
    try {
      vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) => new Promise((_resolve, reject) => {
        init?.signal?.addEventListener('abort', () => {
          reject(new DOMException('aborted', 'AbortError'));
        }, { once: true });
      }));

      const pending = probeRelayEndpoint({
        endpoint: 'https://relay.local/v1',
        apiKey: 'sk-relay',
        retryBackoffMs: [],
      });
      await vi.advanceTimersByTimeAsync(12_000);

      await expect(pending).resolves.toMatchObject({
        state: 'failed',
        failure: 'network',
        retriedRequestCount: 0,
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('retries enumerated transient failures returned by the server proxy', async () => {
    const backoffs: number[] = [];
    const networkFailure = () => new Response(JSON.stringify({
      error: 'socket hang up (ECONNRESET)',
      code: 'relay_upstream_connection_failed',
    }), {
      status: 502,
      headers: { 'X-Oriveo-Error-Source': 'network' },
    });
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(networkFailure())
      .mockResolvedValueOnce(networkFailure())
      .mockResolvedValueOnce(json({ data: [] }));

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.example.com/v1',
      apiKey: 'sk-relay',
      sleep: async (duration) => { backoffs.push(duration); },
    });

    expect(result.state).toBe('needs_manual_model');
    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(backoffs).toEqual([400, 1_200]);
  });

  it('does not retry deterministic TLS failures returned by the server proxy', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      error: 'unable to verify the first certificate (UNABLE_TO_VERIFY_LEAF_SIGNATURE)',
      code: 'relay_upstream_connection_failed',
    }), {
      status: 502,
      headers: { 'X-Oriveo-Error-Source': 'network' },
    }));

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.example.com/v1',
      apiKey: 'sk-relay',
    });

    expect(result).toMatchObject({ state: 'failed', failure: 'network', retriedRequestCount: 0 });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('follows same-origin redirects for browser-direct discovery without dropping auth', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(null, {
        status: 307,
        headers: { Location: '/gateway/v1/models' },
      }))
      .mockResolvedValueOnce(json({ data: [] }));

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey: 'sk-relay',
      forcedTransport: 'openai_chat_completions',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('needs_manual_model');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(String(fetchMock.mock.calls[1][0])).toBe('https://relay.local/gateway/v1/models');
    expect(new Headers(fetchMock.mock.calls[1][1]?.headers).get('Authorization')).toBe('Bearer sk-relay');
  });

  it('never follows a cross-origin browser-direct redirect with Relay credentials', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response(null, {
      status: 302,
      headers: { Location: 'https://attacker.example/models' },
    }));

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey: 'sk-secret',
      forcedTransport: 'openai_chat_completions',
      retryBackoffMs: [],
    });

    expect(result.state).toBe('failed');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('redacts the real key and sensitive custom values from production probe diagnostics', async () => {
    const apiKey = 'current-key-123456';
    const headerSecret = 'header-secret-123456';
    const querySecret = 'query-secret-123456';
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      // First prove these values really reach the production request path, then assert that every
      // diagnostic the failure card receives has been substituted.
      expect(new Headers(init?.headers).get('Authorization')).toBe(`Bearer ${apiKey}`);
      expect(new Headers(init?.headers).get('X-Internal-Token')).toBe(headerSecret);
      expect(new URL(String(input)).searchParams.get('access_token')).toBe(querySecret);
      return json({
        error: { message: `Rejected ${apiKey}; header ${headerSecret}; query ${querySecret}` },
      }, 401);
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1',
      apiKey,
      forcedTransport: 'openai_chat_completions',
      headers: [{ key: 'X-Internal-Token', value: headerSecret }],
      queryParams: [{ key: 'access_token', value: querySecret }],
      retryBackoffMs: [],
    });

    expect(result.state).toBe('failed');
    expect(result.diagnostic).toContain('***hidden');
    expect(result.diagnostic).not.toContain(apiKey);
    expect(result.diagnostic).not.toContain(headerSecret);
    expect(result.diagnostic).not.toContain(querySecret);
  });

  it('rejects embedded query before issuing any request', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch');
    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1?key=secret',
      apiKey: 'sk-relay',
    });
    expect(result.failure).toBe('embedded_query');
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('uses x-goog-api-key instead of putting Gemini credentials in query', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      expect(String(input)).toBe('https://relay.local/v1beta/models');
      expect(String(input)).not.toContain('key=');
      expect(new Headers(init?.headers).get('x-goog-api-key')).toBe('AIza-test');
      return json({ models: [] });
    });

    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1beta',
      apiKey: 'AIza-test',
      forcedTransport: 'gemini_generate_content',
      retryBackoffMs: [],
    });
    expect(result.state).toBe('needs_manual_model');
  });

  it('reconnects a local_http mode through the browser-direct production probe with auth none', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = String(input);
      expect(url.startsWith('/api/relay/forward')).toBe(false);
      expect(new Headers(init?.headers).has('Authorization')).toBe(false);
      if (url === 'http://192.168.1.20:8080/v1/models') {
        return json({ data: [{ id: 'local-model' }] });
      }
      if (url === 'http://192.168.1.20:8080/v1/chat/completions') {
        return json({ choices: [{ message: { content: 'ok' } }] });
      }
      throw new Error(`unexpected request: ${url}`);
    });

    // The assertion reads the detection produced by the production probe rather than a
    // hand-built 'already verified' object that would only exercise the consumer.
    const result = await probeRelayEndpoint({
      endpoint: 'http://192.168.1.20:8080/v1',
      apiKey: '',
      modelHint: 'local-model',
      forcedTransport: 'openai_chat_completions',
      securityMode: 'local_http',
      authMode: 'none',
      retryBackoffMs: [],
    });

    expect(result).toMatchObject({
      state: 'verified',
      detection: {
        authMode: 'none',
        apiBaseURL: 'http://192.168.1.20:8080/v1',
        generationVerified: true,
        modelIDs: ['local-model'],
      },
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe('hasRelayConnectedEvidence', () => {
  it('does not connect without a verified generation', () => {
    expect(hasRelayConnectedEvidence(undefined)).toBe(false);
  });
});
