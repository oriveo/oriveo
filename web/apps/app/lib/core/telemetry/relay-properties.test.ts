import { describe, expect, it } from 'vitest';
import { sanitizeProperties, type Provider } from '@oriveo/shared';
import { relaySendTelemetryProperties } from './relay-properties';

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: '••relay',
    ...overrides,
  };
}

describe('relaySendTelemetryProperties', () => {
  it('records the resolved relay URL and the effective protocol while removing URL credentials', () => {
    const provider = makeProvider({
      baseURLText: 'https://configured.example/v1',
      relayResolvedBaseURLText:
        'https://alice:secret@Relay.Example.com:8443/v1/?api_key=hidden#fragment',
      relayResolvedTransport: 'anthropic_messages',
      relayRequested: { transport: 'openai_responses', authMode: 'bearer' },
    });

    // The protocol is taken only via effectiveTransport; the connection-level derived value relayResolvedTransport no longer takes part.
    expect(sanitizeProperties(relaySendTelemetryProperties(provider))).toEqual({
      relay_url: 'https://relay.example.com:8443/v1',
      relay_protocol: 'openai_responses',
    });
    // When a model sets its own protocol, record the model's protocol.
    expect(relaySendTelemetryProperties(provider, { relayTransport: 'gemini_generate_content' }).relay_protocol)
      .toBe('gemini_generate_content');
  });

  it('maps auto to the concrete runtime default and accepts a URL without scheme', () => {
    const provider = makeProvider({
      baseURLText: 'relay.example.com/v1/',
      relayRequested: { transport: 'auto', authMode: 'auto' },
    });

    expect(sanitizeProperties(relaySendTelemetryProperties(provider))).toEqual({
      relay_url: 'https://relay.example.com/v1',
      relay_protocol: 'openai_chat_completions',
    });
  });

  it('does not add relay dimensions to official providers', () => {
    expect(relaySendTelemetryProperties(makeProvider({ kind: 'openAI' }))).toEqual({});
  });
});
