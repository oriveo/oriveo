import { afterEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { probeRelayModelTransport, withRelayModelProbePass } from '../relay-model-probe';

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...extra,
  };
}

function upstreamOf(input: RequestInfo | URL, init?: RequestInit): string {
  return new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input);
}

describe('RL2-PROBE-03 probeRelayModelTransport (probe one model)', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('RL2-PROBE-03 production ping hits the resolved protocol root verbatim per effectiveAPIRoot, and on failure moves to the next candidate', async () => {
    const requested: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = upstreamOf(input, init);
      requested.push(url);
      if (url.endsWith('/chat/completions')) return new Response('{"id":"ok"}', { status: 200 });
      return new Response('{"error":{"message":"no route"}}', { status: 404 });
    });
    const provider: Pick<Provider, 'baseURLText' | 'relayRequested' | 'apiKey' | 'relayKind'> = {
      baseURLText: 'https://relay.example.com',
      apiKey: 'sk-test',
      relayKind: 'openai_compatible',
      relayRequested: {
        transport: 'auto',
        authMode: 'bearer',
        resolvedAPIBaseURL: 'https://relay.example.com/openai/v1',
        resolvedAPIBaseURLs: { anthropic_messages: 'https://relay.example.com/claude' },
      },
    };

    const pass = await probeRelayModelTransport({
      provider,
      modelID: 'claude-sonnet-4-5',
      candidates: ['anthropic_messages', 'openai_chat_completions', 'openai_responses'],
    });

    // Protocol roots are copied verbatim from the address table / the connection default's single-value root, with no version segment added; the third candidate exceeds the limit and is not hit.
    expect(requested).toEqual([
      'https://relay.example.com/claude/messages',
      'https://relay.example.com/openai/v1/chat/completions',
    ]);
    expect(pass).toEqual({
      transport: 'openai_chat_completions',
      apiBaseURL: 'https://relay.example.com/openai/v1',
    });
  });

  it('RL2-PROBE-03 all failing returns null', async () => {
    const ping = vi.fn(async () => {
      throw new TypeError('Failed to fetch');
    });
    const pass = await probeRelayModelTransport({
      provider: {
        baseURLText: 'https://relay.example.com',
        apiKey: 'sk-test',
        relayRequested: { transport: 'auto', authMode: 'bearer' },
      },
      modelID: 'gpt-x',
      candidates: ['openai_chat_completions'],
      ping,
    });
    expect(pass).toBeNull();
    expect(ping).toHaveBeenCalledTimes(1);
  });

  it('RL2-PROBE-03 write-back touches only that model and that one entry in the address table', () => {
    const provider: Pick<Provider, 'relayRequested' | 'models'> = {
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        resolvedAPIBaseURL: 'https://relay.example.com/v1',
        resolvedAPIBaseURLs: { gemini_generate_content: 'https://relay.example.com/v1beta' },
      },
      models: [model('a'), model('b', { relayTransport: 'anthropic_messages', relayTransportSource: 'user' })],
    };
    const next = withRelayModelProbePass(provider, 'a', {
      transport: 'openai_responses',
      apiBaseURL: 'https://relay.example.com/v1',
    });
    expect(next.relayRequested).toEqual({
      ...provider.relayRequested,
      resolvedAPIBaseURLs: {
        gemini_generate_content: 'https://relay.example.com/v1beta',
        openai_responses: 'https://relay.example.com/v1',
      },
    });
    expect(next.models[0]).toMatchObject({ relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    expect(next.models[1]).toBe(provider.models[1]);
  });
});
