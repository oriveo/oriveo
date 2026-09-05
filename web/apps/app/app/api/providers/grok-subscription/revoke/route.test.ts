import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Upstream revocation on disconnect (RFC 7009).
 *
 * Two hard constraints: the revocation endpoint is resolved only from server-side configuration and must
 * pass the `trustedAuthHosts` allowlist (the browser cannot supply it, and a tampered value is never
 * called), and a missing optional field is skipped, because one absent endpoint must not fail a disconnect.
 */

const getRuntimeMetadata = vi.fn();
vi.mock('../../../chat/stream/runtime', () => ({
  getRuntimeMetadata: () => getRuntimeMetadata(),
}));

/** Bundled grok subscription provider config, with individual fields tweaked per case. */
function metadataWith(subscriptionOverrides: Record<string, unknown>) {
  return {
    version: 1,
    updatedAt: '2026-08-19T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {},
    providerConfigs: [
      {
        kind: 'grok',
        protocolFeatures: {
          authMethod: 'bearer',
          subscriptionAuth: {
            enabled: true,
            flow: 'oauth_device_code',
            clientId: 'b1a00492-073a-47ea-816f-4c329264a828',
            scopes: 'openid profile email offline_access grok-cli:access api:access',
            deviceAuthorizationEndpoint: 'https://auth.x.ai/oauth2/device/code',
            tokenEndpoint: 'https://auth.x.ai/oauth2/token',
            revocationEndpoint: 'https://auth.x.ai/oauth2/revoke',
            trustedAuthHosts: ['auth.x.ai'],
            trustedVerificationHosts: ['accounts.x.ai', 'x.ai'],
            resourceBaseURL: 'https://cli-chat-proxy.grok.com/v1',
            chatPath: '/chat/completions',
            modelsPath: '/models',
            requiredHeaders: { 'x-grok-client-version': '1.0.4' },
            pollIntervalSeconds: 5,
            pollTimeoutSeconds: 1800,
            ...subscriptionOverrides,
          },
        },
      },
    ],
  };
}

function buildRequest(body: unknown): Request {
  return new Request('http://localhost/api/providers/grok-subscription/revoke', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  getRuntimeMetadata.mockResolvedValue(metadataWith({}));
  fetchMock = vi.fn(async () => new Response('', { status: 200 }));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

async function loadRoute() {
  return import('./route');
}

describe('grok-subscription revoke route', () => {
  it('revokes access and refresh separately per RFC 7009 and only calls the configured trusted endpoint', async () => {
    const { POST } = await loadRoute();
    const response = await POST(
      buildRequest({ accessToken: 'access-1', refreshToken: 'refresh-1' }) as never,
    );

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ revoked: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
    const bodies = fetchMock.mock.calls.map(([url, init]) => {
      expect(url).toBe('https://auth.x.ai/oauth2/revoke');
      return new URLSearchParams((init as RequestInit).body as string);
    });
    expect(bodies.map((body) => body.get('token'))).toEqual(['access-1', 'refresh-1']);
    expect(bodies.map((body) => body.get('token_type_hint'))).toEqual([
      'access_token',
      'refresh_token',
    ]);
    for (const body of bodies) {
      expect(body.get('client_id')).toBe('b1a00492-073a-47ea-816f-4c329264a828');
    }
  });

  it('calls no upstream at all when the configured revocation endpoint is outside trustedAuthHosts', async () => {
    // The allowlist is the gate against a tampered value making the server send tokens to an arbitrary address.
    getRuntimeMetadata.mockResolvedValue(
      metadataWith({ revocationEndpoint: 'https://evil.example.com/oauth2/revoke' }),
    );

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ accessToken: 'access-1' }) as never);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ revoked: false, skipped: true });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('skips silently when no revocationEndpoint is configured', async () => {
    getRuntimeMetadata.mockResolvedValue(metadataWith({ revocationEndpoint: null }));

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ accessToken: 'access-1' }) as never);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ revoked: false, skipped: true });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('returns 200 even when the upstream fails, since a failed revocation must not fail the disconnect', async () => {
    fetchMock.mockRejectedValue(new Error('boom'));

    const { POST } = await loadRoute();
    const response = await POST(buildRequest({ accessToken: 'access-1' }) as never);

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ revoked: false });
  });

  it('rejects when no token is supplied instead of calling the upstream with nothing', async () => {
    const { POST } = await loadRoute();
    const response = await POST(buildRequest({}) as never);

    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
