import { describe, expect, it } from 'vitest';
import {
  allowsGrokVerificationURL,
  compareGrokVersions,
  decodeGrokDeviceAuthorization,
  decodeGrokSubscriptionModelIds,
  decodeGrokSubscriptionModelDescriptors,
  decodeGrokSubscriptionTokens,
  grokSubscriptionErrorAllowsRetry,
  grokSubscriptionErrorRequiresConfigRefresh,
  grokSubscriptionTokensNeedRefresh,
  mapGrokSubscriptionFailure,
  resolveGrokSubscriptionAuth,
  type GrokSubscriptionAuthConfig,
} from '../grok-subscription';
import { toProviderError } from '../errors';

/**
 * Pure-logic contract for the Grok subscription sign-in.
 *
 * Nothing here **touches the network**: config decoding, the host allowlist, the version gate,
 * upstream error code translation and renewal timing are all decidable offline, and they are also
 * the parts most easily got wrong in a way that shows up on the real path as one vague error.
 */

/** The grok entry copied verbatim from the shipped provider catalog (captured 2026-08-19). */
const PRODUCTION_PROVIDER_CONFIG = JSON.parse(`{
  "kind": "grok",
  "displayName": "Grok",
  "defaultBaseURL": "https://api.x.ai/v1",
  "apiProtocol": "openai_compatible",
  "protocolFeatures": {
    "authMethod": "bearer",
    "subscriptionAuth": {
      "enabled": true,
      "flow": "oauth_device_code",
      "clientId": "b1a00492-073a-47ea-816f-4c329264a828",
      "scopes": "openid profile email offline_access grok-cli:access api:access",
      "deviceAuthorizationEndpoint": "https://auth.x.ai/oauth2/device/code",
      "tokenEndpoint": "https://auth.x.ai/oauth2/token",
      "revocationEndpoint": "https://auth.x.ai/oauth2/revoke",
      "trustedAuthHosts": ["auth.x.ai"],
      "trustedVerificationHosts": ["accounts.x.ai", "x.ai"],
      "resourceBaseURL": "https://cli-chat-proxy.grok.com/v1",
      "chatPath": "/chat/completions",
      "modelsPath": "/models",
      "requiredHeaders": {
        "x-grok-client-identifier": "oriveo",
        "x-grok-client-surface": "grok-build",
        "x-grok-client-version": "1.0.4",
        "x-xai-token-auth": "xai-grok-cli"
      },
      "pollIntervalSeconds": 5,
      "pollTimeoutSeconds": 1800,
      "minAppVersion": { "ios": "1.2.6" },
      "disabledNotice": null
    }
  }
}`) as { protocolFeatures: { subscriptionAuth: unknown } };

const PRODUCTION_RAW = PRODUCTION_PROVIDER_CONFIG.protocolFeatures.subscriptionAuth;

function makeRaw(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { ...(PRODUCTION_RAW as Record<string, unknown>), ...overrides };
}

function resolvedConfig(
  raw: unknown,
  options?: { appVersion?: string; platform?: string },
): GrokSubscriptionAuthConfig {
  const availability = resolveGrokSubscriptionAuth(raw, options);
  if (availability.state !== 'available') {
    throw new Error(`expected available, got ${availability.state}`);
  }
  return availability.config;
}

describe('Grok subscription, catalog payload end to end', () => {
  it('decodes the shipped providerConfig all the way into a usable config', () => {
    // Every other case starts from a **hand-built** raw object, which can only prove that correct
    // values are judged correctly, not that the real catalog JSON decodes into a usable config.
    // Without this case, any mismatch in the decode layer leaves all unit tests green while the
    // entry point never appears at runtime.
    const config = resolvedConfig(PRODUCTION_RAW);
    expect(config.clientId).toBe('b1a00492-073a-47ea-816f-4c329264a828');
    expect(config.deviceAuthorizationEndpoint).toBe('https://auth.x.ai/oauth2/device/code');
    expect(config.tokenEndpoint).toBe('https://auth.x.ai/oauth2/token');
    expect(config.revocationEndpoint).toBe('https://auth.x.ai/oauth2/revoke');
    expect(config.requiredHeaders['x-grok-client-version']).toBe('1.0.4');
    expect(config.pollIntervalSeconds).toBe(5);
    expect(config.pollTimeoutSeconds).toBe(1800);
  });

  it('builds a chatURL with no duplicated /v1 segment, the regression sentinel for the 404 seen on device in 2026-08', () => {
    const config = resolvedConfig(PRODUCTION_RAW);
    expect(config.chatURL).toBe('https://cli-chat-proxy.grok.com/v1/chat/completions');
    expect(config.chatURL).not.toContain('/v1/v1');
    expect(config.modelsURL).toBe('https://cli-chat-proxy.grok.com/v1/models');
    expect(config.modelsURL).not.toContain('/v1/v1');
  });

  it('applies no gate when minAppVersion has no web key, which is the shipped shape', () => {
    expect(resolveGrokSubscriptionAuth(PRODUCTION_RAW, { appVersion: '0.0.1', platform: 'web' }).state)
      .toBe('available');
  });
});

describe('Grok subscription, tri-state availability', () => {
  it('hides the entry point entirely when nothing is declared, instead of degrading to a dead button', () => {
    expect(resolveGrokSubscriptionAuth(undefined).state).toBe('unavailable');
    expect(resolveGrokSubscriptionAuth(null).state).toBe('unavailable');
    expect(resolveGrokSubscriptionAuth('nope').state).toBe('unavailable');
  });

  it('reports disabled rather than unavailable when the kill switch is off, so connected users see the reason', () => {
    const availability = resolveGrokSubscriptionAuth(
      makeRaw({ enabled: false, disabledNotice: 'paused by ops' }),
    );
    expect(availability).toEqual({ state: 'disabled', notice: 'paused by ops' });
  });

  it('bows out on an unrecognized flow instead of forcing device code logic onto a new authorization method', () => {
    expect(resolveGrokSubscriptionAuth(makeRaw({ flow: 'pkce_authorization_code' })).state)
      .toBe('unavailable');
  });

  it('bows out below minAppVersion as disabled rather than silently unavailable', () => {
    const availability = resolveGrokSubscriptionAuth(
      makeRaw({ minAppVersion: { web: '2.0.0' }, disabledNotice: 'update required' }),
      { appVersion: '1.2.6', platform: 'web' },
    );
    expect(availability).toEqual({ state: 'disabled', notice: 'update required' });
  });

  it('allows a client at or above minAppVersion', () => {
    expect(
      resolveGrokSubscriptionAuth(makeRaw({ minAppVersion: { web: '1.2.6' } }), {
        appVersion: '1.2.6',
        platform: 'web',
      }).state,
    ).toBe('available');
  });

  it('compares versions segment by segment rather than as strings', () => {
    expect(compareGrokVersions('1.2.10', '1.2.9')).toBe(1);
    expect(compareGrokVersions('1.2', '1.2.0')).toBe(0);
    expect(compareGrokVersions('1.10.0', '1.9.9')).toBe(1);
    expect(compareGrokVersions('1.2.3-beta', '1.2.3')).toBe(0);
  });
});

describe('Grok subscription, lenient decoding and the allowlist', () => {
  it.each([
    ['clientId', { clientId: '' }],
    ['scopes', { scopes: undefined }],
    ['resourceBaseURL', { resourceBaseURL: 'http://cli-chat-proxy.grok.com/v1' }],
    ['deviceAuthorizationEndpoint', { deviceAuthorizationEndpoint: undefined }],
    ['tokenEndpoint', { tokenEndpoint: undefined }],
    ['trustedAuthHosts', { trustedAuthHosts: [] }],
    ['trustedVerificationHosts', { trustedVerificationHosts: [] }],
  ])('degrades to unavailable when the required field %s is missing or invalid, never failing to decode', (_name, patch) => {
    expect(resolveGrokSubscriptionAuth(makeRaw(patch)).state).toBe('unavailable');
  });

  it('rejects any endpoint host outside the trusted list, which is the gate against phishing redirects', () => {
    expect(
      resolveGrokSubscriptionAuth(
        makeRaw({ tokenEndpoint: 'https://auth.evil.example/oauth2/token' }),
      ).state,
    ).toBe('unavailable');
  });

  it('rejects a URL carrying credentials or a changed port', () => {
    expect(
      resolveGrokSubscriptionAuth(
        makeRaw({ tokenEndpoint: 'https://user:pass@auth.x.ai/oauth2/token' }),
      ).state,
    ).toBe('unavailable');
    expect(
      resolveGrokSubscriptionAuth(makeRaw({ tokenEndpoint: 'https://auth.x.ai:8443/oauth2/token' }))
        .state,
    ).toBe('unavailable');
  });

  it('treats the revocation endpoint as optional, since one missing optional endpoint should not disable the whole flow', () => {
    const config = resolvedConfig(makeRaw({ revocationEndpoint: undefined }));
    expect(config.revocationEndpoint).toBeUndefined();
  });

  it('falls back to defaults for a missing modelsPath or chatPath instead of breaking the chain', () => {
    const config = resolvedConfig(makeRaw({ modelsPath: undefined, chatPath: undefined }));
    expect(config.modelsURL).toBe('https://cli-chat-proxy.grok.com/v1/models');
    expect(config.chatURL).toBe('https://cli-chat-proxy.grok.com/v1/chat/completions');
  });

  it('produces no double slash or duplicated /v1 when resourceBaseURL has a trailing slash', () => {
    const config = resolvedConfig(makeRaw({ resourceBaseURL: 'https://cli-chat-proxy.grok.com/v1/' }));
    expect(config.chatURL).toBe('https://cli-chat-proxy.grok.com/v1/chat/completions');
  });

  it('checks the authorization page against the verification allowlist, allowing subdomains and rejecting other domains', () => {
    const config = resolvedConfig(PRODUCTION_RAW);
    expect(allowsGrokVerificationURL(config, 'https://accounts.x.ai/device?code=ABCD')).toBe(true);
    expect(allowsGrokVerificationURL(config, 'https://login.accounts.x.ai/device')).toBe(true);
    expect(allowsGrokVerificationURL(config, 'https://x.ai.evil.example/device')).toBe(false);
    expect(allowsGrokVerificationURL(config, 'http://accounts.x.ai/device')).toBe(false);
    expect(allowsGrokVerificationURL(config, 'https://accounts.x.ai:8443/device')).toBe(false);
  });
});

describe('Grok subscription, upstream response translation', () => {
  it('reads the device code intermediate state from 400 plus an error code, since the status alone would end the flow', () => {
    expect(mapGrokSubscriptionFailure(400, '{"error":"authorization_pending"}')).toBe('authorizationPending');
    expect(mapGrokSubscriptionFailure(400, '{"error":"slow_down"}')).toBe('slowDown');
    expect(mapGrokSubscriptionFailure(400, '{"error":"expired_token"}')).toBe('codeExpired');
    expect(mapGrokSubscriptionFailure(400, '{"error":"access_denied"}')).toBe('accessDenied');
  });

  it('maps the four hard failures to distinct meanings rather than collapsing them into one generic error', () => {
    expect(mapGrokSubscriptionFailure(426, '')).toBe('clientVersionRejected');
    expect(mapGrokSubscriptionFailure(403, '')).toBe('subscriptionNotEligible');
    expect(mapGrokSubscriptionFailure(401, '')).toBe('unauthorized');
    expect(mapGrokSubscriptionFailure(429, '')).toBe('quotaExhausted');
    expect(new Set([
      mapGrokSubscriptionFailure(426, ''),
      mapGrokSubscriptionFailure(403, ''),
      mapGrokSubscriptionFailure(401, ''),
      mapGrokSubscriptionFailure(429, ''),
    ]).size).toBe(4);
  });

  it('forces a config refresh only on 426, the one early signal that xAI has changed something', () => {
    expect(grokSubscriptionErrorRequiresConfigRefresh('clientVersionRejected')).toBe(true);
    for (const kind of ['subscriptionNotEligible', 'unauthorized', 'quotaExhausted'] as const) {
      expect(grokSubscriptionErrorRequiresConfigRefresh(kind)).toBe(false);
    }
  });

  it('offers no retry button on a dead-end failure, so the user does not keep clicking in vain', () => {
    expect(grokSubscriptionErrorAllowsRetry('codeExpired')).toBe(true);
    expect(grokSubscriptionErrorAllowsRetry('transport')).toBe(true);
    expect(grokSubscriptionErrorAllowsRetry('subscriptionNotEligible')).toBe(false);
    expect(grokSubscriptionErrorAllowsRetry('clientVersionRejected')).toBe(false);
    expect(grokSubscriptionErrorAllowsRetry('quotaExhausted')).toBe(false);
  });
});

describe('Grok subscription, outbound error classification', () => {
  it('classifies 401/403/426/429 separately under a subscription context, differently from key mode', () => {
    const context = { grokSubscriptionAuth: true };
    expect(toProviderError(403, '', undefined, undefined, [], context).kind)
      .toBe('grokSubscriptionIneligible');
    expect(toProviderError(401, '', undefined, undefined, [], context).kind)
      .toBe('grokSubscriptionExpired');
    expect(toProviderError(426, '', undefined, undefined, [], context).kind)
      .toBe('grokSubscriptionUnavailable');
    expect(toProviderError(429, '', undefined, undefined, [], context).kind)
      .toBe('grokSubscriptionQuotaExhausted');
    // Behavior is unchanged without a subscription context: 403 is still invalidKey.
    expect(toProviderError(403, '').kind).toBe('invalidKey');
    expect(toProviderError(429, '').kind).toBe('rateLimited');
  });

  it('does not use the raw upstream text as the body of a subscription failure, since "Unauthorized" tells the user nothing', () => {
    const error = toProviderError(403, '{"error":"Forbidden"}', undefined, undefined, [], {
      grokSubscriptionAuth: true,
    });
    expect(error.message).toContain('plan');
    expect(error.message).not.toContain('Forbidden');
  });
});

describe('Grok subscription, credentials', () => {
  const config = resolvedConfig(PRODUCTION_RAW);

  it('applies the allowlist to the device code response, marking it unavailable when the authorization page is not on a trusted host', () => {
    expect(
      decodeGrokDeviceAuthorization(
        {
          device_code: 'dc',
          user_code: 'ABCD-EFGH',
          verification_uri_complete: 'https://evil.example/device?code=ABCD',
        },
        config,
      ),
    ).toBeNull();
  });

  it('parses the short code, authorization page and polling interval out of the device code response', () => {
    const decoded = decodeGrokDeviceAuthorization(
      {
        device_code: 'dc',
        user_code: 'ABCD-EFGH',
        verification_uri_complete: 'https://accounts.x.ai/device?code=ABCD-EFGH',
        expires_in: 600,
        interval: 7,
      },
      config,
    );
    expect(decoded).toEqual({
      deviceCode: 'dc',
      userCode: 'ABCD-EFGH',
      verificationURL: 'https://accounts.x.ai/device?code=ABCD-EFGH',
      expiresIn: 600,
      interval: 7,
    });
  });

  it('converts expires_in from the token response into an absolute instant', () => {
    const now = 1_700_000_000_000;
    const tokens = decodeGrokSubscriptionTokens(
      { access_token: 'at', refresh_token: 'rt', expires_in: 21600, scope: 'openid' },
      now,
    );
    expect(tokens).toEqual({
      accessToken: 'at',
      refreshToken: 'rt',
      expiresAt: now + 21600 * 1000,
      scopes: 'openid',
      obtainedAt: now,
    });
  });

  it('renews 5 minutes before expiry, avoiding the random 401 where the token is valid at check time and expired on arrival', () => {
    const now = 1_700_000_000_000;
    expect(grokSubscriptionTokensNeedRefresh({ expiresAt: now + 4 * 60 * 1000 }, now)).toBe(true);
    expect(grokSubscriptionTokensNeedRefresh({ expiresAt: now + 30 * 60 * 1000 }, now)).toBe(false);
  });

  it('does not renew when upstream gives no expiry, rather than refreshing on every request', () => {
    expect(grokSubscriptionTokensNeedRefresh({}, Date.now())).toBe(false);
  });

  it('keeps only non-empty ids in the subscription catalog', () => {
    expect(
      decodeGrokSubscriptionModelIds({
        data: [{ id: 'grok-4.6' }, { id: '' }, { name: 'x' }, { id: 'grok-4.5' }],
      }),
    ).toEqual(['grok-4.6', 'grok-4.5']);
    expect(decodeGrokSubscriptionModelIds({})).toEqual([]);
  });

  it('follows the capabilities upstream declares and degrades when it declares none, instead of hardcoding them in the client', () => {
    // Capabilities must follow the API, otherwise every new model needs a code change.
    // The field names come from the catalog cache the grok CLI writes to disk, whose origin is
    // cli-chat-proxy.grok.com/v1/models.
    const descriptors = decodeGrokSubscriptionModelDescriptors({
      data: [
        {
          id: 'grok-4.6',
          name: 'Grok 4.6',
          supports_backend_search: true,
          supports_reasoning_effort: true,
          context_window: 500000,
          api_backend: 'responses',
          reasoning_efforts: [
            { value: 'xhigh', default: false },
            { value: 'high', default: true },
            { value: 'low', default: false },
          ],
          hidden: false,
          supported_in_api: true,
        },
        { id: 'grok-legacy', supports_backend_search: false, supports_reasoning_effort: false },
        { id: 'grok-internal', hidden: true },
        { id: 'grok-plain' },
      ],
    });

    // Hidden entries are filtered out, while one that declares nothing (grok-plain) must be **kept**.
    // The loose filter is deliberate: emptying the catalog because a field is missing is a far worse
    // regression than missing a capability.
    expect(descriptors.map((d) => d.id)).toEqual(['grok-4.6', 'grok-legacy', 'grok-plain']);

    expect(descriptors[0]).toMatchObject({
      displayName: 'Grok 4.6',
      supportsWebSearch: true,
      supportsReasoning: true,
      reasoningEfforts: ['xhigh', 'high', 'low'],
      defaultReasoningEffort: 'high',
      contextWindow: 500000,
      apiBackend: 'responses',
    });

    // Explicitly unsupported means unsupported, and saying nothing also means unsupported; capabilities are never guessed from the id.
    expect(descriptors[1].supportsWebSearch).toBe(false);
    expect(descriptors[1].supportsReasoning).toBe(false);
    expect(descriptors[2].supportsWebSearch).toBe(false);
    expect(descriptors[2].supportsReasoning).toBe(false);

    expect(decodeGrokSubscriptionModelDescriptors({})).toEqual([]);
  });
});
