import { afterEach, describe, expect, it } from 'vitest';
import { makeRelayRequested, type AIModel, type Provider, type RelayModelTransport } from '@oriveo/shared';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';
import { relayFirstSendTransport } from '../relay-first-send-transport';
import { rememberRelayCatalogEndpointTypes } from '../relay-probe-candidates';

/**
 * First-send transport for unverified models (RL2-FIRSTSEND-05): one pure function, read identically by chat first send / negative-cache key / the advanced page's "Auto =".
 * Candidates = this session's catalog endpoint types (mapped in order, de-duplicated, at most 2); only if empty, look up the cached family table. Reads the cache only, never sends a request.
 */

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

function relay(transport: string = 'auto', extra: Partial<Provider> = {}): Provider {
  const requested = makeRelayRequested('openai_compatible');
  requested.authMode = 'bearer';
  requested.transport = transport as RelayModelTransport;
  return {
    id: 'relay-first-send',
    kind: 'relay',
    customName: 'myrelay.dev',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay-secret-0123456789',
    apiKeyPreview: 'sk-r…6789',
    baseURLText: 'https://api.myrelay.dev',
    relayKind: 'openai_compatible',
    relayRequested: requested,
    ...extra,
  };
}

const noFamily = () => undefined;

afterEach(() => {
  rememberRelayCatalogEndpointTypes('relay-first-send', undefined);
});

describe('RL2-FIRSTSEND-05 first-send transport pure function', () => {
  it('RL2-FIRSTSEND-05 endpoint types first item anthropic → Messages; first item not anthropic → effectiveTransport', () => {
    const provider = relay();
    rememberRelayCatalogEndpointTypes(provider.id, {
      claude: ['anthropic', 'openai'],
      mixed: ['openai', 'anthropic'],
      gemini: ['gemini'],
      unknownFirst: ['vendor-x', 'anthropic'],
    });
    expect(relayFirstSendTransport(provider, model('claude'), { cachedFamily: noFamily })).toBe('anthropic_messages');
    expect(relayFirstSendTransport(provider, model('mixed'), { cachedFamily: noFamily })).toBe('openai_chat_completions');
    expect(relayFirstSendTransport(provider, model('gemini'), { cachedFamily: noFamily })).toBe('openai_chat_completions');
    // After unknown values are dropped, anthropic comes first.
    expect(relayFirstSendTransport(provider, model('unknownFirst'), { cachedFamily: noFamily })).toBe('anthropic_messages');
  });

  it('RL2-FIRSTSEND-05 family table is consulted only when endpoint types are empty (cache read only): anthropic → Messages; google / openai / unknown → effectiveTransport', () => {
    const provider = relay();
    const families: Record<string, string> = { 'claude-sonnet-4-5': 'anthropic', 'gemini-2.5-pro': 'google', 'gpt-5': 'openai' };
    const cachedFamily = (id: string) => families[id];
    expect(relayFirstSendTransport(provider, model('claude-sonnet-4-5'), { cachedFamily })).toBe('anthropic_messages');
    expect(relayFirstSendTransport(provider, model('gemini-2.5-pro'), { cachedFamily })).toBe('openai_chat_completions');
    expect(relayFirstSendTransport(provider, model('gpt-5'), { cachedFamily })).toBe('openai_chat_completions');
    expect(relayFirstSendTransport(provider, model('mystery'), { cachedFamily })).toBe('openai_chat_completions');
    // When endpoint types map to something, the family is not consulted.
    rememberRelayCatalogEndpointTypes(provider.id, { 'claude-sonnet-4-5': ['openai'] });
    expect(relayFirstSendTransport(provider, model('claude-sonnet-4-5'), { cachedFamily })).toBe('openai_chat_completions');
  });

  it('RL2-FIRSTSEND-05 anything not applicable = effectiveTransport: model-owned transport / follows selected connection / local / image generation / non-relay', () => {
    const anthropic = () => 'anthropic';
    const own = model('claude-own', { relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    expect(relayFirstSendTransport(relay(), own, { cachedFamily: anthropic })).toBe('openai_responses');
    // Legacy auto is treated as having no own transport.
    const legacyAuto = model('claude-auto', { relayTransport: 'auto' as RelayModelTransport });
    expect(relayFirstSendTransport(relay(), legacyAuto, { cachedFamily: anthropic })).toBe('anthropic_messages');

    const chosen = relay('openai_responses');
    expect(relayFirstSendTransport(chosen, model('claude'), { cachedFamily: anthropic })).toBe(effectiveTransport(chosen, model('claude')));

    const local = relay();
    local.relayRequested = { ...local.relayRequested!, engineProfile: 'ollama' };
    expect(relayFirstSendTransport(local, model('claude'), { cachedFamily: anthropic })).toBe('openai_chat_completions');

    const imageGen = model('claude-image', { capabilities: ['text', 'imageGeneration'], imageGenProfile: 'openai_images' } as Partial<AIModel>);
    expect(relayFirstSendTransport(relay(), imageGen, { cachedFamily: anthropic })).toBe('openai_chat_completions');

    const official = { ...relay(), kind: 'anthropic' } as Provider;
    expect(relayFirstSendTransport(official, model('claude'), { cachedFamily: anthropic })).toBe(effectiveTransport(official, model('claude')));
  });

  it('RL2-FIRSTSEND-05 first send Messages but attachment files have no extracted text and Messages cannot send files natively → first send unchanged', () => {
    const anthropic = () => 'anthropic';
    expect(relayFirstSendTransport(relay(), model('claude'), { cachedFamily: anthropic, messagesBlockedByFiles: true }))
      .toBe('openai_chat_completions');
    expect(relayFirstSendTransport(relay(), model('claude'), { cachedFamily: anthropic, messagesBlockedByFiles: false }))
      .toBe('anthropic_messages');
  });
});
