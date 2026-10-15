import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayRequestedConfig } from '@oriveo/shared';

import { buildRelayChatRequest } from '../adapters/relay';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import {
  buildRelayPingRequest,
  extractPingErrorMessage,
  extractRelayPingFailureDetails,
  pingRelay,
} from '../ping-relay';

afterEach(() => {
  vi.restoreAllMocks();
});

/** A public address goes through the reverse proxy in the browser: upstream auth and identity are decided by this config. */
function proxyConfigOf(headers: Record<string, string>): Record<string, unknown> {
  return JSON.parse(headers['X-Relay-Proxy-Config'] ?? '{}') as Record<string, unknown>;
}

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
      max_output_tokens: 16,
      stream: false,
      store: false,
    });
    expect(proxyConfigOf(req.headers)).toMatchObject({
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

  // Without a verification sample no request is sent, and the hard-coded gpt-4o fallback is no longer used.
  it('refuses to build a ping request when no saved model is available', () => {
    expect(() => buildRelayPingRequest({
      baseURL: 'relay.example.com/v1',
      apiKey: 'sk-test',
      modelID: '',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
      },
    })).toThrow(expect.objectContaining({ kind: 'network', detail: 'No model to verify this relay with.' }));
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
      stream: false,
      // Shares the chat request body builder, so the last block carries Relay Anthropic's single cache breakpoint (below the minimum cacheable length, so no cache write happens).
      messages: [{ role: 'user', content: [{ type: 'text', text: 'ping', cache_control: { type: 'ephemeral' } }] }],
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
    expect(proxyConfigOf(req.headers)).toMatchObject({ authMode: 'x_goog_api_key', apiKey: 'g-key' });
    expect(req.body).toEqual({
      contents: [{ role: 'user', parts: [{ text: 'ping' }] }],
      generationConfig: { maxOutputTokens: 1 },
    });
  });
});

/* -- Probe = the chat request turned into a one-sentence conversation -- */

const probeRules = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'probe-orchestration.v1.json');
    if (existsSync(candidate)) {
      return (JSON.parse(readFileSync(candidate, 'utf8')) as {
        probeRequestRules: { responsesMaxOutputTokens: number; otherProtocolsMaxTokens: number };
      }).probeRequestRules;
    }
    dir = path.dirname(dir);
  }
  throw new Error('probe-orchestration.v1.json not found');
})();

type ChatTransport = Exclude<RelayRequestedConfig['transport'], 'auto' | 'llamacpp_native'>;
const CHAT_TRANSPORTS: readonly ChatTransport[] = [
  'openai_chat_completions', 'openai_responses', 'anthropic_messages', 'gemini_generate_content',
];

/** A connection with identity / storage / cache / tier / custom headers all filled in: if any of these keys is missing, the same-shape assertion should go red. */
function shapedRequested(transport: ChatTransport): RelayRequestedConfig {
  return {
    transport,
    authMode: 'auto',
    disableResponseStorage: true,
    codexCompatIdentity: true,
    serviceTier: 'priority',
    reasoningEffort: 'high',
    customUserAgent: 'oriveo-shape-test',
    headers: [{ key: 'X-Tenant', value: 'tenant-a' }],
  };
}

function shapedPair(transport: ChatTransport, baseURL: string) {
  const model: AIModel = {
    id: 'shape-model', name: 'shape-model', capabilities: ['text'],
    reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '',
  };
  const provider: Provider = {
    id: 'relay-shape', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [model],
    apiKey: 'sk-shape', apiKeyPreview: 'sk-...hape', baseURLText: baseURL,
    relayKind: 'openai_compatible', relayRequested: shapedRequested(transport),
  };
  const probe = buildRelayPingRequest({
    baseURL, apiKey: 'sk-shape', modelID: model.id, relayRequested: provider.relayRequested!, relayKind: provider.relayKind,
  });
  // The chat side goes through production option construction and request construction: a plain send with only one user message.
  const chat = buildRelayChatRequest(
    'sk-shape', model.id, [{ role: 'user', content: 'Hello there' }], baseURL,
    buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false), model),
  );
  return { probe, chat, chatBody: JSON.parse(chat.body) as Record<string, unknown> };
}

/** Top-level keys chat has and the probe may lack: conversation content, system prompt, streaming, tools, reasoning, sampling parameters, output limit. */
const CONTENT_AND_GENERATION_KEYS: ReadonlySet<string> = new Set([
  'messages', 'input', 'contents', 'system', 'systemInstruction', 'instructions',
  'stream', 'stream_options',
  'tools', 'tool_choice',
  'reasoning', 'reasoning_effort', 'thinking',
  'temperature', 'top_p', 'top_k', 'seed', 'stop',
  'max_tokens', 'max_output_tokens', 'max_completion_tokens', 'generationConfig',
]);
const OUTPUT_CAP_KEYS: ReadonlySet<string> = new Set(['max_tokens', 'max_output_tokens', 'generationConfig']);

describe('probe and chat have the same shape', () => {
  // A public address goes through the reverse proxy (upstream headers are decided by the proxy config), a LAN address connects directly (request headers are the upstream headers): compare both lines.
  const BASES = [['public reverse proxy', 'https://relay.example.com/v1'], ['LAN direct', 'https://relay.local:8443/v1']] as const;

  for (const transport of CHAT_TRANSPORTS) {
    it.each(BASES)(`probe and chat have the same shape ${transport} %s`, (_label, baseURL) => {
      const { probe, chat, chatBody } = shapedPair(transport, baseURL);

      expect(Object.keys(probe.headers).sort()).toEqual(Object.keys(chat.headers).sort());
      expect(proxyConfigOf(probe.headers)).toEqual(proxyConfigOf(chat.headers));

      const probeKeys = new Set(Object.keys(probe.body));
      const chatOnly = Object.keys(chatBody).filter((key) => !probeKeys.has(key));
      expect(chatOnly.filter((key) => !CONTENT_AND_GENERATION_KEYS.has(key))).toEqual([]);
      // Conversely: what the probe has beyond chat can only be the output limit.
      const probeOnly = [...probeKeys].filter((key) => !(key in chatBody));
      expect(probeOnly.filter((key) => !OUTPUT_CAP_KEYS.has(key))).toEqual([]);
    });
  }

  it('probe and chat have the same shape: identity / storage / cache fields are on both sides (Responses)', () => {
    const { probe, chatBody } = shapedPair('openai_responses', 'https://relay.example.com/v1');
    for (const key of ['store', 'service_tier', 'prompt_cache_key']) {
      expect(chatBody, key).toHaveProperty(key);
      expect(probe.body, key).toHaveProperty(key);
    }
    expect(probe.body.store).toBe(chatBody.store);
    expect(probe.body.service_tier).toBe(chatBody.service_tier);
  });

  it('the probe carries no tools or reasoning fields: the Responses probe body has no tools or reasoning, while the chat side still carries them', () => {
    const responses = shapedPair('openai_responses', 'https://relay.example.com/v1');
    expect(responses.chatBody).toHaveProperty('tools');
    expect(responses.chatBody).toHaveProperty('reasoning');
    expect(responses.probe.body).not.toHaveProperty('tools');
    expect(responses.probe.body).not.toHaveProperty('reasoning');
    // Connection-level reasoning tier is void: an existing value is not carried by chat this turn either (automatic), and the probe does not carry it.
    const chat = shapedPair('openai_chat_completions', 'https://relay.example.com/v1');
    expect(chat.chatBody).not.toHaveProperty('reasoning_effort');
    expect(chat.probe.body).not.toHaveProperty('reasoning_effort');
    for (const transport of CHAT_TRANSPORTS) {
      const body = shapedPair(transport, 'https://relay.example.com/v1').probe.body;
      for (const key of ['tools', 'tool_choice', 'reasoning', 'reasoning_effort', 'thinking']) {
        expect(body, `${transport} ${key}`).not.toHaveProperty(key);
      }
    }
  });

  it('the Responses probe output limit is 16', () => {
    expect(probeRules.responsesMaxOutputTokens).toBe(16);
    const { probe } = shapedPair('openai_responses', 'https://relay.example.com/v1');
    expect(probe.body.max_output_tokens).toBe(probeRules.responsesMaxOutputTokens);
    expect(probe.body.stream).toBe(false);
  });

  it('the Chat / Messages / Gemini probe output limit is still 1', () => {
    const cap = probeRules.otherProtocolsMaxTokens;
    expect(shapedPair('openai_chat_completions', 'https://relay.example.com/v1').probe.body.max_tokens).toBe(cap);
    expect(shapedPair('anthropic_messages', 'https://relay.example.com/v1').probe.body.max_tokens).toBe(cap);
    expect(shapedPair('gemini_generate_content', 'https://relay.example.com/v1').probe.body.generationConfig)
      .toEqual({ maxOutputTokens: cap });
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
