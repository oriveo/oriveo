import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { OpenAISubscriptionAuthConfig } from '@oriveo/core/providers/openai-subscription';

/**
 * Browser-side runtime for the Codex subscription: all three outbound calls go through the
 * app's own Next route, with refresh timing and failure semantics following the shared rules.
 *
 * What is mocked here is `fetch` (the external IO boundary) and the metadata read; the code
 * under test is the production implementation.
 *
 * Two Codex-specific traps get most of the coverage:
 * 1. **The stage header decides which failure rules apply**: the same 403 means "the user
 *    has not approved yet" while polling, and "this plan tier is unsupported" elsewhere.
 * 2. **accountID is only read from the already parsed value**: re-deriving it from the
 *    access token yields nothing, which surfaces as "could not fetch the model list"
 *    immediately after a successful authorization.
 */

const getOpenAISubscriptionAuthConfig = vi.fn<[], OpenAISubscriptionAuthConfig | null>();
const refreshMetadata = vi.fn(async () => {});

vi.mock('../../metadata/metadata-client', () => ({
  getOpenAISubscriptionAuthConfig: () => getOpenAISubscriptionAuthConfig(),
  refreshMetadata: () => refreshMetadata(),
}));

const CONFIG: OpenAISubscriptionAuthConfig = {
  clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
  deviceAuthorizationEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/usercode',
  deviceTokenEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/token',
  tokenEndpoint: 'https://auth.openai.com/oauth/token',
  verificationURL: 'https://auth.openai.com/codex/device',
  redirectURI: 'https://auth.openai.com/deviceauth/callback',
  trustedVerificationHosts: ['auth.openai.com'],
  resourceBaseURL: 'https://chatgpt.com/backend-api/codex',
  requiredHeaders: { originator: 'oriveo', version: '0.148.0' },
  modelsPath: '/models',
  chatPath: '/responses',
  modelsURL: 'https://chatgpt.com/backend-api/codex/models',
  responsesURL: 'https://chatgpt.com/backend-api/codex/responses',
  pollIntervalSeconds: 5,
  pollTimeoutSeconds: 900,
};

const ACCOUNT_ID = '5c0d9a3e-1f2b-4c8d-9e7a-0b1c2d3e4f50';

function jwt(payload: Record<string, unknown>): string {
  const encode = (value: unknown): string =>
    Buffer.from(JSON.stringify(value))
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');
  return `${encode({ alg: 'RS256' })}.${encode(payload)}.sig`;
}

/** Same shape as a real id_token: the account info hangs off a namespaced claim. */
const ID_TOKEN = jwt({
  'https://api.openai.com/auth': { chatgpt_account_id: ACCOUNT_ID, chatgpt_plan_type: 'pro' },
});
/** The access token **does not** carry chatgpt_account_id, which is exactly the trap here. */
const ACCESS_TOKEN = jwt({ sub: 'user-1' });

function jsonResponse(status: number, body: unknown, stage?: string): Response {
  return new Response(JSON.stringify(body), {
    status,
    ...(stage ? { headers: { 'X-Oriveo-Codex-Stage': stage } } : {}),
  });
}

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
  vi.resetModules();
  getOpenAISubscriptionAuthConfig.mockReturnValue(CONFIG);
  refreshMetadata.mockClear();
  fetchMock = vi.fn();
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

async function loadModule() {
  return import('../openai-subscription');
}

describe('pollOpenAIDeviceToken: the stage header decides the failure rules', () => {
  it('a 403 while polling means the user has not approved yet, not an unsupported plan tier', async () => {
    // Getting this one wrong looks like: the user has just scanned the code and is told their plan tier is unsupported, a fake failure that can never be fixed.
    fetchMock.mockResolvedValue(jsonResponse(403, { detail: 'pending' }, 'poll'));
    const { pollOpenAIDeviceToken } = await loadModule();
    const result = await pollOpenAIDeviceToken('da_1', 'AB-12');
    expect(result).toEqual({ ok: false, error: 'authorizationPending' });
  });

  it('a 403 during the exchange means an unsupported plan tier, the opposite of the polling stage', async () => {
    fetchMock.mockResolvedValue(jsonResponse(403, { error: 'usage_not_included' }, 'exchange'));
    const { pollOpenAIDeviceToken } = await loadModule();
    const result = await pollOpenAIDeviceToken('da_1', 'AB-12');
    expect(result).toEqual({ ok: false, error: 'subscriptionNotEligible' });
  });

  it('decodes the token the route folded together into a credential carrying accountID on success', async () => {
    fetchMock.mockResolvedValue(
      jsonResponse(200, {
        access_token: ACCESS_TOKEN,
        refresh_token: 'rt_1',
        id_token: ID_TOKEN,
        expires_in: 3600,
      }, 'exchange'),
    );
    const { pollOpenAIDeviceToken } = await loadModule();
    const result = await pollOpenAIDeviceToken('da_1', 'AB-12', 1_000_000);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.accountID).toBe(ACCOUNT_ID);
    expect(result.value.planType).toBe('pro');
    expect(result.value.refreshToken).toBe('rt_1');
  });

  it('fails immediately when accountID cannot be decoded, instead of keeping a credential whose requests will always miss the header', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { access_token: ACCESS_TOKEN }, 'exchange'));
    const { pollOpenAIDeviceToken } = await loadModule();
    expect(await pollOpenAIDeviceToken('da_1', 'AB')).toEqual({ ok: false, error: 'upstream' });
  });

  it('treats a 503 from the app own route as an unavailable configuration, not upstream semantics', async () => {
    fetchMock.mockResolvedValue(jsonResponse(503, { error: 'openai_subscription_unavailable' }));
    const { pollOpenAIDeviceToken } = await loadModule();
    expect(await pollOpenAIDeviceToken('da_1', 'AB')).toEqual({
      ok: false,
      error: 'configurationUnavailable',
    });
  });
});

describe('refreshOpenAISubscriptionTokens', () => {
  it('keeps the previous id_token and refresh_token when the response omits them, so account identity and refresh ability are not wiped', async () => {
    // An OpenAI refresh response usually carries only access_token. Without carrying the old values forward, every real expiry would force a new sign-in.
    fetchMock.mockResolvedValue(jsonResponse(200, { access_token: ACCESS_TOKEN, expires_in: 3600 }, 'refresh'));
    const { refreshOpenAISubscriptionTokens } = await loadModule();
    const result = await refreshOpenAISubscriptionTokens(
      { accessToken: 'old', refreshToken: 'rt_old', accountID: ACCOUNT_ID, planType: 'pro', obtainedAt: 1 },
      1_000_000,
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.accountID).toBe(ACCOUNT_ID);
    expect(result.value.refreshToken).toBe('rt_old');
    expect(result.value.planType).toBe('pro');
  });

  it('does not call upstream without a refresh token and asks for a new sign-in directly', async () => {
    const { refreshOpenAISubscriptionTokens } = await loadModule();
    const result = await refreshOpenAISubscriptionTokens({ accessToken: 'at', obtainedAt: 1 });
    expect(result).toEqual({ ok: false, error: 'unauthorized' });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('fetchOpenAISubscriptionModels', () => {
  it('hands the already parsed accountID to the route rather than making the downstream look it up', async () => {
    fetchMock.mockResolvedValue(
      jsonResponse(200, {
        models: [
          {
            slug: 'gpt-5.6-sol',
            visibility: 'list',
            supported_in_api: true,
            web_search_tool_type: 'text_and_image',
            supported_reasoning_levels: ['low', 'medium', 'high'],
          },
        ],
      }, 'models'),
    );
    const { fetchOpenAISubscriptionModels } = await loadModule();
    const result = await fetchOpenAISubscriptionModels('at', ACCOUNT_ID);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value[0]?.slug).toBe('gpt-5.6-sol');
    expect(result.value[0]?.supportsWebSearch).toBe(true);

    const body = JSON.parse(fetchMock.mock.calls[0]?.[1]?.body as string) as Record<string, unknown>;
    expect(body.accountID).toBe(ACCOUNT_ID);
  });

  it('does not call upstream with an empty accountID, since that request is certain to be rejected with a confusing error', async () => {
    const { fetchOpenAISubscriptionModels } = await loadModule();
    expect(await fetchOpenAISubscriptionModels('at', '  ')).toEqual({
      ok: false,
      error: 'unauthorized',
    });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('treats an empty catalog as catalogUnavailable rather than passing an empty list off as success', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { models: [] }, 'models'));
    const { fetchOpenAISubscriptionModels } = await loadModule();
    expect(await fetchOpenAISubscriptionModels('at', ACCOUNT_ID)).toEqual({
      ok: false,
      error: 'catalogUnavailable',
    });
  });

  it('maps 426 to clientVersionRejected and lets the caller force a metadata refresh', async () => {
    fetchMock.mockResolvedValue(jsonResponse(426, {}, 'models'));
    const { fetchOpenAISubscriptionModels, refreshMetadataOnCodexClientVersionRejected } =
      await loadModule();
    const result = await fetchOpenAISubscriptionModels('at', ACCOUNT_ID);
    expect(result).toEqual({ ok: false, error: 'clientVersionRejected' });

    refreshMetadataOnCodexClientVersionRejected('clientVersionRejected');
    expect(refreshMetadata).toHaveBeenCalledTimes(1);
    // Any other failure must not trigger a refresh; only a rejected client version can.
    refreshMetadataOnCodexClientVersionRejected('unauthorized');
    expect(refreshMetadata).toHaveBeenCalledTimes(1);
  });
});

describe('prepareOpenAISubscriptionRequest', () => {
  const stored = {
    accessToken: 'at',
    refreshToken: 'rt',
    accountID: ACCOUNT_ID,
    expiresAt: 1_700_000_000_000,
    obtainedAt: 1,
  };

  it('passes through without an extra refresh while the token is still fresh', async () => {
    const { prepareOpenAISubscriptionRequest } = await loadModule();
    const result = await prepareOpenAISubscriptionRequest(
      { openAISubscription: stored },
      stored.expiresAt - 60 * 60 * 1000,
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.accessToken).toBe('at');
    expect(result.value.accountID).toBe(ACCOUNT_ID);
    expect(result.value.refreshed).toBeUndefined();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('refreshes 5 minutes before expiry and hands the new credential back to the caller to persist', async () => {
    fetchMock.mockResolvedValue(jsonResponse(200, { access_token: ACCESS_TOKEN, expires_in: 3600 }, 'refresh'));
    const { prepareOpenAISubscriptionRequest } = await loadModule();
    const result = await prepareOpenAISubscriptionRequest(
      { openAISubscription: stored },
      stored.expiresAt - 60 * 1000,
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.refreshed?.accountID).toBe(ACCOUNT_ID);
  });

  it('passes through when a refresh fails but the old token has not really expired, so one network blip does not force a new sign-in', async () => {
    fetchMock.mockRejectedValue(new Error('boom'));
    const { prepareOpenAISubscriptionRequest } = await loadModule();
    const result = await prepareOpenAISubscriptionRequest(
      { openAISubscription: stored },
      stored.expiresAt - 60 * 1000,
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.value.accessToken).toBe('at');
  });

  it('asks for a new sign-in once the old token has expired too', async () => {
    fetchMock.mockRejectedValue(new Error('boom'));
    const { prepareOpenAISubscriptionRequest } = await loadModule();
    const result = await prepareOpenAISubscriptionRequest(
      { openAISubscription: stored },
      stored.expiresAt + 1,
    );
    expect(result).toEqual({ ok: false, error: 'unauthorized' });
  });

  it('asks for re-authorization when the credential has no accountID, instead of sending a request certain to miss the header', async () => {
    const { prepareOpenAISubscriptionRequest } = await loadModule();
    const result = await prepareOpenAISubscriptionRequest(
      { openAISubscription: { accessToken: 'at', obtainedAt: 1 } },
      1_000,
    );
    expect(result).toEqual({ ok: false, error: 'unauthorized' });
  });

  it('sends nothing outbound once the kill switch is off', async () => {
    getOpenAISubscriptionAuthConfig.mockReturnValue(null);
    const { prepareOpenAISubscriptionRequest } = await loadModule();
    const result = await prepareOpenAISubscriptionRequest({ openAISubscription: stored }, 1_000);
    expect(result).toEqual({ ok: false, error: 'configurationUnavailable' });
  });
});

describe('failure semantics to rendered kind', () => {
  it('maps the four failure classes to distinct errors.* kinds rather than collapsing them into one network error', async () => {
    const { openAISubscriptionErrorKindToProviderErrorKind: map } = await loadModule();
    const kinds = [
      map('clientVersionRejected'),
      map('subscriptionNotEligible'),
      map('unauthorized'),
      map('quotaExhausted'),
    ];
    expect(new Set(kinds).size).toBe(4);
    expect(kinds).toEqual([
      'openAISubscriptionUnavailable',
      'openAISubscriptionIneligible',
      'openAISubscriptionExpired',
      'openAISubscriptionQuotaExhausted',
    ]);
    // It must also be a different kind from the Grok one: the copy has to name which subscription it is talking about.
    expect(kinds.some((kind) => kind.startsWith('grok'))).toBe(false);
  });
});
