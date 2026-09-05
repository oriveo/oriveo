import { beforeEach, describe, expect, it } from 'vitest';
import { relayEndpointFingerprint, relayUnsupportedParamScope } from './relay-stream';
import {
  relayGenerationEndpointFingerprint,
  sendRelayStream,
  type RelayOrchestratorDeps,
} from './relay-orchestrator';
import type { StreamEvent } from './types';
import { RELAY_REDACTED_PLACEHOLDER } from '@oriveo/shared/relay/endpoint-policy';
import { droppedUnsupportedParams, resetUnsupportedParamCacheForTesting } from './unsupported-param';

beforeEach(() => resetUnsupportedParamCacheForTesting());

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

function relayDeps(response: Response): RelayOrchestratorDeps {
  return {
    transport: { fetch: async () => response },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

describe('relay unsupported-param scope', () => {
  it('ignores query and credentials in the endpoint fingerprint and never leaks the request address in clear text', () => {
    const first = relayEndpointFingerprint('https://user:secret@relay.example/v1/chat/completions?key=secret');
    const second = relayEndpointFingerprint('https://relay.example/v1/chat/completions?other=secret');
    expect(first).toBe(second);
    expect(first).toMatch(/^ep_[0-9a-f]{8}$/);
    expect(first).not.toContain('relay.example');
  });

  it('binds the relay endpoint to the self-healing negative cache scope of the same model', () => {
    const scope = relayUnsupportedParamScope({
      url: 'http://127.0.0.1:8080/v1/chat/completions?debug=1',
      headers: {},
      body: { model: 'local-model' },
    });
    expect(scope.providerKind).toBe('relay');
    expect(scope.modelID).toBe('local-model');
    expect(scope.endpointFingerprint).toMatch(/^ep_[0-9a-f]{8}$/);
    expect(scope.endpointFingerprint).not.toContain('127.0.0.1');
  });

  it('prefers an explicit modelID over the body fallback, covering Gemini and llama request bodies that carry no model', () => {
    expect(relayUnsupportedParamScope({
      url: 'https://relay.example/v1beta/models/gemini-pro:generateContent',
      headers: {},
      body: {},
      modelID: 'gemini-pro',
    }).modelID).toBe('gemini-pro');
  });

  it('does not scan a 400 or retry without the parameter when the local identity is incomplete either', async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const responses = [
      new Response('does not support parameter temperature', { status: 400 }),
      new Response('{"choices":[{"message":{"content":"ok"}}]}', { status: 200 }),
      new Response('{"choices":[{"message":{"content":"ok"}}]}', { status: 200 }),
      new Response('{"choices":[{"message":{"content":"ok"}}]}', { status: 200 }),
    ];
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async (_url, init) => {
          bodies.push(JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>);
          return responses.shift()!;
        },
      },
      // Both public upstreams are rewritten to this one URL in the browser.
      buildFetchArgs: (_upstreamURL, headers) => ({ url: '/api/relay/forward', headers }),
      getRelayRuntimeConfig: () => null,
    };
    const options = {
      relayTransport: 'openai_chat_completions' as const,
      relayAuthMode: 'bearer' as const,
      relayStream: false,
      generationProfile: {
        template: 'openai_chat_completions',
        parameters: [{ id: 'temperature', support: 'supported', source: 'contract' }],
        wire: { temperature: 'temperature' },
      },
      generationParameters: { temperature: { state: 'value' as const, value: 0.4 } },
    };
    const send = async (baseURL: string) => {
      const handle = sendRelayStream(
        'key', 'same-model', [{ role: 'user', content: 'hello' }], baseURL, options, deps,
      );
      await drain(handle.stream);
    };

    await send('https://relay-a.example/v1'); // The first 400 is rethrown verbatim.
    await send('https://relay-a.example/v1'); // The next request still carries the original parameters.
    await send('https://relay-b.example/v1');

    expect(bodies.map((body) => body.temperature)).toEqual([0.4, 0.4, 0.4]);
    expect(responses).toHaveLength(1);
  });

  it('builds no cross-request self-healing cache for a Gemini production request with an incomplete identity', async () => {
    const bodies: Array<Record<string, unknown>> = [];
    let upstreamURL = '';
    const responses = [
      new Response('does not support parameter temperature', { status: 400 }),
      new Response('{}', { status: 200 }),
      new Response('{}', { status: 200 }),
    ];
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async (_url, init) => {
          bodies.push(JSON.parse(String(init?.body ?? '{}')) as Record<string, unknown>);
          return responses.shift()!;
        },
      },
      buildFetchArgs: (url, headers) => {
        upstreamURL = url;
        return { url: '/api/relay/forward', headers };
      },
      getRelayRuntimeConfig: () => null,
    };
    const options = {
      relayTransport: 'gemini_generate_content' as const,
      relayAuthMode: 'x_goog_api_key' as const,
      relayStream: false,
      generationProfile: {
        template: 'gemini_generate_content',
        parameters: [{ id: 'temperature', support: 'supported', source: 'contract' }],
        wire: { temperature: 'temperature' },
      },
      generationParameters: { temperature: { state: 'value' as const, value: 0.4 } },
    };
    const send = async () => {
      const handle = sendRelayStream(
        'key', 'gemini-pro', [{ role: 'user', content: 'hello' }],
        'https://relay.example/prefix', options, deps,
      );
      await drain(handle.stream);
    };

    await send(); // The first 400 is rethrown verbatim.
    await send(); // The next one still carries the original parameters.

    const scope = {
      providerKind: 'relay',
      modelID: 'gemini-pro',
      endpointFingerprint: relayEndpointFingerprint(upstreamURL),
    };
    expect(droppedUnsupportedParams(scope)).toEqual([]);
    expect(bodies.map((body) => body.temperature)).toEqual([0.4, 0.4]);
    expect(responses).toHaveLength(1);
  });

  it('produces a fingerprint identical to the production images endpoint for the image generation panel', async () => {
    let upstreamURL = '';
    const options = {
      relayTransport: 'openai_chat_completions' as const,
      relayAuthMode: 'bearer' as const,
      relayStream: false,
      supportsImageGen: true,
    };
    const deps: RelayOrchestratorDeps = {
      transport: { fetch: async () => new Response('{"data":[]}', { status: 200 }) },
      buildFetchArgs: (url, headers) => {
        upstreamURL = url;
        return { url: '/api/relay/forward', headers };
      },
      getRelayRuntimeConfig: () => null,
    };

    await drain(sendRelayStream(
      'key', 'image-model', [{ role: 'user', content: 'draw a cat' }],
      'https://relay.example/prefix', options, deps,
    ).stream);

    expect(upstreamURL).toBe('https://relay.example/prefix/v1/images/generations');
    expect(relayGenerationEndpointFingerprint(
      'https://relay.example/prefix', 'image-model', options, null,
    )).toBe(relayEndpointFingerprint(upstreamURL));
  });

  it.each([
    [false, 'https://relay.example/prefix/models/gemini-pro:generateContent'],
    [true, 'https://relay.example/prefix/models/gemini-pro:streamGenerateContent?alt=sse'],
  ])('Gemini stream=%s exact base matches the production endpoint', async (relayStream, expectedURL) => {
    let upstreamURL = '';
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async () => relayStream
          ? new Response('data: [DONE]\n\n', { status: 200, headers: { 'Content-Type': 'text/event-stream' } })
          : new Response('{}', { status: 200 }),
      },
      buildFetchArgs: (url, headers) => {
        upstreamURL = url;
        return { url, headers };
      },
      getRelayRuntimeConfig: () => null,
    };
    const options = {
      relayTransport: 'gemini_generate_content' as const,
      relayAuthMode: 'x_goog_api_key' as const,
      relayResolvedAPIBaseURLIsExact: true,
      relayStream,
    };

    await drain(sendRelayStream(
      'key', 'gemini-pro', [{ role: 'user', content: 'hello' }],
      'https://relay.example/prefix', options, deps,
    ).stream);

    expect(upstreamURL).toBe(expectedURL);
    expect(relayGenerationEndpointFingerprint(
      'https://relay.example/prefix', 'gemini-pro', options, null,
    )).toBe(relayEndpointFingerprint(expectedURL));
  });
});

describe('relay production error credential redaction', () => {
  it('masks the short key, sensitive headers and query values of the request in a real JSON chat exchange', async () => {
    const response = new Response(JSON.stringify({
      error: { message: 'upstream echoed key=key header=hdr query=qry' },
    }), { status: 401 });
    const handle = sendRelayStream(
      'key',
      'model-a',
      [{ role: 'user', content: 'hello' }],
      'https://relay.example/v1',
      {
        relayTransport: 'openai_chat_completions',
        relayAuthMode: 'bearer',
        relayStream: false,
        relayHeaders: [{ key: 'Authorization', value: 'hdr' }],
        relayQueryParams: [{ key: 'api_key', value: 'qry' }],
      },
      relayDeps(response),
    );

    const error = (await drain(handle.stream)).find((event) => event.type === 'error');
    expect(error?.type).toBe('error');
    if (error?.type !== 'error') throw new Error('expected production relay JSON error');
    expect(error.error).toContain(RELAY_REDACTED_PLACEHOLDER);
    expect(error.error).not.toContain('key');
    expect(error.error).not.toContain('hdr');
    expect(error.error).not.toContain('qry');
  });

  it('masks the credentials of the current request inside a real Gemini SSE error too', async () => {
    const response = new Response(
      'data: {"error":{"message":"upstream echoed key hdr qry"}}\n\ndata: [DONE]\n\n',
      { status: 200, headers: { 'Content-Type': 'text/event-stream' } },
    );
    const handle = sendRelayStream(
      'key',
      'model-a',
      [{ role: 'user', content: 'hello' }],
      'https://relay.example/v1',
      {
        relayTransport: 'gemini_generate_content',
        relayAuthMode: 'bearer',
        relayStream: true,
        relayHeaders: [{ key: 'x-api-key', value: 'hdr' }],
        relayQueryParams: [{ key: 'token', value: 'qry' }],
      },
      relayDeps(response),
    );

    const error = (await drain(handle.stream)).find((event) => event.type === 'error');
    expect(error?.type).toBe('error');
    if (error?.type !== 'error') throw new Error('expected production relay SSE error');
    expect(error.error).toBe(`upstream echoed ${RELAY_REDACTED_PLACEHOLDER} ${RELAY_REDACTED_PLACEHOLDER} ${RELAY_REDACTED_PLACEHOLDER}`);
  });

  it('does not over-replace matching body text with auth=none, where no key, header or query was actually sent', async () => {
    const message = 'ordinary key hdr qry text';
    const response = new Response(JSON.stringify({ error: { message } }), { status: 400 });
    const handle = sendRelayStream(
      'key',
      'model-a',
      [{ role: 'user', content: 'hello' }],
      'https://relay.example/v1',
      {
        relayTransport: 'openai_chat_completions',
        relayAuthMode: 'none',
        relayStream: false,
        relayHeaders: [{ key: 'Authorization', value: 'hdr' }],
        relayQueryParams: [{ key: 'token', value: 'qry' }],
      },
      relayDeps(response),
    );

    const error = (await drain(handle.stream)).find((event) => event.type === 'error');
    expect(error?.type).toBe('error');
    if (error?.type !== 'error') throw new Error('expected production relay JSON error');
    expect(error.error).toContain(message);
    expect(error.error).not.toContain(RELAY_REDACTED_PLACEHOLDER);
  });
});
