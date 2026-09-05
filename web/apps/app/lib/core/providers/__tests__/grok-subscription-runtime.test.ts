import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { GrokSubscriptionAuthConfig } from '@oriveo/core/providers/grok-subscription';

/**
 * Browser-side subscription runtime: all three outbound calls go through the app's own Next
 * routes, with renewal timing and failure semantics following the shared rules.
 *
 * Only `fetch` (the external IO boundary) and metadata reads are mocked; the production functions
 * themselves are under test.
 */

const getGrokSubscriptionAuthConfig = vi.fn<[], GrokSubscriptionAuthConfig | null>();
const refreshMetadata = vi.fn(async () => {});

vi.mock('../../metadata/metadata-client', () => ({
  getGrokSubscriptionAuthConfig: () => getGrokSubscriptionAuthConfig(),
  refreshMetadata: () => refreshMetadata(),
}));

const CONFIG: GrokSubscriptionAuthConfig = {
  clientId: 'client',
  scopes: 'openid',
  deviceAuthorizationEndpoint: 'https://auth.x.ai/oauth2/device/code',
  tokenEndpoint: 'https://auth.x.ai/oauth2/token',
  trustedVerificationHosts: ['accounts.x.ai'],
  resourceBaseURL: 'https://cli-chat-proxy.grok.com/v1',
  requiredHeaders: { 'x-grok-client-version': '1.0.4' },
  modelsPath: '/models',
  chatPath: '/chat/completions',
  modelsURL: 'https://cli-chat-proxy.grok.com/v1/models',
  chatURL: 'https://cli-chat-proxy.grok.com/v1/chat/completions',
  pollIntervalSeconds: 5,
  pollTimeoutSeconds: 1800,
};

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  getGrokSubscriptionAuthConfig.mockReturnValue(CONFIG);
  refreshMetadata.mockClear();
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

async function loadModule() {
  return import('../grok-subscription');
}

describe('prepareGrokSubscriptionRequest', () => {
  it('lets a token that is nowhere near expiry through without an extra renewal call', async () => {
    const { prepareGrokSubscriptionRequest } = await loadModule();
    const now = 1_700_000_000_000;
    const result = await prepareGrokSubscriptionRequest(
      { grokSubscription: { accessToken: 'at', expiresAt: now + 3_600_000, obtainedAt: now } },
      now,
    );
    expect(result).toEqual({ ok: true, value: { accessToken: 'at', config: CONFIG } });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('renews five minutes before expiry and writes back the rotated refresh_token as well', async () => {
    const { prepareGrokSubscriptionRequest } = await loadModule();
    const now = 1_700_000_000_000;
    fetchMock.mockResolvedValue(
      jsonResponse(200, { access_token: 'new-at', refresh_token: 'rotated-rt', expires_in: 21600 }),
    );
    const result = await prepareGrokSubscriptionRequest(
      {
        grokSubscription: {
          accessToken: 'old-at',
          refreshToken: 'old-rt',
          expiresAt: now + 60_000,
          obtainedAt: now,
        },
      },
      now,
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.accessToken).toBe('new-at');
    expect(result.value.refreshed?.refreshToken).toBe('rotated-rt');
    expect(fetchMock).toHaveBeenCalledWith(
      '/api/providers/grok-subscription/token',
      expect.objectContaining({ method: 'POST' }),
    );
  });

  it('lets the old token through when renewal fails but it has not actually expired, so one network hiccup does not force a new sign-in', async () => {
    const { prepareGrokSubscriptionRequest } = await loadModule();
    const now = 1_700_000_000_000;
    fetchMock.mockRejectedValue(new Error('offline'));
    const result = await prepareGrokSubscriptionRequest(
      {
        grokSubscription: {
          accessToken: 'old-at',
          refreshToken: 'old-rt',
          expiresAt: now + 60_000,
          obtainedAt: now,
        },
      },
      now,
    );
    expect(result).toEqual({ ok: true, value: { accessToken: 'old-at', config: CONFIG } });
  });

  it('returns unauthorized when the token really expired and renewal failed, asking for re-authorization rather than failing silently', async () => {
    const { prepareGrokSubscriptionRequest } = await loadModule();
    const now = 1_700_000_000_000;
    fetchMock.mockResolvedValue(jsonResponse(401, { error: 'invalid_grant' }));
    const result = await prepareGrokSubscriptionRequest(
      {
        grokSubscription: {
          accessToken: 'old-at',
          refreshToken: 'old-rt',
          expiresAt: now - 60_000,
          obtainedAt: now,
        },
      },
      now,
    );
    expect(result).toEqual({ ok: false, error: 'unauthorized' });
  });

  it('makes no outbound call and returns configurationUnavailable when the kill switch is off or nothing is configured', async () => {
    const { prepareGrokSubscriptionRequest } = await loadModule();
    getGrokSubscriptionAuthConfig.mockReturnValue(null);
    const result = await prepareGrokSubscriptionRequest(
      { grokSubscription: { accessToken: 'at', obtainedAt: 0 } },
      Date.now(),
    );
    expect(result).toEqual({ ok: false, error: 'configurationUnavailable' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('returns unauthorized when there are no local credentials', async () => {
    const { prepareGrokSubscriptionRequest } = await loadModule();
    expect(await prepareGrokSubscriptionRequest({}, Date.now())).toEqual({
      ok: false,
      error: 'unauthorized',
    });
  });
});

describe('device code and catalog', () => {
  it('returns configurationUnavailable when the authorization page host is not trusted, rather than sending the user to another domain', async () => {
    const { requestGrokDeviceAuthorization } = await loadModule();
    fetchMock.mockResolvedValue(
      jsonResponse(200, {
        device_code: 'dc',
        user_code: 'ABCD',
        verification_uri_complete: 'https://evil.example/device',
      }),
    );
    expect(await requestGrokDeviceAuthorization(CONFIG)).toEqual({
      ok: false,
      error: 'configurationUnavailable',
    });
  });

  it('translates a 503 from the route (nothing configured, or kill switch) into configurationUnavailable rather than upstream semantics', async () => {
    const { requestGrokDeviceAuthorization } = await loadModule();
    fetchMock.mockResolvedValue(jsonResponse(503, { error: 'grok_subscription_unavailable' }));
    expect(await requestGrokDeviceAuthorization(CONFIG)).toEqual({
      ok: false,
      error: 'configurationUnavailable',
    });
  });

  it('an intermediate polling state is returned as-is; the state machine decides whether to keep waiting or back off', async () => {
    const { pollGrokDeviceToken } = await loadModule();
    fetchMock.mockResolvedValue(jsonResponse(400, { error: 'authorization_pending' }));
    expect(await pollGrokDeviceToken('dc')).toEqual({ ok: false, error: 'authorizationPending' });
    fetchMock.mockResolvedValue(jsonResponse(400, { error: 'slow_down' }));
    expect(await pollGrokDeviceToken('dc')).toEqual({ ok: false, error: 'slowDown' });
  });

  it('treats an empty catalog as catalogUnavailable instead of leaving an empty list that reads as "there simply are no models"', async () => {
    const { fetchGrokSubscriptionModels } = await loadModule();
    fetchMock.mockResolvedValue(jsonResponse(200, { data: [] }));
    expect(await fetchGrokSubscriptionModels('at')).toEqual({
      ok: false,
      error: 'catalogUnavailable',
    });
  });

  it('sends only the access token to the app route when fetching the catalog, leaving the endpoint and required headers to the server', async () => {
    const { fetchGrokSubscriptionModels } = await loadModule();
    fetchMock.mockResolvedValue(jsonResponse(200, { data: [{ id: 'grok-4.6' }, { id: 'grok-4.5' }] }));
    const result = await fetchGrokSubscriptionModels('at');
    // An upstream reply carrying only an id degrades to "capabilities not declared".
    expect(result.ok).toBe(true);
    expect(result.ok && result.value.map((m) => m.id)).toEqual(['grok-4.6', 'grok-4.5']);
    expect(result.ok && result.value.every((m) => !m.supportsWebSearch && !m.supportsReasoning)).toBe(true);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe('/api/providers/grok-subscription/models');
    expect(JSON.parse(String(init.body))).toEqual({ accessToken: 'at' });
  });
});

describe('426 forces a metadata refresh', () => {
  it('only clientVersionRejected forces a refresh, since it is the one early signal that xAI changed something', async () => {
    const { refreshMetadataOnClientVersionRejected } = await loadModule();
    refreshMetadataOnClientVersionRejected('unauthorized');
    expect(refreshMetadata).not.toHaveBeenCalled();
    refreshMetadataOnClientVersionRejected('clientVersionRejected');
    expect(refreshMetadata).toHaveBeenCalledTimes(1);
  });
});
