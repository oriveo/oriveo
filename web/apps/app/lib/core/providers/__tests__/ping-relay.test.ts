import { afterEach, describe, expect, it, vi } from 'vitest';

import {
  buildRelayPingRequest,
  extractPingErrorMessage,
  extractRelayPingFailureDetails,
  pingRelay,
} from '../ping-relay';

afterEach(() => {
  vi.restoreAllMocks();
});

describe('buildRelayPingRequest', () => {
  it('uses POST /responses for Codex style / OpenAI Responses ping', () => {
    const req = buildRelayPingRequest({
      baseURL: 'https://codex-relay.example.com/codex/v1/',
      apiKey: 'sk-test',
      modelID: 'gpt-5.4',
      relayRequested: {
        transport: 'openai_responses',
        authMode: 'bearer',
        disableResponseStorage: true,
        codexCompatIdentity: true,
      },
    });

    expect(req.method).toBe('POST');
    expect(req.upstreamURL).toBe('https://codex-relay.example.com/codex/v1/responses');
    expect(req.body).toMatchObject({
      model: 'gpt-5.4',
      max_output_tokens: 1,
      store: false,
    });
    expect(req.directConfig).toMatchObject({
      transport: 'openai_responses',
      authMode: 'bearer',
      apiKey: 'sk-test',
      codexCompatIdentity: true,
    });
    // Label for the ping path, which is shown to the user in the success message.
    expect(req.probedEndpoint).toBe('POST /responses');
    expect(req.parseModelCatalog).toBeUndefined();
  });

  it('uses POST /chat/completions for OpenAI compatible ping when a model is provided', () => {
    const req = buildRelayPingRequest({
      baseURL: 'relay.example.com/v1',
      apiKey: 'sk-test',
      modelID: 'gpt-4o',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
      },
    });

    expect(req.method).toBe('POST');
    expect(req.upstreamURL).toBe('https://relay.example.com/v1/chat/completions');
    expect(req.body).toEqual({
      model: 'gpt-4o',
      stream: false,
      max_tokens: 1,
      messages: [{ role: 'user', content: 'ping' }],
    });
    expect(req.probedEndpoint).toBe('POST /chat/completions');
    expect(req.parseModelCatalog).toBeUndefined();
  });

  it('uses a 1-token generation request when no saved model is available', () => {
    const req = buildRelayPingRequest({
      baseURL: 'relay.example.com/v1',
      apiKey: 'sk-test',
      modelID: '',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
      },
    });

    expect(req.method).toBe('POST');
    expect(req.upstreamURL).toBe('https://relay.example.com/v1/chat/completions');
    expect(req.body).toMatchObject({ model: 'gpt-4o', max_tokens: 1, stream: false });
    expect(req.probedEndpoint).toBe('POST /chat/completions');
  });

  it('uses POST /messages for Anthropic compatible ping with x-api-key auth', () => {
    const req = buildRelayPingRequest({
      baseURL: 'https://claude-relay.example.com/v1',
      apiKey: 'sk-ant',
      modelID: 'claude-3-5-sonnet',
      relayRequested: {
        transport: 'anthropic_messages',
        authMode: 'x_api_key',
      },
    });

    expect(req.method).toBe('POST');
    expect(req.upstreamURL).toBe('https://claude-relay.example.com/v1/messages');
    expect(req.body).toEqual({
      model: 'claude-3-5-sonnet',
      max_tokens: 1,
      messages: [{ role: 'user', content: 'ping' }],
    });
  });

  it('adds /v1 for Anthropic origin base URLs without duplicating existing version paths', () => {
    const fromOrigin = buildRelayPingRequest({
      baseURL: 'https://api.anthropic.com',
      apiKey: 'sk-ant',
      modelID: 'claude-3-5-sonnet',
      relayRequested: {
        transport: 'anthropic_messages',
        authMode: 'x_api_key',
      },
    });
    const fromVersioned = buildRelayPingRequest({
      baseURL: 'https://api.anthropic.com/v1/',
      apiKey: 'sk-ant',
      modelID: 'claude-3-5-sonnet',
      relayRequested: {
        transport: 'anthropic_messages',
        authMode: 'x_api_key',
      },
    });

    expect(fromOrigin.upstreamURL).toBe('https://api.anthropic.com/v1/messages');
    expect(fromVersioned.upstreamURL).toBe('https://api.anthropic.com/v1/messages');
  });

  it('uses Gemini generateContent path and keeps key as x-goog-api-key proxy config', () => {
    const req = buildRelayPingRequest({
      baseURL: 'https://generativelanguage.googleapis.com',
      apiKey: 'g-key',
      modelID: 'gemini-2.5-pro',
      relayRequested: {
        transport: 'gemini_generate_content',
        authMode: 'x_goog_api_key',
      },
    });

    expect(req.method).toBe('POST');
    expect(req.upstreamURL).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent');
    expect(req.directConfig.authMode).toBe('x_goog_api_key');
    expect(req.directConfig.apiKey).toBe('g-key');
    expect(req.body).toEqual({
      contents: [{ role: 'user', parts: [{ text: 'ping' }] }],
      generationConfig: { maxOutputTokens: 1 },
    });
  });
});

describe('extractPingErrorMessage', () => {
  // Regression: "test connection" on the detail page showed [object Object] whenever a relay
  // answered with a 4xx, because pingRelay throws a ProviderError plain object while the detail
  // page fell back to String(error).
  it('returns the message field of a ProviderError plain object instead of "[object Object]"', () => {
    const err = { kind: 'badRequest', title: 'Bad Request', message: 'Model gpt-5.5 not found.' };
    expect(extractPingErrorMessage(err)).toBe('Model gpt-5.5 not found.');
  });

  it('falls back to title then detail when message is missing', () => {
    expect(extractPingErrorMessage({ kind: 'invalidKey', title: 'Invalid Key' })).toBe('Invalid Key');
    expect(extractPingErrorMessage({ kind: 'unavailable', detail: 'route disabled' })).toBe('route disabled');
  });

  it('uses Error.message for native Error instances', () => {
    expect(extractPingErrorMessage(new Error('Failed to fetch'))).toBe('Failed to fetch');
  });

  it('falls back to String(error) for unknown shapes', () => {
    expect(extractPingErrorMessage(42)).toBe('42');
  });

  it('localizes ProviderError messages when a translator is provided', () => {
    const err = {
      kind: 'invalidKey',
      title: 'Invalid API Key',
      message: 'The API key you entered is invalid or has been revoked. Please check your key and try again.',
    };
    expect(extractPingErrorMessage(err, (key) => `[translated:${key}]`)).toBe('[translated:invalidKey.message]');
  });
});

describe('pingRelay secure browser boundary', () => {
  const input = {
    baseURL: 'https://relay.local:8443/v1',
    apiKey: 'sk-test',
    modelID: 'gpt-4o',
    relayRequested: {
      transport: 'openai_chat_completions' as const,
      authMode: 'bearer' as const,
    },
  };

  it('connects directly with credentials omitted', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ choices: [] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(pingRelay(input)).resolves.toMatchObject({
      probedEndpoint: 'POST /chat/completions',
    });
    expect(fetchMock).toHaveBeenCalledWith(
      'https://relay.local:8443/v1/chat/completions',
      expect.objectContaining({
        method: 'POST',
        credentials: 'omit',
        headers: expect.objectContaining({ Authorization: 'Bearer sk-test' }),
      }),
    );
    expect(fetchMock).not.toHaveBeenCalledWith('/api/relay/forward', expect.anything());
  });

  it('accepts an SSE success response from a relay that ignores stream=false', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('data: {"choices":[]}\n\ndata: [DONE]\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      }),
    );

    await expect(pingRelay(input)).resolves.toMatchObject({
      probedEndpoint: 'POST /chat/completions',
    });
  });

  it('rejects a 2xx HTML fallback page instead of marking the relay connected', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response('<!doctype html><html>relay console</html>', {
        status: 200,
        headers: { 'Content-Type': 'text/html' },
      }),
    );

    await expect(pingRelay(input)).rejects.toMatchObject({
      kind: 'upstream',
      status: 200,
    });
  });

  it('builds failure-card details from the production ping error without exposing credentials or prompt text', async () => {
    const apiKey = 'sk-production-secret';
    const headerSecret = 'tenant-header-secret';
    const querySecret = 'query-secret';
    const privatePrompt = 'private prompt must not render';
    const securedInput = {
      ...input,
      apiKey,
      relayRequested: {
        ...input.relayRequested,
        headers: [{ key: 'X-Session-Token', value: headerSecret }],
        queryParams: [{ key: 'api_key', value: querySecret }],
      },
    };
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      error: { message: `invalid ${apiKey} ${headerSecret} ${querySecret}; prompt=${privatePrompt}` },
    }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));

    let productionError: unknown;
    try {
      await pingRelay(securedInput);
    } catch (error) {
      productionError = error;
    }
    const details = extractRelayPingFailureDetails(productionError, securedInput);
    const rendered = JSON.stringify({ productionError, details });
    expect(details).toMatchObject({ statusCode: 401, requestURL: 'https://relay.local:8443/v1/chat/completions' });
    expect(rendered).not.toContain(apiKey);
    expect(rendered).not.toContain(headerSecret);
    expect(rendered).not.toContain(querySecret);
    expect(rendered).not.toContain(privatePrompt);
    expect(details.upstreamMessage).toContain('***hidden');
  });

  it('rejects HTTP before fetch', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch');
    await expect(pingRelay({ ...input, baseURL: 'http://relay.local:8080/v1' }))
      .rejects.toThrow('Use an HTTPS endpoint');
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
