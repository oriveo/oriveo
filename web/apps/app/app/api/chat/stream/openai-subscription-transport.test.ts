import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

/**
 * Outbound request building for the Codex subscription path.
 *
 * This pins six hard constraints on the body plus two capability rules: web search is on
 * only when the user intent and the upstream declaration agree, and a reasoning tier is only
 * ever a value from the upstream declared set. All of them are the kind of mistake that
 * still returns 200 while the feature silently does nothing - as when tools was hardcoded to
 * nil, so the UI let the user turn web search on and nothing was ever sent.
 */

const getRuntimeMetadata = vi.fn();
vi.mock('./runtime', () => ({
  getRuntimeMetadata: () => getRuntimeMetadata(),
}));

const SUBSCRIPTION_AUTH = {
  enabled: true,
  flow: 'codex_device_code',
  clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
  deviceAuthorizationEndpoint: 'https://auth.openai.com/api/accounts/deviceauth/usercode',
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
};

function metadataWith(subscriptionAuth: unknown) {
  return {
    version: 1,
    updatedAt: '2026-08-20T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {},
    providerConfigs: [
      { kind: 'openAI', protocolFeatures: { authMethod: 'bearer', subscriptionAuth } },
    ],
  };
}

const MESSAGES = [
  { role: 'system' as const, content: 'be brief' },
  { role: 'user' as const, content: 'hi' },
];

beforeEach(() => {
  vi.resetModules();
  getRuntimeMetadata.mockResolvedValue(metadataWith(SUBSCRIPTION_AUTH));
});

afterEach(() => {
  vi.clearAllMocks();
});

async function loadModule() {
  return import('./openai-subscription-transport');
}

async function buildRequest(options?: Record<string, unknown>) {
  const { buildCodexSubscriptionRequest, resolveOpenAISubscriptionConfig } = await loadModule();
  const config = await resolveOpenAISubscriptionConfig();
  if (!config) throw new Error('expected an available config');
  return buildCodexSubscriptionRequest(
    {
      modelID: 'gpt-5.6-sol',
      messages: MESSAGES,
      apiKey: 'access-token',
      options: options as never,
    },
    config,
  );
}

describe('resolveOpenAISubscriptionConfig', () => {
  it('accepts subscriptionAuth only from the server-side metadata', async () => {
    const { resolveOpenAISubscriptionConfig } = await loadModule();
    const config = await resolveOpenAISubscriptionConfig();
    expect(config?.responsesURL).toBe('https://chatgpt.com/backend-api/codex/responses');
  });

  it('returns null when nothing is delivered, never falling back to api.openai.com', async () => {
    // Sending a subscription token to the metered endpoint gives the user an error unrelated to the real cause.
    getRuntimeMetadata.mockResolvedValue(metadataWith(undefined));
    const { resolveOpenAISubscriptionConfig } = await loadModule();
    expect(await resolveOpenAISubscriptionConfig()).toBeNull();
  });

  it('also returns null once the kill switch is off', async () => {
    getRuntimeMetadata.mockResolvedValue(metadataWith({ ...SUBSCRIPTION_AUTH, enabled: false }));
    const { resolveOpenAISubscriptionConfig } = await loadModule();
    expect(await resolveOpenAISubscriptionConfig()).toBeNull();
  });
});

describe('buildCodexSubscriptionRequest: hard body constraints', () => {
  it('calls the delivered responses endpoint with the account id and every required header', async () => {
    const request = await buildRequest({ openAISubscriptionAccountID: 'acc-1' });
    expect(request.url).toBe('https://chatgpt.com/backend-api/codex/responses');
    expect(request.headers.Authorization).toBe('Bearer access-token');
    expect(request.headers['chatgpt-account-id']).toBe('acc-1');
    expect(request.headers.originator).toBe('oriveo');
    expect(request.headers['OpenAI-Beta']).toBe('responses=experimental');
    expect(request.headers.version).toBe('0.148.0');
    expect(request.headers.Accept).toBe('text/event-stream');
  });

  it('sets store to false, stream to true, and include to carry the encrypted reasoning', async () => {
    const request = await buildRequest({});
    expect(request.body.store).toBe(false);
    expect(request.body.stream).toBe(true);
    expect(request.body.include).toEqual(['reasoning.encrypted_content']);
    expect(request.body.model).toBe('gpt-5.6-sol');
  });

  it('puts the system prompt in instructions only, leaving nothing in input', async () => {
    const request = await buildRequest({});
    expect(request.body.instructions).toBe('be brief');
    const input = request.body.input as Array<{ role: string }>;
    expect(input.map((item) => item.role)).toEqual(['user']);
  });

  it('offers no fallback: the Codex backend has only the responses path, and falling back only earns another 404', async () => {
    const request = await buildRequest({});
    expect(request.fallback).toBeUndefined();
  });
});

describe('buildCodexSubscriptionRequest: web search requires both user intent and the upstream declaration', () => {
  it('adds the web_search tool only when both are true', async () => {
    const request = await buildRequest({
      supportsWebSearch: true,
      openAISubscriptionWebSearchDeclared: true,
    });
    expect(request.body.tools).toEqual([{ type: 'web_search' }]);
  });

  it('adds no tool for a model upstream never declared web search for, even with the toggle on', async () => {
    // Forcing in a tool upstream does not recognize gets the whole request rejected, so the user sees an outright failure rather than "no web search".
    const request = await buildRequest({
      supportsWebSearch: true,
      openAISubscriptionWebSearchDeclared: false,
    });
    expect(request.body.tools).toBeUndefined();
  });

  it('adds nothing when upstream declares it but the user has not turned it on', async () => {
    const request = await buildRequest({
      supportsWebSearch: false,
      openAISubscriptionWebSearchDeclared: true,
    });
    expect(request.body.tools).toBeUndefined();
  });
});

describe('buildCodexSubscriptionRequest: tiers come only from the upstream declared set', () => {
  it('maps a product tier to an effort value that really exists in the upstream declaration', async () => {
    const request = await buildRequest({
      reasoning: 'deep',
      upstreamReasoningLevels: ['low', 'medium', 'high'],
    });
    expect(request.body.reasoning).toEqual({ effort: 'high', summary: 'auto' });
  });

  it('omits the reasoning field entirely when upstream declares no tier table', async () => {
    // Sending a tier value upstream does not recognize is the shape of the grok reasoning_effort incident.
    const request = await buildRequest({ reasoning: 'deep', upstreamReasoningLevels: [] });
    expect('reasoning' in request.body).toBe(false);
  });

  it('injects no effort for automatic, leaving it to the upstream default_reasoning_level', async () => {
    const request = await buildRequest({
      reasoning: 'automatic',
      upstreamReasoningLevels: ['low', 'medium', 'high'],
    });
    expect('reasoning' in request.body).toBe(false);
  });

  it('degrades along the candidate order when upstream offers fewer tiers than the product, rather than silently sending nothing', async () => {
    const request = await buildRequest({
      reasoning: 'max',
      upstreamReasoningLevels: ['low', 'medium'],
    });
    expect(request.body.reasoning).toEqual({ effort: 'medium', summary: 'auto' });
  });
});
