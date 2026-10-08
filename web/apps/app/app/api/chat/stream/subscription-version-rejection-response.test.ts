import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { __resetRuntimeMetadataCache, getRuntimeMetadata } from './runtime';
import { subscriptionVersionRejectionHeaders } from './subscription-version-rejection-response';
import { resolveGrokSubscriptionConfig } from './grok-subscription-transport';
import { subscriptionConfigRevision } from '../../../../lib/core/providers/subscription-version-rejection';

/**
 * Route-side handling of a subscription 426: force a refresh of the server-side metadata snapshot
 * and tell the browser whether the configuration changed. Runs the real runtime snapshot cache
 * and the real Grok subscription config resolution; only the fetch to the backend is replaced.
 */
function metadata(clientVersion: string) {
  return {
    version: 1,
    providers: {},
    profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: { templates: {} } },
    providerConfigs: [{
      kind: 'grok',
      protocolFeatures: {
        subscriptionAuth: {
          enabled: true,
          flow: 'oauth_device_code',
          clientId: 'b1a00492-073a-47ea-816f-4c329264a828',
          scopes: 'openid profile email offline_access grok-cli:access api:access',
          deviceAuthorizationEndpoint: 'https://auth.x.ai/oauth2/device/code',
          tokenEndpoint: 'https://auth.x.ai/oauth2/token',
          trustedAuthHosts: ['auth.x.ai'],
          trustedVerificationHosts: ['accounts.x.ai', 'x.ai'],
          resourceBaseURL: 'https://cli-chat-proxy.grok.com/v1',
          requiredHeaders: { 'x-grok-client-version': clientVersion },
        },
      },
    }],
  };
}

const respond = (clientVersion: string, etag: string) =>
  new Response(JSON.stringify({ data: metadata(clientVersion) }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: etag },
  });

describe('subscriptionVersionRejectionHeaders', () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    __resetRuntimeMetadataCache();
    fetchSpy = vi.spyOn(globalThis, 'fetch') as never;
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    __resetRuntimeMetadataCache();
  });

  it('fixture check: the real resolver accepts this published configuration', async () => {
    fetchSpy.mockResolvedValueOnce(respond('1.0.4', '"m1"'));
    await getRuntimeMetadata();
    expect((await resolveGrokSubscriptionConfig())?.requiredHeaders).toEqual({ 'x-grok-client-version': '1.0.4' });
  });

  it('refetches on 426 without waiting for the TTL and marks the request as stale when the version header was raised', async () => {
    fetchSpy.mockResolvedValueOnce(respond('1.0.4', '"m1"'));
    await getRuntimeMetadata();
    const sent = await resolveGrokSubscriptionConfig();
    fetchSpy.mockResolvedValueOnce(respond('1.0.46', '"m2"'));

    const headers = await subscriptionVersionRejectionHeaders({
      upstreamStatus: 426,
      sentConfig: sent,
      resolveCurrentConfig: resolveGrokSubscriptionConfig,
    });

    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(headers).toEqual({
      'X-Oriveo-Subscription-Config-Revision': subscriptionConfigRevision({ 'x-grok-client-version': '1.0.4' }),
      'X-Oriveo-Subscription-Config-Stale': '1',
    });
    // The next request carries the new value straight away instead of waiting out the TTL.
    expect((await resolveGrokSubscriptionConfig())?.requiredHeaders).toEqual({ 'x-grok-client-version': '1.0.46' });
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it('returns only the fingerprint, without the stale mark, when the published value is unchanged on 426', async () => {
    fetchSpy.mockResolvedValueOnce(respond('1.0.4', '"m1"'));
    await getRuntimeMetadata();
    const sent = await resolveGrokSubscriptionConfig();
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 304 }));

    const headers = await subscriptionVersionRejectionHeaders({
      upstreamStatus: 426,
      sentConfig: sent,
      resolveCurrentConfig: resolveGrokSubscriptionConfig,
    });

    expect(headers).toEqual({
      'X-Oriveo-Subscription-Config-Revision': subscriptionConfigRevision({ 'x-grok-client-version': '1.0.4' }),
    });
  });

  it('still returns the 426 headers when the refresh fails, treating the configuration as unchanged', async () => {
    fetchSpy.mockResolvedValueOnce(respond('1.0.4', '"m1"'));
    await getRuntimeMetadata();
    const sent = await resolveGrokSubscriptionConfig();
    fetchSpy.mockRejectedValueOnce(new TypeError('fetch failed'));

    const headers = await subscriptionVersionRejectionHeaders({
      upstreamStatus: 426,
      sentConfig: sent,
      resolveCurrentConfig: resolveGrokSubscriptionConfig,
    });

    expect(headers['X-Oriveo-Subscription-Config-Stale']).toBeUndefined();
    expect(headers['X-Oriveo-Subscription-Config-Revision']).toBeTruthy();
  });

  it('does nothing for a status other than 426 or outside the subscription path', async () => {
    expect(await subscriptionVersionRejectionHeaders({
      upstreamStatus: 403,
      sentConfig: { requiredHeaders: { a: '1' } },
      resolveCurrentConfig: resolveGrokSubscriptionConfig,
    })).toEqual({});
    expect(await subscriptionVersionRejectionHeaders({
      upstreamStatus: 426,
      sentConfig: null,
      resolveCurrentConfig: resolveGrokSubscriptionConfig,
    })).toEqual({});
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
