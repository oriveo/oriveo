import { describe, expect, it } from 'vitest';
import {
  allowsOpenAIVerificationURL,
  buildCodexModelsURL,
  buildCodexResponsesBody,
  codexReasoningEffort,
  decodeCodexAuthorizationGrant,
  decodeCodexModelDescriptors,
  decodeOpenAIDeviceAuthorization,
  decodeOpenAISubscriptionTokens,
  mapCodexDevicePollFailure,
  mapOpenAISubscriptionFailure,
  openAISubscriptionErrorAllowsRetry,
  openAISubscriptionErrorRequiresConfigRefresh,
  openAISubscriptionTokensNeedRefresh,
  readOpenAIJWTClaim,
  resolveOpenAISubscriptionAuth,
  type OpenAISubscriptionAuthConfig,
} from '../openai-subscription';

/**
 * Pure-logic contract for Codex, meaning ChatGPT subscription sign-in.
 *
 * Nothing here touches the network. Parsing the served config, the host allowlist, the version
 * gate, decoding the two-stage device flow responses, translating upstream error codes,
 * capability parsing and the hard constraints on the outbound body are all decidable offline,
 * and they are exactly the parts that break quietly and surface on a real connection as one
 * vague error message.
 */

/**
 * The openAI entry exactly as the production /api/metadata serves it, captured 2026-08-20 and
 * copied verbatim.
 *
 * A hand-made raw fixture proves nothing about production: one misspelt field name or one
 * missing host in the allowlist still passes against a made-up sample, while the real payload
 * comes back `unavailable` and the entry disappears.
 */
const PRODUCTION_PROVIDER_CONFIG = JSON.parse(`{
  "kind": "openAI",
  "displayName": "OpenAI",
  "defaultBaseURL": "https://api.openai.com/v1",
  "apiProtocol": "openai",
  "protocolFeatures": {
    "authMethod": "bearer",
    "subscriptionAuth": {
      "chatPath": "/responses",
      "clientId": "app_EMoamEEZ73f0CkXaXp7hrann",
      "deviceAuthorizationEndpoint": "https://auth.openai.com/api/accounts/deviceauth/usercode",
      "deviceTokenEndpoint": "https://auth.openai.com/api/accounts/deviceauth/token",
      "disabledNotice": null,
      "enabled": true,
      "flow": "codex_device_code",
      "minAppVersion": { "ios": "1.2.6" },
      "modelsPath": "/models",
      "pollIntervalSeconds": 5,
      "pollTimeoutSeconds": 900,
      "redirectURI": "https://auth.openai.com/deviceauth/callback",
      "requiredHeaders": {
        "OpenAI-Beta": "responses=experimental",
        "originator": "oriveo",
        "version": "0.148.0"
      },
      "resourceBaseURL": "https://chatgpt.com/backend-api/codex",
      "tokenEndpoint": "https://auth.openai.com/oauth/token",
      "trustedAuthHosts": ["auth.openai.com"],
      "trustedVerificationHosts": ["auth.openai.com"],
      "verificationURL": "https://auth.openai.com/codex/device"
    }
  }
}`) as { protocolFeatures: { subscriptionAuth: unknown } };

const PRODUCTION_RAW = PRODUCTION_PROVIDER_CONFIG.protocolFeatures.subscriptionAuth;

function availableConfig(raw: unknown = PRODUCTION_RAW): OpenAISubscriptionAuthConfig {
  const availability = resolveOpenAISubscriptionAuth(raw);
  if (availability.state !== 'available') {
    throw new Error(`expected available, got ${availability.state}`);
  }
  return availability.config;
}

/** Build a base64url-encoded JWT; only the payload matters, the signature is not verified here. */
function jwt(payload: Record<string, unknown>): string {
  const encode = (value: unknown): string =>
    Buffer.from(JSON.stringify(value))
      .toString('base64')
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=+$/, '');
  return `${encode({ alg: 'RS256', typ: 'JWT' })}.${encode(payload)}.signature`;
}

const ACCOUNT_ID = '5c0d9a3e-1f2b-4c8d-9e7a-0b1c2d3e4f50';

/** Same shape as a real id_token: account details hang off a namespaced claim, not the top level. */
const ID_TOKEN = jwt({
  sub: 'user-1',
  'https://api.openai.com/auth': {
    chatgpt_account_id: ACCOUNT_ID,
    chatgpt_plan_type: 'pro',
  },
});

/** The access token carries exp and deliberately no chatgpt_account_id, which is the case worth pinning. */
const ACCESS_TOKEN = jwt({ sub: 'user-1', exp: 1_800_000_000 });

describe('Codex subscription - production payload end to end', () => {
  it('decodes the providerConfig the production endpoint actually serves into a usable config', () => {
    const availability = resolveOpenAISubscriptionAuth(PRODUCTION_RAW, { platform: 'web' });
    expect(availability.state).toBe('available');
    const config = availableConfig();
    expect(config.clientId).toBe('app_EMoamEEZ73f0CkXaXp7hrann');
    expect(config.deviceAuthorizationEndpoint).toBe(
      'https://auth.openai.com/api/accounts/deviceauth/usercode',
    );
    expect(config.deviceTokenEndpoint).toBe('https://auth.openai.com/api/accounts/deviceauth/token');
    expect(config.tokenEndpoint).toBe('https://auth.openai.com/oauth/token');
    expect(config.redirectURI).toBe('https://auth.openai.com/deviceauth/callback');
    expect(config.verificationURL).toBe('https://auth.openai.com/codex/device');
    expect(config.requiredHeaders).toEqual({
      'OpenAI-Beta': 'responses=experimental',
      originator: 'oriveo',
      version: '0.148.0',
    });
  });

  it('builds URLs from the production payload that land on the Codex backend paths, with no duplicated or missing segments', () => {
    const config = availableConfig();
    expect(config.responsesURL).toBe('https://chatgpt.com/backend-api/codex/responses');
    expect(config.modelsURL).toBe('https://chatgpt.com/backend-api/codex/models');
    expect(config.responsesURL).not.toContain('/codex/codex');
  });

  it('requires client_version on the catalog URL, taken from the served version header (the upstream answers 400 without it)', () => {
    const config = availableConfig();
    expect(buildCodexModelsURL(config)).toBe(
      'https://chatgpt.com/backend-api/codex/models?client_version=0.148.0',
    );
  });

  it('treats a missing web key in minAppVersion as no gate at all', () => {
    const availability = resolveOpenAISubscriptionAuth(PRODUCTION_RAW, {
      platform: 'web',
      appVersion: '0.0.1',
    });
    expect(availability.state).toBe('available');
  });
});

describe('Codex subscription - three-state availability', () => {
  it('hides the entry entirely when the backend serves nothing, instead of degrading to a dead button', () => {
    expect(resolveOpenAISubscriptionAuth(undefined).state).toBe('unavailable');
    expect(resolveOpenAISubscriptionAuth(null).state).toBe('unavailable');
    expect(resolveOpenAISubscriptionAuth('nope').state).toBe('unavailable');
  });

  it('reports disabled rather than unavailable when the kill switch is off, so connected users see a reason', () => {
    const availability = resolveOpenAISubscriptionAuth({
      ...(PRODUCTION_RAW as Record<string, unknown>),
      enabled: false,
      disabledNotice: 'We are adapting to the new OpenAI release',
    });
    expect(availability).toEqual({ state: 'disabled', notice: 'We are adapting to the new OpenAI release' });
  });

  it('bows out on an unrecognised flow instead of forcing two-stage device code logic onto a new authorization method', () => {
    const availability = resolveOpenAISubscriptionAuth({
      ...(PRODUCTION_RAW as Record<string, unknown>),
      flow: 'oauth_device_code',
    });
    expect(availability.state).toBe('unavailable');
  });

  it('bows out below minAppVersion, reporting disabled rather than silently unavailable', () => {
    const availability = resolveOpenAISubscriptionAuth(
      {
        ...(PRODUCTION_RAW as Record<string, unknown>),
        minAppVersion: { web: '1.3.0' },
      },
      { platform: 'web', appVersion: '1.2.9' },
    );
    expect(availability.state).toBe('disabled');
  });

  it('compares versions segment by segment rather than as strings (1.2.10 > 1.2.9)', () => {
    const availability = resolveOpenAISubscriptionAuth(
      {
        ...(PRODUCTION_RAW as Record<string, unknown>),
        minAppVersion: { web: '1.2.9' },
      },
      { platform: 'web', appVersion: '1.2.10' },
    );
    expect(availability.state).toBe('available');
  });
});

describe('Codex subscription - lenient decoding and host allowlist', () => {
  const base = PRODUCTION_RAW as Record<string, unknown>;

  it('reports unavailable when any required field is missing, instead of assembling a partial config', () => {
    for (const key of [
      'clientId',
      'deviceAuthorizationEndpoint',
      'deviceTokenEndpoint',
      'tokenEndpoint',
      'redirectURI',
      'verificationURL',
      'resourceBaseURL',
      'trustedAuthHosts',
      'trustedVerificationHosts',
    ]) {
      const raw = { ...base };
      delete raw[key];
      expect(resolveOpenAISubscriptionAuth(raw).state, `missing ${key}`).toBe('unavailable');
    }
  });

  it('rejects an auth endpoint whose host is not on the trusted list, which is the anti-phishing gate', () => {
    const availability = resolveOpenAISubscriptionAuth({
      ...base,
      tokenEndpoint: 'https://auth.openai.com.evil.test/oauth/token',
    });
    expect(availability.state).toBe('unavailable');
  });

  it('requires the resourceBaseURL host to equal chatgpt.com exactly, with no subdomains', () => {
    // Where the access token goes is not open to approximate matching: one rewritten served value is a credential leak.
    for (const host of ['evil.chatgpt.com', 'chatgpt.com.evil.test', 'api.openai.com']) {
      const availability = resolveOpenAISubscriptionAuth({
        ...base,
        resourceBaseURL: `https://${host}/backend-api/codex`,
      });
      expect(availability.state, host).toBe('unavailable');
    }
  });

  it('rejects URLs that embed credentials or change the port', () => {
    expect(
      resolveOpenAISubscriptionAuth({
        ...base,
        tokenEndpoint: 'https://user:pass@auth.openai.com/oauth/token',
      }).state,
    ).toBe('unavailable');
    expect(
      resolveOpenAISubscriptionAuth({
        ...base,
        tokenEndpoint: 'https://auth.openai.com:8443/oauth/token',
      }).state,
    ).toBe('unavailable');
    expect(
      resolveOpenAISubscriptionAuth({ ...base, resourceBaseURL: 'http://chatgpt.com/backend-api/codex' })
        .state,
    ).toBe('unavailable');
  });

  it('falls back to default modelsPath / chatPath instead of breaking the whole chain', () => {
    const raw = { ...base };
    delete raw.modelsPath;
    delete raw.chatPath;
    const config = availableConfig(raw);
    expect(config.modelsURL).toBe('https://chatgpt.com/backend-api/codex/models');
    expect(config.responsesURL).toBe('https://chatgpt.com/backend-api/codex/responses');
  });

  it('does not produce a double slash when resourceBaseURL has a trailing slash', () => {
    const config = availableConfig({ ...base, resourceBaseURL: 'https://chatgpt.com/backend-api/codex/' });
    expect(config.responsesURL).toBe('https://chatgpt.com/backend-api/codex/responses');
  });

  it('checks the authorization page against the verification allowlist, allowing subdomains and rejecting other domains', () => {
    const config = availableConfig();
    expect(allowsOpenAIVerificationURL(config, 'https://auth.openai.com/codex/device')).toBe(true);
    expect(allowsOpenAIVerificationURL(config, 'https://sub.auth.openai.com/codex/device')).toBe(true);
    expect(allowsOpenAIVerificationURL(config, 'https://auth.openai.com.evil.test/x')).toBe(false);
    expect(allowsOpenAIVerificationURL(config, 'http://auth.openai.com/codex/device')).toBe(false);
  });

  it('returns the catalog URL unchanged rather than hardcoding a version when no version header was served', () => {
    const raw = { ...base, requiredHeaders: { originator: 'oriveo' } };
    expect(buildCodexModelsURL(availableConfig(raw))).toBe(
      'https://chatgpt.com/backend-api/codex/models',
    );
  });
});

describe('Codex subscription - upstream response translation', () => {
  it('maps the four hard failures to distinct meanings rather than collapsing them into one generic error', () => {
    expect(mapOpenAISubscriptionFailure(426, '')).toBe('clientVersionRejected');
    expect(mapOpenAISubscriptionFailure(403, '')).toBe('subscriptionNotEligible');
    expect(mapOpenAISubscriptionFailure(401, '')).toBe('unauthorized');
    expect(mapOpenAISubscriptionFailure(429, '')).toBe('quotaExhausted');
  });

  it('recognises both error shapes, since Codex signals quota and tier through an error code rather than a status code', () => {
    // String form
    expect(mapOpenAISubscriptionFailure(400, '{"error":"usage_limit_reached"}')).toBe('quotaExhausted');
    // Object form, which may be {code} or {type}
    expect(mapOpenAISubscriptionFailure(400, '{"error":{"code":"usage_not_included"}}')).toBe(
      'subscriptionNotEligible',
    );
    expect(mapOpenAISubscriptionFailure(400, '{"error":{"type":"invalid_grant"}}')).toBe('unauthorized');
  });

  it('reads 403/404 during device polling as "not authorized yet", the opposite of a 403 elsewhere', () => {
    // Getting this wrong tells the user their account tier is unsupported right after they scanned the code.
    expect(mapCodexDevicePollFailure(403, '')).toBe('authorizationPending');
    expect(mapCodexDevicePollFailure(404, '')).toBe('authorizationPending');
    // The same status code outside the polling path still means the tier is unsupported.
    expect(mapOpenAISubscriptionFailure(403, '')).toBe('subscriptionNotEligible');
  });

  it('honours an explicit error code during polling instead of letting the 403/404 fallback swallow it', () => {
    expect(mapCodexDevicePollFailure(403, '{"error":"access_denied"}')).toBe('accessDenied');
    expect(mapCodexDevicePollFailure(400, '{"error":"deviceauth_authorization_pending"}')).toBe(
      'authorizationPending',
    );
    expect(mapCodexDevicePollFailure(400, '{"error":"slow_down"}')).toBe('slowDown');
    expect(mapCodexDevicePollFailure(400, '{"error":"expired_token"}')).toBe('codeExpired');
  });

  it('forces a config refresh only on 426, the one early signal that OpenAI changed the contract', () => {
    expect(openAISubscriptionErrorRequiresConfigRefresh('clientVersionRejected')).toBe(true);
    for (const kind of ['unauthorized', 'quotaExhausted', 'subscriptionNotEligible', 'transport'] as const) {
      expect(openAISubscriptionErrorRequiresConfigRefresh(kind)).toBe(false);
    }
  });

  it('offers no retry button on a dead-end failure, so the user does not keep clicking', () => {
    expect(openAISubscriptionErrorAllowsRetry('codeExpired')).toBe(true);
    expect(openAISubscriptionErrorAllowsRetry('transport')).toBe(true);
    expect(openAISubscriptionErrorAllowsRetry('subscriptionNotEligible')).toBe(false);
    expect(openAISubscriptionErrorAllowsRetry('quotaExhausted')).toBe(false);
    expect(openAISubscriptionErrorAllowsRetry('unauthorized')).toBe(false);
    expect(openAISubscriptionErrorAllowsRetry('clientVersionRejected')).toBe(false);
  });
});

describe('Codex subscription - two-stage device flow responses', () => {
  it('decodes device_auth_id and the user code from the usercode response, taking the authorization page from the served config rather than the response', () => {
    const config = availableConfig();
    const authorization = decodeOpenAIDeviceAuthorization(
      { device_auth_id: 'da_123', user_code: 'ABCD-1234', expires_in: 600, interval: 5 },
      config,
    );
    expect(authorization).toEqual({
      deviceAuthID: 'da_123',
      userCode: 'ABCD-1234',
      // Codex does not return verification_uri_complete, so the page address can only come from the allowlisted served value.
      verificationURL: 'https://auth.openai.com/codex/device',
      expiresIn: 600,
      interval: 5,
    });
  });

  it('reports unavailable when device_auth_id or the user code is missing, instead of proceeding on half a response', () => {
    const config = availableConfig();
    expect(decodeOpenAIDeviceAuthorization({ user_code: 'ABCD' }, config)).toBeNull();
    expect(decodeOpenAIDeviceAuthorization({ device_auth_id: 'da_1' }, config)).toBeNull();
  });

  it('falls back to the served polling timeout when expires_in is missing, and accepts interval as a numeric string', () => {
    const config = availableConfig();
    const authorization = decodeOpenAIDeviceAuthorization(
      { device_auth_id: 'da_1', user_code: 'AB', interval: '7' },
      config,
    );
    expect(authorization?.expiresIn).toBe(900);
    expect(authorization?.interval).toBe(7);
  });

  it('gets authorization_code plus code_verifier from the polling response, not tokens', () => {
    expect(
      decodeCodexAuthorizationGrant({ authorization_code: 'ac_1', code_verifier: 'cv_1' }),
    ).toEqual({ authorizationCode: 'ac_1', codeVerifier: 'cv_1' });
  });

  it('decodes a 200 without a code to null, so the caller keeps polling as pending', () => {
    expect(decodeCodexAuthorizationGrant({})).toBeNull();
    expect(decodeCodexAuthorizationGrant({ authorization_code: 'ac_1' })).toBeNull();
  });
});

describe('Codex subscription - credentials and account identity', () => {
  it('reads chatgpt_account_id from the namespaced claim in id_token rather than the top level', () => {
    expect(readOpenAIJWTClaim(ID_TOKEN, 'chatgpt_account_id')).toBe(ACCOUNT_ID);
    expect(readOpenAIJWTClaim(ID_TOKEN, 'chatgpt_plan_type')).toBe('pro');
  });

  it('decodes accountID / planType from the token response and prefers the exp carried by the access token', () => {
    const tokens = decodeOpenAISubscriptionTokens(
      {
        access_token: ACCESS_TOKEN,
        refresh_token: 'rt_1',
        id_token: ID_TOKEN,
        expires_in: 60,
      },
      1_000_000,
    );
    expect(tokens?.accountID).toBe(ACCOUNT_ID);
    expect(tokens?.planType).toBe('pro');
    expect(tokens?.refreshToken).toBe('rt_1');
    // exp=1_800_000_000 seconds -> milliseconds; more authoritative than expires_in.
    expect(tokens?.expiresAt).toBe(1_800_000_000_000);
  });

  it('treats credentials as unusable when the access token has no chatgpt_account_id and id_token is missing, instead of hunting for it', () => {
    // Decoding the claim straight from the access token surfaces as "cannot list models" right
    // after a successful authorization. Returning null here makes the failure happen at the
    // moment the credentials are obtained.
    const tokens = decodeOpenAISubscriptionTokens(
      { access_token: ACCESS_TOKEN, expires_in: 60 },
      1_000_000,
    );
    expect(tokens).toBeNull();
  });

  it('keeps the previous id_token / refresh_token when a refresh response omits them, so renewal and identity survive', () => {
    const refreshed = decodeOpenAISubscriptionTokens(
      { access_token: ACCESS_TOKEN, expires_in: 3600 },
      1_000_000,
      { refreshToken: 'rt_old', accountID: ACCOUNT_ID, planType: 'pro' },
    );
    expect(refreshed?.accountID).toBe(ACCOUNT_ID);
    expect(refreshed?.refreshToken).toBe('rt_old');
    expect(refreshed?.planType).toBe('pro');
  });

  it('fails any response that carries no access_token', () => {
    expect(decodeOpenAISubscriptionTokens({ refresh_token: 'rt' }, 1)).toBeNull();
    expect(decodeOpenAISubscriptionTokens('nope', 1)).toBeNull();
  });

  it('renews 5 minutes before expiry, avoiding the random 401 when a token expires between the check and the request', () => {
    expect(openAISubscriptionTokensNeedRefresh({ expiresAt: 1_000_000 }, 1_000_000 - 4 * 60 * 1000)).toBe(true);
    expect(openAISubscriptionTokensNeedRefresh({ expiresAt: 1_000_000 }, 1_000_000 - 6 * 60 * 1000)).toBe(false);
  });

  it('does not renew when the upstream gave no expiry, rather than refreshing on every request', () => {
    expect(openAISubscriptionTokensNeedRefresh({}, Date.now())).toBe(false);
  });
});

describe('Codex subscription - catalog and upstream-declared capabilities', () => {
  /**
   * A response captured from the production chain with a real pro account, copied field for
   * field with no simplification.
   *
   * An earlier version of this fixture also claimed to be a real capture, yet
   * `supported_reasoning_levels` had been hand-written as `["low","medium","high"]`, a flat
   * string array. The upstream actually sends an array of objects, `[{effort, description}, ...]`.
   * The suite stayed green while every subscription model in production reported no thinking
   * support. A fake fixture is worse than no test: it freezes an assumption about the upstream
   * into an assertion that nothing will ever question again.
   *
   * Before editing this data, note that all of its value comes from matching the upstream
   * exactly. Build boundary cases in a separate fixture and label them as constructed.
   */
  const REAL_MODELS_PAYLOAD = JSON.parse(`{
    "models": [
      {"slug":"gpt-5.6-sol","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"low",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast responses with lighter reasoning"},
         {"effort":"medium","description":"Balances speed and reasoning depth for everyday tasks"},
         {"effort":"high","description":"Greater reasoning depth for complex problems"},
         {"effort":"xhigh","description":"Extra high reasoning depth for complex problems"},
         {"effort":"max","description":"Maximum reasoning depth for the hardest problems"},
         {"effort":"ultra","description":"Maximum reasoning with automatic task delegation"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-5.6-terra","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"},
         {"effort":"max","description":"Max"},{"effort":"ultra","description":"Ultra"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-5.6-luna","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"},
         {"effort":"max","description":"Max"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-reserve","visibility":"hide","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[{"effort":"low","description":"Fast"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-5.5","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-5.4","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-5.4-mini","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
       "input_modalities":["text","image"],"context_window":272000},
      {"slug":"gpt-5.3-codex-spark","visibility":"list","supported_in_api":false,
       "web_search_tool_type":"text","default_reasoning_level":"high",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"}],
       "input_modalities":["text"],"context_window":128000},
      {"slug":"codex-auto-review","visibility":"hide","supported_in_api":true,
       "web_search_tool_type":"text_and_image","default_reasoning_level":"medium",
       "supported_reasoning_levels":[
         {"effort":"low","description":"Fast"},{"effort":"medium","description":"Balanced"},
         {"effort":"high","description":"Deep"},{"effort":"xhigh","description":"Extra"},
         {"effort":"max","description":"Max"}],
       "input_modalities":["text","image"],"context_window":272000}
    ]
  }`);

  /** A constructed boundary case, not a real upstream response; it pins how an undeclared capability degrades. */
  const SPARSE_MODELS_PAYLOAD = JSON.parse(`{
    "models": [
      {"slug":"no-caps","visibility":"list","supported_in_api":true},
      {"slug":"empty-caps","visibility":"list","supported_in_api":true,
       "web_search_tool_type":"","supported_reasoning_levels":[],"input_modalities":["text"]}
    ]
  }`);

  it('parses by models[].slug, filtering hidden entries and entries not supported through the API', () => {
    // Key regression: the Codex response is not the official {"data":[{"id"}]} shape, and
    // copying the official shape parses an empty catalog. 6 of the 9 entries reach the catalog:
    // gpt-reserve and codex-auto-review are visibility=hide, gpt-5.3-codex-spark has
    // supported_in_api=false.
    const descriptors = decodeCodexModelDescriptors(REAL_MODELS_PAYLOAD);
    expect(descriptors.map((d) => d.slug)).toEqual([
      'gpt-5.6-sol',
      'gpt-5.6-terra',
      'gpt-5.6-luna',
      'gpt-5.5',
      'gpt-5.4',
      'gpt-5.4-mini',
    ]);
  });

  // Observed in production 2026-08: the upstream declares 4 to 6 reasoning levels per model, and
  // parsing them as a flat string array yields undefined for every entry, leaving the level table
  // permanently empty so every subscription model reports no thinking support.
  it('decodes reasoning levels for every model that enters the catalog, with none left empty', () => {
    const descriptors = decodeCodexModelDescriptors(REAL_MODELS_PAYLOAD);
    const withoutLevels = descriptors.filter((d) => d.supportedReasoningLevels.length === 0);
    expect(withoutLevels).toEqual([]);

    const luna = descriptors.find((d) => d.slug === 'gpt-5.6-luna');
    expect(luna?.supportedReasoningLevels).toEqual(['low', 'medium', 'high', 'xhigh', 'max']);
    expect(luna?.defaultReasoningLevel).toBe('medium');
  });

  it('decodes web search capability for every model that enters the catalog', () => {
    const descriptors = decodeCodexModelDescriptors(REAL_MODELS_PAYLOAD);
    expect(descriptors.every((d) => d.supportsWebSearch)).toBe(true);
    expect(descriptors.every((d) => d.supportsImageInput)).toBe(true);
    expect(descriptors.every((d) => d.contextWindow === 272000)).toBe(true);
  });

  it('still parses a flat string array if the upstream goes back to one', () => {
    const [model] = decodeCodexModelDescriptors({
      models: [{
        slug: 'flat',
        visibility: 'list',
        supported_in_api: true,
        supported_reasoning_levels: ['low', 'high'],
      }],
    });
    expect(model.supportedReasoningLevels).toEqual(['low', 'high']);
  });

  it('skips a level entry that is neither a string nor carries effort, keeping the level table clean', () => {
    const [model] = decodeCodexModelDescriptors({
      models: [{
        slug: 'mixed',
        visibility: 'list',
        supported_in_api: true,
        supported_reasoning_levels: [{ description: 'no effort field' }, { effort: 'high' }, 42],
      }],
    });
    expect(model.supportedReasoningLevels).toEqual(['high']);
  });

  it('parses nothing from the official {"data":[{"id"}]} shape, since the two catalog routes are not interchangeable', () => {
    expect(decodeCodexModelDescriptors({ data: [{ id: 'gpt-4o' }] })).toEqual([]);
  });

  it('copies capabilities straight from the upstream declaration: declared means supported', () => {
    const sol = decodeCodexModelDescriptors(REAL_MODELS_PAYLOAD)[0];
    expect(sol).toEqual({
      slug: 'gpt-5.6-sol',
      displayName: undefined,
      supportsWebSearch: true,
      supportedReasoningLevels: ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'],
      defaultReasoningLevel: 'low',
      supportsImageInput: true,
      contextWindow: 272000,
    });
  });

  it('treats an empty string or empty array as unsupported, never guessing a capability from the slug', () => {
    const empty = decodeCodexModelDescriptors(SPARSE_MODELS_PAYLOAD).find((d) => d.slug === 'empty-caps');
    expect(empty?.supportsWebSearch).toBe(false);
    expect(empty?.supportedReasoningLevels).toEqual([]);
    expect(empty?.supportsImageInput).toBe(false);
  });

  it('keeps a model that declares no capability fields in the catalog, only downgraded to no capabilities', () => {
    // Treating "not declared" as "filter it out" would empty the entire catalog on a single upstream field change, which is far worse than a missing capability.
    const bare = decodeCodexModelDescriptors(SPARSE_MODELS_PAYLOAD).find((d) => d.slug === 'no-caps');
    expect(bare).toBeDefined();
    expect(bare?.supportsWebSearch).toBe(false);
    expect(bare?.supportedReasoningLevels).toEqual([]);
    expect(bare?.contextWindow).toBeUndefined();
  });
});

describe('Codex subscription - reasoning level admission', () => {
  const declared = ['low', 'medium', 'high', 'xhigh'];

  it('maps product levels onto values inside the upstream-declared set', () => {
    expect(codexReasoningEffort('fast', declared)).toBe('low');
    expect(codexReasoningEffort('balanced', declared)).toBe('medium');
    expect(codexReasoningEffort('deep', declared)).toBe('high');
    expect(codexReasoningEffort('max', declared)).toBe('xhigh');
  });

  it('injects nothing when the upstream declares no level table, never sending a value it does not know', () => {
    // This is exactly the shape of the grok reasoning_effort incident: a local level table exists while the upstream declares none.
    for (const mode of ['fast', 'balanced', 'deep', 'max']) {
      expect(codexReasoningEffort(mode, [])).toBeUndefined();
    }
  });

  it('never injects for automatic, leaving it to the upstream default_reasoning_level', () => {
    expect(codexReasoningEffort('automatic', declared)).toBeUndefined();
    expect(codexReasoningEffort(undefined, declared)).toBeUndefined();
  });

  it('degrades along the candidate order when the upstream offers fewer levels than the product, rather than silently sending nothing', () => {
    expect(codexReasoningEffort('max', ['low', 'medium'])).toBe('medium');
    expect(codexReasoningEffort('deep', ['medium'])).toBe('medium');
    expect(codexReasoningEffort('fast', ['minimal', 'high'])).toBe('minimal');
  });

  it('sends nothing when no product level matches the upstream table, instead of forcing one in', () => {
    expect(codexReasoningEffort('fast', ['ultra'])).toBeUndefined();
  });

  it('compares levels case-insensitively, so an upstream switching to uppercase does not break the feature', () => {
    expect(codexReasoningEffort('deep', ['LOW', 'HIGH'])).toBe('high');
  });
});

describe('Codex subscription - outbound body constraints', () => {
  const input = [{ role: 'user', content: [{ type: 'input_text', text: 'hi' }] }];

  it('requires store false, stream true, and include to carry encrypted reasoning', () => {
    const body = buildCodexResponsesBody({ modelID: 'gpt-5.6-sol', input });
    expect(body.store).toBe(false);
    expect(body.stream).toBe(true);
    expect(body.include).toEqual(['reasoning.encrypted_content']);
    expect(body.model).toBe('gpt-5.6-sol');
    expect(body.input).toBe(input);
  });

  it('puts the system prompt in instructions only, never as an input message', () => {
    const body = buildCodexResponsesBody({ modelID: 'm', input, systemPrompt: '  be brief  ' });
    expect(body.instructions).toBe('be brief');
    expect(body.input).toBe(input);
  });

  it('omits the instructions field for a blank system prompt', () => {
    const body = buildCodexResponsesBody({ modelID: 'm', input, systemPrompt: '   ' });
    expect('instructions' in body).toBe(false);
  });

  it('adds tools only when the user asked for web search and the upstream declares it', () => {
    expect(
      buildCodexResponsesBody({ modelID: 'm', input, webSearchRequested: true, webSearchDeclared: true }).tools,
    ).toEqual([{ type: 'web_search' }]);
    // The user enabled it but the upstream never declared it: do not send it, because the upstream rejects the whole request.
    expect(
      buildCodexResponsesBody({ modelID: 'm', input, webSearchRequested: true, webSearchDeclared: false }).tools,
    ).toBeUndefined();
    // Declared upstream but not enabled by the user: also not sent.
    expect(
      buildCodexResponsesBody({ modelID: 'm', input, webSearchRequested: false, webSearchDeclared: true }).tools,
    ).toBeUndefined();
  });

  it('only sends a declared reasoning level, and omits the reasoning field entirely when none is declared', () => {
    const withEffort = buildCodexResponsesBody({
      modelID: 'm',
      input,
      reasoningMode: 'deep',
      declaredReasoningLevels: ['low', 'medium', 'high'],
    });
    expect(withEffort.reasoning).toEqual({ effort: 'high', summary: 'auto' });

    const withoutDeclaration = buildCodexResponsesBody({
      modelID: 'm',
      input,
      reasoningMode: 'deep',
      declaredReasoningLevels: [],
    });
    expect('reasoning' in withoutDeclaration).toBe(false);
  });
});
