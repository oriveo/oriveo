import { describe, expect, it } from 'vitest';
import type { Provider } from '@oriveo/shared';
import {
  getProviderInstanceDisplayName,
  makeDefaultProviderInstanceName,
  makeUniqueProviderInstanceName,
  makeRelayDefaultProviderInstanceName,
} from '../provider-display';

function makeProvider(overrides: Partial<Provider>): Provider {
  return {
    id: overrides.id ?? 'provider-id',
    kind: overrides.kind ?? 'openRouter',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    ...overrides,
  };
}

describe('provider-display', () => {
  it('uses customName for official provider instance display names', () => {
    const provider = makeProvider({ kind: 'openRouter', customName: 'OpenRouter 2' });

    expect(getProviderInstanceDisplayName(provider)).toBe('OpenRouter 2');
  });

  it('falls back to provider kind display name when customName is empty', () => {
    const provider = makeProvider({ kind: 'openRouter', customName: '   ' });

    expect(getProviderInstanceDisplayName(provider)).toBe('OpenRouter');
  });

  it('allocates the next numeric suffix for same-kind providers', () => {
    const providers = [
      makeProvider({ kind: 'openRouter', customName: undefined }),
      makeProvider({ kind: 'openRouter', customName: 'OpenRouter 2' }),
      makeProvider({ kind: 'openAI', customName: 'OpenAI' }),
    ];

    expect(makeDefaultProviderInstanceName('openRouter', providers)).toBe('OpenRouter 3');
  });

  it('allocates a unique provider name while excluding the current provider id', () => {
    const providers = [
      makeProvider({ id: 'current', kind: 'openRouter', customName: 'OpenRouter' }),
      makeProvider({ id: 'other', kind: 'openRouter', customName: ' openrouter 2 ' }),
      makeProvider({ id: 'openai', kind: 'openAI', customName: 'OpenRouter' }),
    ];

    expect(makeUniqueProviderInstanceName('OpenRouter', 'openRouter', providers, 'current')).toBe('OpenRouter');
    expect(makeUniqueProviderInstanceName('OpenRouter 2', 'openRouter', providers, 'current')).toBe('OpenRouter 3');
  });

  it('uses the registrable domain as the default relay provider name', () => {
    expect(makeRelayDefaultProviderInstanceName('https://aa.bb.cc/v1', [])).toBe('bb.cc');
    expect(makeRelayDefaultProviderInstanceName('https://aa.bb.cc/v1', [
      makeProvider({ id: 'relay-1', kind: 'relay', customName: 'bb.cc' }),
    ])).toBe('bb.cc 2');
    expect(makeRelayDefaultProviderInstanceName('http://localhost:11434', [])).toBe('localhost');
    expect(makeRelayDefaultProviderInstanceName('http://127.0.0.1:8000/v1', [])).toBe('127.0.0.1');
  });
});
