import { describe, expect, it } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { allowsCredentialEditing, getEffectiveStatusKind } from '../provider-status';

function provider(overrides: Partial<Provider>): Provider {
  return {
    id: 'p',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    ...overrides,
  };
}

describe('provider-status', () => {
  it('keeps BYOK providers on the existing local key requirement path', () => {
    expect(allowsCredentialEditing('openAI')).toBe(true);
    expect(getEffectiveStatusKind(provider({ kind: 'openAI', apiKey: '' }))).toBe('needsKey');
  });

  // Subscription sign-in credentials are not in apiKey, which stays empty even though the
  // connection is fully usable. Without checking this on its own, the list, the detail page and
  // the recovery card would all say "needs key" while the user has no key to enter.
  it('a Grok subscription instance with credentials follows its real status and is not judged needsKey by an empty apiKey', () => {
    expect(
      getEffectiveStatusKind(
        provider({
          kind: 'grok',
          apiKey: '',
          authMode: 'subscription',
          grokSubscription: { accessToken: 'at', obtainedAt: 1 },
        }),
      ),
    ).toBe('connected');
  });

  it('a subscription instance with no credentials, such as metadata pulled from the cloud on a new device, is still needsKey', () => {
    expect(
      getEffectiveStatusKind(provider({ kind: 'grok', apiKey: '', authMode: 'subscription' })),
    ).toBe('needsKey');
  });

  // Regression guard: reading only `grokSubscription` here judges every Codex instance needsKey -
  // a "Needs API Key" badge on the hero and an "add an API key" recovery card at the top, while a
  // subscription path has no key to enter, and the fake state also masks the real lastError. The
  // rule has to dispatch by kind, matching resync in provider-sync and the authorization panel on
  // the detail page.
  it('a Codex subscription instance with credentials follows its real status and is not judged needsKey by an empty apiKey', () => {
    expect(
      getEffectiveStatusKind(
        provider({
          kind: 'openAI',
          apiKey: '',
          authMode: 'subscription',
          openAISubscription: { accessToken: 'at', accountID: 'acc', obtainedAt: 1 },
        }),
      ),
    ).toBe('connected');
  });

  it('a real issue on a Codex subscription instance is not masked by needsKey', () => {
    expect(
      getEffectiveStatusKind(
        provider({
          kind: 'openAI',
          apiKey: '',
          authMode: 'subscription',
          status: { kind: 'issue', message: "Couldn't load the model list" },
          openAISubscription: { accessToken: 'at', accountID: 'acc', obtainedAt: 1 },
        }),
      ),
    ).toBe('issue');
  });

  it('a Codex subscription instance with no credentials is still needsKey', () => {
    expect(
      getEffectiveStatusKind(provider({ kind: 'openAI', apiKey: '', authMode: 'subscription' })),
    ).toBe('needsKey');
  });

  // The two paths' credential fields never stand in for each other: Grok credentials must not make a Codex instance look connected.
  it('credential fields do not substitute for each other across paths', () => {
    expect(
      getEffectiveStatusKind(
        provider({
          kind: 'openAI',
          apiKey: '',
          authMode: 'subscription',
          grokSubscription: { accessToken: 'at', obtainedAt: 1 },
        }),
      ),
    ).toBe('needsKey');
  });

  // Regression: local engines need no authentication and send no credentials, so an empty key is
  // a valid state and must not be derived as needsKey by the missing-key rule.
  it('does not derive needsKey for a local engine relay with an intentionally empty key', () => {
    expect(getEffectiveStatusKind(provider({
      kind: 'relay',
      apiKey: '',
      baseURLText: 'http://192.168.31.250:1234',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'none',
        securityMode: 'local_http',
        engineProfile: 'lmstudio',
        resolvedAPIBaseURL: 'http://192.168.31.250:1234/v1',
      },
    }))).toBe('connected');
  });

  // Anchor: a cloud relay (no engineProfile) with an empty key must still derive needsKey, so the exemption does not weaken the missing-key rule.
  it('still derives needsKey for a cloud relay with an empty key', () => {
    expect(getEffectiveStatusKind(provider({
      kind: 'relay',
      apiKey: '',
      baseURLText: 'https://relay.example.com/v1',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    }))).toBe('needsKey');
  });
});
