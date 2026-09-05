import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { applyToolCallWireAdapter } from '@oriveo/core/providers/request-builders/tool-call-wire-adapter';
import type { ProviderRequest } from '@oriveo/core/providers/request-builders/types';

/**
 * Subscription route adaptation for the chat route.
 *
 * The first assertion here is a regression sentinel: swapping only the base and not the path
 * produced a 404 on the first message, because `providers.grok.transport` already carries `/v1`
 * in its path and the subscription `resourceBaseURL` carries `/v1` as well, which composes to
 * `.../v1/v1/chat/completions`.
 */

const getRuntimeMetadata = vi.fn();
vi.mock('./runtime', () => ({ getRuntimeMetadata: () => getRuntimeMetadata() }));

/** The grok entry exactly as production `/api/metadata` serves it. */
const PRODUCTION_METADATA = {
  version: 1,
  updatedAt: '2026-08-19T00:00:00Z',
  profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
  providers: {},
  providerConfigs: [
    {
      kind: 'openAI',
      protocolFeatures: { authMethod: 'bearer' },
    },
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
          responsesPath: '/responses',
          apiBackend: 'responses',
          modelsPath: '/models',
          requiredHeaders: {
            'x-grok-client-identifier': 'oriveo',
            'x-grok-client-surface': 'grok-build',
            'x-grok-client-version': '1.0.4',
            'x-xai-token-auth': 'xai-grok-cli',
          },
          pollIntervalSeconds: 5,
          pollTimeoutSeconds: 1800,
          minAppVersion: { ios: '1.2.6' },
          disabledNotice: null,
        },
      },
    },
  ],
};

beforeEach(() => {
  vi.resetModules();
  getRuntimeMetadata.mockResolvedValue(PRODUCTION_METADATA);
});

afterEach(() => {
  vi.clearAllMocks();
});

async function loadModule() {
  return import('./grok-subscription-transport');
}

describe('resolveGrokSubscriptionConfig', () => {
  it('never derives a chatURL containing /v1/v1 from production metadata', async () => {
    const { resolveGrokSubscriptionConfig } = await loadModule();
    const config = await resolveGrokSubscriptionConfig();
    expect(config?.chatURL).toBe('https://cli-chat-proxy.grok.com/v1/chat/completions');
    expect(config?.chatURL).not.toContain('/v1/v1');
  });

  it('returns null when the backend issues no subscriptionAuth, so the route answers 503 instead of falling back to api.x.ai', async () => {
    getRuntimeMetadata.mockResolvedValue({ ...PRODUCTION_METADATA, providerConfigs: [] });
    const { resolveGrokSubscriptionConfig } = await loadModule();
    expect(await resolveGrokSubscriptionConfig()).toBeNull();
  });

  it('also returns null when the kill switch is off', async () => {
    getRuntimeMetadata.mockResolvedValue({
      ...PRODUCTION_METADATA,
      providerConfigs: [
        {
          kind: 'grok',
          protocolFeatures: {
            subscriptionAuth: {
              ...PRODUCTION_METADATA.providerConfigs[1].protocolFeatures.subscriptionAuth,
              enabled: false,
            },
          },
        },
      ],
    });
    const { resolveGrokSubscriptionConfig } = await loadModule();
    expect(await resolveGrokSubscriptionConfig()).toBeNull();
  });
});

describe('applyGrokSubscriptionTransport', () => {
  it('takes the whole URL from the issued value, attaches required headers verbatim, and keeps Authorization as bearer', async () => {
    const { applyGrokSubscriptionTransport, resolveGrokSubscriptionConfig } = await loadModule();
    const config = await resolveGrokSubscriptionConfig();
    const applied = applyGrokSubscriptionTransport(
      {
        url: 'https://api.x.ai/v1/chat/completions',
        headers: { Authorization: 'Bearer access-token', Accept: 'text/event-stream' },
        body: { model: 'grok-4.6' },
      },
      config,
    );
    expect(applied.url).toBe('https://cli-chat-proxy.grok.com/v1/responses');
    expect(applied.headers).toMatchObject({
      Authorization: 'Bearer access-token',
      Accept: 'text/event-stream',
      'x-grok-client-version': '1.0.4',
      'x-grok-client-identifier': 'oriveo',
      'x-xai-token-auth': 'xai-grok-cli',
    });
    expect(applied.body).toMatchObject({ model: 'grok-4.6', store: false, stream: true, input: [] });
  });

  it('drops the API key mode fallback, which points at a backup endpoint on a different route', async () => {
    const { applyGrokSubscriptionTransport, resolveGrokSubscriptionConfig } = await loadModule();
    const config = await resolveGrokSubscriptionConfig();
    const applied = applyGrokSubscriptionTransport(
      {
        url: 'https://api.x.ai/v1/responses',
        headers: {},
        body: {},
        fallback: { url: 'https://api.x.ai/v1/chat/completions', headers: {}, body: {} },
      },
      config,
    );
    expect(applied.fallback).toBeUndefined();
  });

  it('encodes multi-turn Responses history as input_text / output_text by role', async () => {
    const { applyGrokSubscriptionTransport, resolveGrokSubscriptionConfig } = await loadModule();
    const config = await resolveGrokSubscriptionConfig();
    const request: ProviderRequest = {
      url: 'https://api.x.ai/v1/chat/completions',
      headers: {},
      body: { model: 'grok-4.6' },
    };
    const applied = applyGrokSubscriptionTransport(
      request,
      config,
      {
        messages: [
          { role: 'user', content: 'first question' },
          { role: 'assistant', content: 'first answer' },
          { role: 'user', content: 'follow up' },
        ],
      },
    );
    expect(applied.body.input).toEqual([
      { role: 'user', content: [{ type: 'input_text', text: 'first question' }] },
      { role: 'assistant', content: [{ type: 'output_text', text: 'first answer' }] },
      { role: 'user', content: [{ type: 'input_text', text: 'follow up' }] },
    ]);
  });

  it('returns the input unchanged when config is null, leaving API key mode untouched', async () => {
    const { applyGrokSubscriptionTransport } = await loadModule();
    const request = { url: 'https://api.x.ai/v1/chat/completions', headers: { a: '1' }, body: {} };
    expect(applyGrokSubscriptionTransport(request, null)).toBe(request);
  });

  describe('reasoning tier injection', () => {
    async function applyWithReasoning(reasoning?: {
      mode?: string; declaredLevels?: readonly string[]; defaultLevel?: string;
      apiBackend?: string; supportsWebSearch?: boolean;
    }) {
      const { applyGrokSubscriptionTransport, resolveGrokSubscriptionConfig } = await loadModule();
      const config = await resolveGrokSubscriptionConfig();
      return applyGrokSubscriptionTransport(
        { url: 'https://api.x.ai/v1/chat/completions', headers: {}, body: { model: 'grok-4.6' } },
        config,
        reasoning,
      );
    }

    it('maps the product tier to a reasoning_effort that upstream actually declares', async () => {
      // Subscription models have no server profile, so the builder path injects nothing - the UI
      // would let the user pick a tier while the request carried none. This is the only injection
      // point.
      const applied = await applyWithReasoning({ mode: 'deep', declaredLevels: ['low', 'high'] });
      expect(applied.body).toMatchObject({
        model: 'grok-4.6', reasoning: { effort: 'high', summary: 'auto' },
      });
    });

    it('injects nothing when upstream declares no tier table, never sending a value upstream does not accept', async () => {
      // This is the exact shape of the grok reasoning_effort incident: a local tier table that upstream does not have.
      const applied = await applyWithReasoning({ mode: 'deep', declaredLevels: [] });
      expect(applied.body).not.toHaveProperty('reasoning');
    });

    it('sends the default tier from the upstream declared set for automatic', async () => {
      const applied = await applyWithReasoning({
        mode: 'automatic', declaredLevels: ['low', 'high'], defaultLevel: 'high',
      });
      expect(applied.body).toMatchObject({ reasoning: { effort: 'high', summary: 'auto' } });
    });

    it('behaves identically when no tier information is passed at all', async () => {
      const applied = await applyWithReasoning(undefined);
      expect(applied.body).toMatchObject({ model: 'grok-4.6', input: [], store: false });
    });

    it('always carries a real web_search on Responses when upstream declares web search', async () => {
      const applied = await applyWithReasoning({
        mode: 'deep', declaredLevels: ['high'], supportsWebSearch: true,
      });
      expect(applied.body).not.toHaveProperty('search_parameters');
      expect(applied.body).toHaveProperty('tools', [{ type: 'web_search' }]);
      expect(applied.body).not.toHaveProperty('web_search');
    });

    it('keeps the chat schema when the model explicitly declares chat', async () => {
      const applied = await applyWithReasoning({
        apiBackend: 'chat', mode: 'deep', declaredLevels: ['high'],
      });
      expect(applied.url).toBe('https://cli-chat-proxy.grok.com/v1/chat/completions');
      expect(applied.body).toEqual({ model: 'grok-4.6', reasoning_effort: 'high' });
    });

    it('keeps both the server web_search and the local function tool on Responses', async () => {
      const applied = await applyWithReasoning({ supportsWebSearch: true });
      const adapted = applyToolCallWireAdapter(applied, {
        messages: [{ role: 'user', content: 'search my library' }],
        tools: [{
          type: 'function',
          function: { name: 'search_library', description: 'Search', parameters: { type: 'object' } },
        }],
        toolChoice: 'auto',
      });
      expect(adapted.body.tools).toEqual([
        { type: 'web_search' },
        { type: 'function', name: 'search_library', description: 'Search', parameters: { type: 'object' } },
      ]);
      expect(adapted.body.tool_choice).toBe('auto');
    });
  });
});
