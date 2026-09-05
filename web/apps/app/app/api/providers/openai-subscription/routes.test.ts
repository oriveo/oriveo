import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { CODEX_STAGE_HEADER } from './shared';

/**
 * The three Next routes behind Codex subscription sign-in.
 *
 * Three hard constraints: upstream endpoints are resolved only from server-side metadata (the
 * browser cannot supply them, and a metadata value pointing at a foreign origin is not called);
 * the two-step exchange is folded into the server side and must forward the upstream status code
 * verbatim; and the stage marker must survive, because the same 403 means "not authorized yet"
 * during polling and "tier not supported" during exchange.
 *
 * Assertions always live outside the fetch mock: the route wraps fetch in try/catch, so an
 * AssertionError thrown inside the mock is swallowed into a 502 and hides the real failure.
 */

const getRuntimeMetadata = vi.fn();
vi.mock('../../chat/stream/runtime', () => ({
  getRuntimeMetadata: () => getRuntimeMetadata(),
}));

/** OpenAI subscription slice of the provider config, with individual fields overridden per test. */
function metadataWith(subscriptionOverrides: Record<string, unknown> | null) {
  return {
    version: 1,
    updatedAt: '2026-08-20T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {},
    providerConfigs: [
      {
        kind: 'openAI',
        protocolFeatures: {
          authMethod: 'bearer',
          subscriptionAuth:
            subscriptionOverrides === null
              ? undefined
              : {
                  enabled: true,
                  flow: 'codex_device_code',
                  clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
                  deviceAuthorizationEndpoint:
                    'https://auth.openai.com/api/accounts/deviceauth/usercode',
                  deviceTokenEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/token',
                  tokenEndpoint: 'https://auth.openai.com/oauth/token',
                  redirectURI: 'https://auth.openai.com/deviceauth/callback',
                  verificationURL: 'https://auth.openai.com/codex/device',
                  trustedAuthHosts: ['auth.openai.com'],
                  trustedVerificationHosts: ['auth.openai.com'],
                  resourceBaseURL: 'https://chatgpt.com/backend-api/codex',
                  chatPath: '/responses',
                  modelsPath: '/models',
                  requiredHeaders: {
                    'OpenAI-Beta': 'responses=experimental',
                    originator: 'oriveo',
                    version: '0.148.0',
                  },
                  pollIntervalSeconds: 5,
                  pollTimeoutSeconds: 900,
                  ...subscriptionOverrides,
                },
        },
      },
    ],
  };
}

function request(path: string, body?: unknown): Request {
  return new Request(`http://localhost/api/providers/openai-subscription/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  getRuntimeMetadata.mockResolvedValue(metadataWith({}));
  fetchMock = vi.fn(async () => new Response('{}', { status: 200 }));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

/** The (url, init) of the nth fetch call; assertions are made outside the mock. */
function call(index: number): [string, RequestInit] {
  const entry = fetchMock.mock.calls[index] as [string | URL, RequestInit];
  return [String(entry[0]), entry[1]];
}

describe('device-code route', () => {
  it('sends a JSON body carrying only the configured client_id, and uses the configured endpoint', async () => {
    const { POST } = await import('./device-code/route');
    const response = await POST();
    expect(response.status).toBe(200);
    const [url, init] = call(0);
    expect(url).toBe('https://auth.openai.com/api/accounts/deviceauth/usercode');
    // The Codex device step takes JSON, not the form-urlencoded body Grok expects.
    expect((init.headers as Record<string, string>)['Content-Type']).toBe('application/json');
    expect(JSON.parse(init.body as string)).toEqual({ client_id: 'app_EMoamEEZ73f0CkXaXp7hrann' });
  });

  it('returns 503 with no subscription config and makes no upstream request at all', async () => {
    getRuntimeMetadata.mockResolvedValue(metadataWith(null));
    const { POST } = await import('./device-code/route');
    const response = await POST();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ error: 'openai_subscription_unavailable' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('returns the configured copy to the client when the kill switch is off, rather than failing silently', async () => {
    getRuntimeMetadata.mockResolvedValue(
      metadataWith({ enabled: false, disabledNotice: 'Integration in progress' }),
    );
    const { POST } = await import('./device-code/route');
    const response = await POST();
    expect(response.status).toBe(503);
    expect(await response.json()).toMatchObject({ state: 'disabled', notice: 'Integration in progress' });
  });

  it('does not call an endpoint rewritten to an outside domain -- the allowlist is the anti-phishing gate', async () => {
    getRuntimeMetadata.mockResolvedValue(
      metadataWith({ deviceAuthorizationEndpoint: 'https://auth.openai.com.evil.test/usercode' }),
    );
    const { POST } = await import('./device-code/route');
    expect((await POST()).status).toBe(503);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('returns 502 with the stage marked when the upstream is unreachable', async () => {
    fetchMock.mockRejectedValueOnce(new Error('ECONNRESET'));
    const { POST } = await import('./device-code/route');
    const response = await POST();
    expect(response.status).toBe(502);
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('poll');
  });
});

describe('token route - two-step exchange', () => {
  it('completes the PKCE exchange server-side as soon as polling yields a code, returning the token in one round trip', async () => {
    fetchMock
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ authorization_code: 'ac_1', code_verifier: 'cv_1' }), {
          status: 200,
        }),
      )
      .mockResolvedValueOnce(new Response(JSON.stringify({ access_token: 'at_1' }), { status: 200 }));

    const { POST } = await import('./token/route');
    const response = await POST(request('token', { deviceAuthID: 'da_1', userCode: 'AB-12' }) as never);

    expect(response.status).toBe(200);
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('exchange');
    expect(fetchMock).toHaveBeenCalledTimes(2);

    const [pollURL, pollInit] = call(0);
    expect(pollURL).toBe('https://auth.openai.com/api/accounts/deviceauth/token');
    expect(JSON.parse(pollInit.body as string)).toEqual({
      device_auth_id: 'da_1',
      user_code: 'AB-12',
    });

    const [exchangeURL, exchangeInit] = call(1);
    expect(exchangeURL).toBe('https://auth.openai.com/oauth/token');
    // The exchange must be form-encoded and carry the full PKCE set; without redirect_uri the upstream rejects it outright.
    expect((exchangeInit.headers as Record<string, string>)['Content-Type']).toBe(
      'application/x-www-form-urlencoded',
    );
    const fields = new URLSearchParams(exchangeInit.body as string);
    expect(fields.get('grant_type')).toBe('authorization_code');
    expect(fields.get('code')).toBe('ac_1');
    expect(fields.get('code_verifier')).toBe('cv_1');
    expect(fields.get('redirect_uri')).toBe('https://auth.openai.com/deviceauth/callback');
    expect(fields.get('client_id')).toBe('app_EMoamEEZ73f0CkXaXp7hrann');
  });

  it('a polling 200 without a code means authorization is still pending, and returns an explicit pending rather than an empty body', async () => {
    fetchMock.mockResolvedValueOnce(new Response('{}', { status: 200 }));
    const { POST } = await import('./token/route');
    const response = await POST(request('token', { deviceAuthID: 'da_1', userCode: 'AB' }) as never);
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: 'authorization_pending' });
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('poll');
    // Without a code there is no reason to exchange for a token.
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('forwards a 403 during polling verbatim and marks it poll, leaving interpretation to the browser', async () => {
    fetchMock.mockResolvedValueOnce(new Response('{"detail":"pending"}', { status: 403 }));
    const { POST } = await import('./token/route');
    const response = await POST(request('token', { deviceAuthID: 'da_1', userCode: 'AB' }) as never);
    expect(response.status).toBe(403);
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('poll');
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('marks a 403 during exchange as exchange, where the same status code means the tier is not supported', async () => {
    fetchMock
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ authorization_code: 'ac', code_verifier: 'cv' }), {
          status: 200,
        }),
      )
      .mockResolvedValueOnce(new Response('{"error":"usage_not_included"}', { status: 403 }));
    const { POST } = await import('./token/route');
    const response = await POST(request('token', { deviceAuthID: 'da', userCode: 'AB' }) as never);
    expect(response.status).toBe(403);
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('exchange');
  });

  it('renews through a form-encoded refresh_token grant and marks it refresh', async () => {
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ access_token: 'at_2' }), { status: 200 }),
    );
    const { POST } = await import('./token/route');
    const response = await POST(request('token', { refreshToken: 'rt_1' }) as never);
    expect(response.status).toBe(200);
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('refresh');
    const [url, init] = call(0);
    expect(url).toBe('https://auth.openai.com/oauth/token');
    const fields = new URLSearchParams(init.body as string);
    expect(fields.get('grant_type')).toBe('refresh_token');
    expect(fields.get('refresh_token')).toBe('rt_1');
    expect(fields.get('client_id')).toBe('app_EMoamEEZ73f0CkXaXp7hrann');
  });

  it('returns 400 when polling and refresh are both given or both missing', async () => {
    const { POST } = await import('./token/route');
    expect(
      (await POST(request('token', { deviceAuthID: 'da', userCode: 'AB', refreshToken: 'rt' }) as never))
        .status,
    ).toBe(400);
    expect((await POST(request('token', {}) as never)).status).toBe(400);
    // Half of the polling parameters is not enough either: both are required for a meaningful poll.
    expect((await POST(request('token', { deviceAuthID: 'da' }) as never)).status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('rejects an over-long opaque string outright instead of carrying it to the upstream', async () => {
    const { POST } = await import('./token/route');
    const response = await POST(request('token', { refreshToken: 'x'.repeat(5000) }) as never);
    expect(response.status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('models route', () => {
  it('appends client_version to the catalog URL and sends the account id plus every configured required header', async () => {
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ models: [] }), { status: 200 }),
    );
    const { POST } = await import('./models/route');
    const response = await POST(
      request('models', { accessToken: 'at_1', accountID: 'acc_1' }) as never,
    );
    expect(response.status).toBe(200);
    expect(response.headers.get(CODEX_STAGE_HEADER)).toBe('models');

    const [url, init] = call(0);
    // Without client_version the upstream always returns 400 missing field client_version.
    expect(url).toBe('https://chatgpt.com/backend-api/codex/models?client_version=0.148.0');
    expect(init.method).toBe('GET');
    const headers = init.headers as Record<string, string>;
    expect(headers.Authorization).toBe('Bearer at_1');
    expect(headers['chatgpt-account-id']).toBe('acc_1');
    expect(headers.originator).toBe('oriveo');
    expect(headers['OpenAI-Beta']).toBe('responses=experimental');
    expect(headers.version).toBe('0.148.0');
  });

  it('reports a missing access token or account id directly instead of letting the upstream return a vague error', async () => {
    const { POST } = await import('./models/route');
    expect(
      await (await POST(request('models', { accountID: 'acc' }) as never)).json(),
    ).toEqual({ error: 'missing_access_token' });
    expect(
      await (await POST(request('models', { accessToken: 'at' }) as never)).json(),
    ).toEqual({ error: 'missing_account_id' });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('forwards an upstream 426 verbatim, which the client uses to force a metadata refresh', async () => {
    fetchMock.mockResolvedValueOnce(new Response('{"error":"client_version"}', { status: 426 }));
    const { POST } = await import('./models/route');
    const response = await POST(
      request('models', { accessToken: 'at', accountID: 'acc' }) as never,
    );
    expect(response.status).toBe(426);
  });

  // Regression, seen in production against a real pro-account catalog: the read limit was sized
  // at 64KB for a few hundred bytes of OAuth receipt, while the Codex catalog carries dozens of
  // fields per model and is far larger. Truncating it forwarded half a JSON document, the browser
  // failed to parse it, the error surfaced as `upstream`, and the copy read "cannot connect to
  // Codex" even though the connection succeeded and the upstream returned 200 with a complete
  // catalog. Users then investigate their network and find nothing.
  it('forwards a real catalog larger than 64KB in full instead of truncating it into unparseable JSON', async () => {
    const models = Array.from({ length: 120 }, (_, i) => ({
      slug: `gpt-5.6-model-${i}`,
      visibility: 'list',
      supported_in_api: true,
      web_search_tool_type: 'text_and_image',
      input_modalities: ['text', 'image'],
      supported_reasoning_levels: ['low', 'medium', 'high'],
      context_window: 272000,
      padding: 'x'.repeat(600),
    }));
    const body = JSON.stringify({ models });
    expect(body.length).toBeGreaterThan(64 * 1024);

    fetchMock.mockResolvedValueOnce(new Response(body, { status: 200 }));
    const { POST } = await import('./models/route');
    const response = await POST(
      request('models', { accessToken: 'at', accountID: 'acc' }) as never,
    );

    expect(response.status).toBe(200);
    const text = await response.text();
    // The point of the test: what comes back is still parseable and no model is missing.
    const parsed = JSON.parse(text) as { models: unknown[] };
    expect(parsed.models).toHaveLength(120);
  });

  it('returns a recognizable error object rather than half a JSON document when the response is too large to be a real catalog', async () => {
    // Past the 4MB catalog limit, half a JSON document is still not acceptable: it would be read as the opposite of the truth, a connection failure.
    const body = JSON.stringify({ models: [], padding: 'x'.repeat(5 * 1024 * 1024) });
    fetchMock.mockResolvedValueOnce(new Response(body, { status: 200 }));
    const { POST } = await import('./models/route');
    const response = await POST(
      request('models', { accessToken: 'at', accountID: 'acc' }) as never,
    );

    const text = await response.text();
    expect(() => JSON.parse(text)).not.toThrow();
    expect(JSON.parse(text)).toMatchObject({ error: 'upstream_body_too_large' });
  });
});
