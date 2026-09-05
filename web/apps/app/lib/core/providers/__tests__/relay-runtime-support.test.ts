/**
 * @vitest-environment jsdom
 */
import { describe, expect, it } from 'vitest';
import type { Provider } from '@oriveo/shared';
import {
  relayProviderCredentialState,
  relayProviderRequiresCredential,
  relayRequiresCredential,
  resolveRelayAttachmentSupport,
  resolveRelayCredentialState,
  transportSupportsImageGeneration,
  transportSupportsReasoning,
  transportSupportsWebSearch,
} from '../relay-runtime-support';
import { DEFAULT_RELAY_RUNTIME_CONFIG } from '../../metadata/metadata-client';

function makeRelayProvider(
  overrides: Partial<Provider> = {},
): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    status: 'connected',
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: '',
    ...overrides,
  } as Provider;
}

describe('relay-runtime-support', () => {
  it('resolveRelayAttachmentSupport: a non-relay provider returns null', () => {
    const provider = makeRelayProvider({ kind: 'openAI' });
    expect(resolveRelayAttachmentSupport(provider, DEFAULT_RELAY_RUNTIME_CONFIG)).toBeNull();
  });

  it('resolveRelayAttachmentSupport: returns null while the transport is unresolved (stays disabled)', () => {
    const provider = makeRelayProvider({ relayResolvedTransport: undefined });
    expect(resolveRelayAttachmentSupport(provider, DEFAULT_RELAY_RUNTIME_CONFIG)).toBeNull();
  });

  it('resolveRelayAttachmentSupport: openai_responses inherits envelope.image/nativeFile/textFileInline', () => {
    const provider = makeRelayProvider({ relayResolvedTransport: 'openai_responses' });
    expect(resolveRelayAttachmentSupport(provider, DEFAULT_RELAY_RUNTIME_CONFIG)).toEqual({
      image: true,
      nativeFile: true,
      textFileInline: true,
    });
  });

  it('resolveRelayAttachmentSupport: openai_chat_completions has no nativeFile (a protocol-level limit)', () => {
    const provider = makeRelayProvider({ relayResolvedTransport: 'openai_chat_completions' });
    expect(resolveRelayAttachmentSupport(provider, DEFAULT_RELAY_RUNTIME_CONFIG)).toEqual({
      image: true,
      nativeFile: false,
      textFileInline: true,
    });
  });

  it('resolveRelayAttachmentSupport: when the backend envelope turns images off, the composer turns them off too', () => {
    const provider = makeRelayProvider({ relayResolvedTransport: 'openai_responses' });
    const runtimeConfig = {
      ...DEFAULT_RELAY_RUNTIME_CONFIG,
      transportEnvelopes: {
        ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes,
        openai_responses: {
          ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes.openai_responses,
          image: false,
        },
      },
    };
    expect(resolveRelayAttachmentSupport(provider, runtimeConfig)?.image).toBe(false);
  });

  it('transportSupportsWebSearch: follows the envelope, not the model capabilities', () => {
    expect(
      transportSupportsWebSearch(
        makeRelayProvider({ relayResolvedTransport: 'openai_responses' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(true);
    expect(
      transportSupportsWebSearch(
        makeRelayProvider({ relayResolvedTransport: 'openai_chat_completions' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(false);
    expect(
      transportSupportsWebSearch(
        makeRelayProvider({ relayResolvedTransport: 'anthropic_messages' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(false);
    expect(
      transportSupportsWebSearch(
        makeRelayProvider({ relayResolvedTransport: 'gemini_generate_content' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(true);
  });

  it('transportSupportsImageGeneration: openai_chat_completions / anthropic_messages are off by default', () => {
    expect(
      transportSupportsImageGeneration(
        makeRelayProvider({ relayResolvedTransport: 'openai_responses' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(true);
    expect(
      transportSupportsImageGeneration(
        makeRelayProvider({ relayResolvedTransport: 'openai_chat_completions' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(false);
    expect(
      transportSupportsImageGeneration(
        makeRelayProvider({ relayResolvedTransport: 'anthropic_messages' }),
        DEFAULT_RELAY_RUNTIME_CONFIG,
      ),
    ).toBe(false);
  });

  it('transportSupportsReasoning: every transport allows reasoning by default', () => {
    for (const transport of [
      'openai_responses',
      'openai_chat_completions',
      'anthropic_messages',
      'gemini_generate_content',
    ] as const) {
      expect(
        transportSupportsReasoning(
          makeRelayProvider({ relayResolvedTransport: transport }),
          DEFAULT_RELAY_RUNTIME_CONFIG,
        ),
      ).toBe(true);
    }
  });
});

describe('credential resolution and the connection state machine', () => {
  it('requiresCredential only looks at authMode; both unset and auto are treated as needing a credential', () => {
    expect(relayRequiresCredential('bearer')).toBe(true);
    expect(relayRequiresCredential('x_api_key')).toBe(true);
    expect(relayRequiresCredential('x_goog_api_key')).toBe(true);
    expect(relayRequiresCredential('query_key')).toBe(true);
    expect(relayRequiresCredential('auto')).toBe(true);
    expect(relayRequiresCredential(undefined)).toBe(true);
    expect(relayRequiresCredential(null)).toBe(true);
    expect(relayRequiresCredential('none')).toBe(false);
  });

  it('S0/S1/S2 follow authMode x what the key store actually holds, independent of apiKeyPreview', () => {
    expect(resolveRelayCredentialState({ authMode: 'none', hasStoredKey: false })).toBe('not_required');
    expect(resolveRelayCredentialState({ authMode: 'bearer', hasStoredKey: false })).toBe('missing');
    expect(resolveRelayCredentialState({ authMode: 'bearer', hasStoredKey: true })).toBe('present');
  });

  it('S3 only appears when a plaintext connection carries credential material', () => {
    expect(resolveRelayCredentialState({
      authMode: 'bearer', hasStoredKey: false, securityMode: 'local_http',
    })).toBe('conflict');
    expect(resolveRelayCredentialState({
      authMode: 'none', hasStoredKey: true, securityMode: 'private_vpn',
    })).toBe('conflict');
    expect(resolveRelayCredentialState({
      authMode: 'none', hasStoredKey: false, securityMode: 'local_http',
      hasSensitiveTransportCredentials: true,
    })).toBe('conflict');
    // The same credential combination is perfectly legal over an encrypted connection.
    expect(resolveRelayCredentialState({
      authMode: 'bearer', hasStoredKey: true, securityMode: 'remote_https',
    })).toBe('present');
  });

  it('provider derivation: a resolved authMode wins over the requested one', () => {
    const provider = makeRelayProvider({
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', stream: true },
      relayResolvedAuthMode: 'none',
    });
    expect(relayProviderRequiresCredential(provider)).toBe(false);
    expect(relayProviderCredentialState(provider)).toBe('not_required');
  });

  it('provider derivation: an empty apiKeyPreview does not mean there is no key', () => {
    const provider = makeRelayProvider({
      apiKey: 'sk-live-key',
      apiKeyPreview: '',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', stream: true },
    });
    expect(relayProviderCredentialState(provider)).toBe('present');
  });
});
