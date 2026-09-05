import { describe, expect, it, vi, beforeEach } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';
import { buildRelaySettingsCandidate, updateProviderKey } from '../provider-ops';
import {
  planRelaySettingsSave,
  refreshRelayCatalogInStore,
  resyncProviderInStore,
  verifyRelayProviderCandidate,
  verifyRelayProviderInStore,
} from './provider-sync';
import { PROVIDER_VALIDATION_MESSAGES } from './validation-messages';
import {
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
} from '../chat/capability-recovery-runtime';

const mocks = vi.hoisted(() => ({
  syncProviderModels: vi.fn(),
  validateOfficialProviderKey: vi.fn(),
  refreshMetadata: vi.fn(),
  getMetadataSnapshot: vi.fn(),
  getRelayRuntimeConfig: vi.fn(() => ({ version: 'test' })),
  didUpdateProvider: vi.fn(),
  buildOfficialEnabledModels: vi.fn(),
  enrichRelayCatalog: vi.fn((models: unknown) => models),
  prepareGrokSubscription: vi.fn(),
  fetchGrokSubscriptionModels: vi.fn(),
  persistGrokSubscriptionCredential: vi.fn(),
  prepareOpenAISubscription: vi.fn(),
  fetchOpenAISubscriptionModels: vi.fn(),
  persistOpenAISubscriptionCredential: vi.fn(),
}));

vi.mock('./service', () => ({
  syncProviderModels: mocks.syncProviderModels,
  validateOfficialProviderKey: mocks.validateOfficialProviderKey,
}));

vi.mock('../metadata/metadata-client', () => ({
  refreshMetadata: mocks.refreshMetadata,
  getMetadataSnapshot: mocks.getMetadataSnapshot,
  getRelayRuntimeConfig: mocks.getRelayRuntimeConfig,
  resolveCatalogModel: () => null,
}));

vi.mock('../sync-port', () => ({
  getSyncAdapter: () => ({
    didUpdateProvider: mocks.didUpdateProvider,
  }),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUIDSync: () => 'account-a',
}));

vi.mock('./official-model-sync', () => ({
  buildOfficialEnabledModels: mocks.buildOfficialEnabledModels,
}));

vi.mock('./relay-official-catalog-match', () => ({
  enrichRelayCatalog: mocks.enrichRelayCatalog,
}));

// Only IO is replaced; `*ErrorToValidationMessage` keeps its real implementation. The assertions
// below about which reason is written target that mapping itself, so mocking it would swap the
// predicate under test for the test's own assumption.
vi.mock('./grok-subscription', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./grok-subscription')>()),
  prepareGrokSubscriptionRequest: (...args: unknown[]) => mocks.prepareGrokSubscription(...args),
  fetchGrokSubscriptionModels: (...args: unknown[]) => mocks.fetchGrokSubscriptionModels(...args),
  refreshMetadataOnClientVersionRejected: () => {},
}));

vi.mock('./openai-subscription', async (importOriginal) => ({
  ...(await importOriginal<typeof import('./openai-subscription')>()),
  prepareOpenAISubscriptionRequest: (...args: unknown[]) => mocks.prepareOpenAISubscription(...args),
  fetchOpenAISubscriptionModels: (...args: unknown[]) => mocks.fetchOpenAISubscriptionModels(...args),
  refreshMetadataOnCodexClientVersionRejected: () => {},
}));

vi.mock('../provider-ops', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../provider-ops')>()),
  persistGrokSubscriptionCredential: (...args: unknown[]) =>
    mocks.persistGrokSubscriptionCredential(...args),
  persistOpenAISubscriptionCredential: (...args: unknown[]) =>
    mocks.persistOpenAISubscriptionCredential(...args),
}));

describe('resyncProviderInStore', () => {
  beforeEach(() => {
    localStorage.clear();
    mocks.syncProviderModels.mockReset().mockResolvedValue({ models: [] });
    // Official key validation returns valid by default (the normal path); individual cases override it.
    mocks.validateOfficialProviderKey.mockReset().mockResolvedValue('valid');
    mocks.refreshMetadata.mockReset().mockRejectedValue(new Error('offline'));
    mocks.getMetadataSnapshot.mockReset().mockReturnValue(null);
    mocks.didUpdateProvider.mockReset();
    mocks.buildOfficialEnabledModels.mockReset();
    mocks.enrichRelayCatalog.mockClear();
    mocks.enrichRelayCatalog.mockImplementation((models: unknown) => models);
    mocks.prepareGrokSubscription.mockReset();
    mocks.fetchGrokSubscriptionModels.mockReset();
    mocks.persistGrokSubscriptionCredential.mockReset().mockResolvedValue(true);
    mocks.prepareOpenAISubscription.mockReset();
    mocks.fetchOpenAISubscriptionModels.mockReset();
    mocks.persistOpenAISubscriptionCredential.mockReset().mockResolvedValue(true);
    vi.stubGlobal('fetch', vi.fn());
  });

  describe('resyncing a Grok subscription instance', () => {
    const subscriptionProvider = (): Provider => ({
      id: 'grok-sub', kind: 'grok', status: { kind: 'connected' },
      models: [{
        id: 'grok-4.6', name: 'grok-4.6', capabilities: ['text'],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
      }],
      catalogModels: [], apiKey: '', apiKeyPreview: '',
      authMode: 'subscription',
      grokSubscription: { accessToken: 'at', obtainedAt: 1 },
    });

    it('fetches the catalog live from the subscription path and never from the metadata-only official catalog', async () => {
      const store = createAppStore();
      const provider = subscriptionProvider();
      store.getState().addProvider(provider);
      const toolIdentity = {
        accountId: 'account-a', connectionId: provider.id, authMode: 'subscription' as const,
        canonicalModelId: 'grok-4.6', finalTransport: 'grok_subscription_sse',
      };
      recordToolCallSupportFalse(toolIdentity);
      mocks.prepareGrokSubscription.mockResolvedValue({ ok: true, value: { accessToken: 'at' } });
      mocks.fetchGrokSubscriptionModels.mockResolvedValue({
        ok: true,
        value: [
          { id: 'grok-4.6', supportsWebSearch: true, supportsReasoning: true, reasoningEfforts: ['high'] },
          { id: 'grok-4.5', supportsWebSearch: false, supportsReasoning: false, reasoningEfforts: [] },
        ],
      });

      await resyncProviderInStore(store, provider);

      const next = store.getState().providers[0]!;
      expect(next.models.map((model) => model.id)).toEqual(['grok-4.6', 'grok-4.5']);
      expect(next.status.kind).toBe('connected');
      // Neither official entry point may be touched: they would overwrite the subscription
      // catalog with the api.x.ai one.
      expect(mocks.buildOfficialEnabledModels).not.toHaveBeenCalled();
      expect(mocks.validateOfficialProviderKey).not.toHaveBeenCalled();
      expect(toolCallSupportIsRememberedFalse(toolIdentity)).toBe(false);
    });

    it('writes renewed credentials back locally, since refresh_token rotates and skipping the write-back destroys the ability to renew', async () => {
      const store = createAppStore();
      const provider = subscriptionProvider();
      store.getState().addProvider(provider);
      const refreshed = { accessToken: 'new-at', refreshToken: 'new-rt', obtainedAt: 2 };
      mocks.prepareGrokSubscription.mockResolvedValue({
        ok: true, value: { accessToken: 'new-at', refreshed },
      });
      mocks.fetchGrokSubscriptionModels.mockResolvedValue({
        ok: true,
        value: [{ id: 'grok-4.6', supportsWebSearch: false, supportsReasoning: false, reasoningEfforts: [] }],
      });

      await resyncProviderInStore(store, provider);

      expect(mocks.persistGrokSubscriptionCredential).toHaveBeenCalledWith(store, 'grok-sub', refreshed);
    });

    it('clears the catalog and writes an explicit reason when it cannot be fetched, leaving no possibly stale list behind', async () => {
      const store = createAppStore();
      const provider = subscriptionProvider();
      store.getState().addProvider(provider);
      mocks.prepareGrokSubscription.mockResolvedValue({ ok: true, value: { accessToken: 'at' } });
      mocks.fetchGrokSubscriptionModels.mockResolvedValue({ ok: false, error: 'catalogUnavailable' });

      await resyncProviderInStore(store, provider);

      const next = store.getState().providers[0]!;
      expect(next.models).toEqual([]);
      expect(next.lastError).toBe(PROVIDER_VALIDATION_MESSAGES.grokSubscriptionCatalogUnavailable);
      expect(next.status.kind).toBe('issue');
    });

    it('asks for re-authorization when credentials expire instead of reporting a generic sync failure', async () => {
      const store = createAppStore();
      const provider = subscriptionProvider();
      store.getState().addProvider(provider);
      mocks.prepareGrokSubscription.mockResolvedValue({ ok: false, error: 'unauthorized' });

      await resyncProviderInStore(store, provider);

      const next = store.getState().providers[0]!;
      expect(next.lastError).toBe(PROVIDER_VALIDATION_MESSAGES.grokSubscriptionReauthorize);
      expect(mocks.fetchGrokSubscriptionModels).not.toHaveBeenCalled();
    });
  });

  describe('resyncing a Codex subscription instance', () => {
    const codexProvider = (): Provider => ({
      id: 'openai-sub', kind: 'openAI', status: { kind: 'connected' },
      models: [{
        id: 'gpt-5.6-sol', name: 'gpt-5.6-sol', capabilities: ['text'],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
      }],
      catalogModels: [], apiKey: '', apiKeyPreview: '',
      authMode: 'subscription',
      openAISubscription: { accessToken: 'at', accountID: 'acc-1', obtainedAt: 1 },
    });

    it('dispatches by kind to the Codex path and never into the Grok prepare step', async () => {
      // Looking only at `authMode === 'subscription'` sends a Codex instance to read an empty
      // `grokSubscription` and report 'please authorize again' -- a fake failure the user can
      // never fix.
      const store = createAppStore();
      const provider = codexProvider();
      store.getState().addProvider(provider);
      mocks.prepareOpenAISubscription.mockResolvedValue({
        ok: true, value: { accessToken: 'at', accountID: 'acc-1' },
      });
      mocks.fetchOpenAISubscriptionModels.mockResolvedValue({
        ok: true,
        value: [
          { slug: 'gpt-5.6-sol', supportsWebSearch: true, supportedReasoningLevels: ['low', 'high'], supportsImageInput: true },
          { slug: 'gpt-5.5', supportsWebSearch: false, supportedReasoningLevels: [], supportsImageInput: false },
        ],
      });

      await resyncProviderInStore(store, provider);

      const next = store.getState().providers[0]!;
      expect(next.models.map((model) => model.id)).toEqual(['gpt-5.6-sol', 'gpt-5.5']);
      expect(next.status.kind).toBe('connected');
      expect(mocks.prepareGrokSubscription).not.toHaveBeenCalled();
      // Neither official entry point may be touched: they would overwrite the subscription
      // catalog with the api.openai.com one.
      expect(mocks.buildOfficialEnabledModels).not.toHaveBeenCalled();
      expect(mocks.validateOfficialProviderKey).not.toHaveBeenCalled();
    });

    it('copies capabilities from the upstream declaration and rebuilds the level table with the catalog', async () => {
      const store = createAppStore();
      const provider = codexProvider();
      store.getState().addProvider(provider);
      mocks.prepareOpenAISubscription.mockResolvedValue({
        ok: true, value: { accessToken: 'at', accountID: 'acc-1' },
      });
      mocks.fetchOpenAISubscriptionModels.mockResolvedValue({
        ok: true,
        value: [{
          slug: 'gpt-5.6-sol', supportsWebSearch: true,
          supportedReasoningLevels: ['low', 'medium', 'high'], supportsImageInput: true,
        }],
      });

      await resyncProviderInStore(store, provider);

      const model = store.getState().providers[0]!.models[0]!;
      expect(model.capabilities).toEqual(['text', 'web', 'reasoning', 'image']);
      expect(model.reasoningModeAvailable).toBe(true);
      expect(model.upstreamReasoningLevels).toEqual(['low', 'medium', 'high']);
    });

    it('writes the account id back locally along with the renewal', async () => {
      const store = createAppStore();
      const provider = codexProvider();
      store.getState().addProvider(provider);
      const refreshed = { accessToken: 'new-at', refreshToken: 'new-rt', accountID: 'acc-1', obtainedAt: 2 };
      mocks.prepareOpenAISubscription.mockResolvedValue({
        ok: true, value: { accessToken: 'new-at', accountID: 'acc-1', refreshed },
      });
      mocks.fetchOpenAISubscriptionModels.mockResolvedValue({
        ok: true,
        value: [{ slug: 'gpt-5.6-sol', supportsWebSearch: false, supportedReasoningLevels: [], supportsImageInput: false }],
      });

      await resyncProviderInStore(store, provider);

      expect(mocks.persistOpenAISubscriptionCredential)
        .toHaveBeenCalledWith(store, 'openai-sub', refreshed);
      // The catalog fetch must receive the already parsed accountID rather than digging it out
      // of the token downstream.
      expect(mocks.fetchOpenAISubscriptionModels).toHaveBeenCalledWith('new-at', 'acc-1');
    });

    it('clears the catalog and writes the Codex reason when it cannot be fetched, leaving no dead official catalog', async () => {
      const store = createAppStore();
      const provider = codexProvider();
      store.getState().addProvider(provider);
      mocks.prepareOpenAISubscription.mockResolvedValue({
        ok: true, value: { accessToken: 'at', accountID: 'acc-1' },
      });
      mocks.fetchOpenAISubscriptionModels.mockResolvedValue({ ok: false, error: 'catalogUnavailable' });

      await resyncProviderInStore(store, provider);

      const next = store.getState().providers[0]!;
      expect(next.models).toEqual([]);
      expect(next.catalogModels).toEqual([]);
      expect(next.lastError).toBe(PROVIDER_VALIDATION_MESSAGES.openAISubscriptionCatalogUnavailable);
      expect(next.status.kind).toBe('issue');
    });

    it('asks for re-authorization when credentials expire, using the ChatGPT wording rather than the Grok one', async () => {
      const store = createAppStore();
      const provider = codexProvider();
      store.getState().addProvider(provider);
      mocks.prepareOpenAISubscription.mockResolvedValue({ ok: false, error: 'unauthorized' });

      await resyncProviderInStore(store, provider);

      const next = store.getState().providers[0]!;
      expect(next.lastError).toBe(PROVIDER_VALIDATION_MESSAGES.openAISubscriptionReauthorize);
      expect(next.lastError).not.toBe(PROVIDER_VALIDATION_MESSAGES.grokSubscriptionReauthorize);
      expect(mocks.fetchOpenAISubscriptionModels).not.toHaveBeenCalled();
    });

    it('keeps an API key OpenAI instance on the official path, without the subscription branch intercepting it', async () => {
      const store = createAppStore();
      const provider: Provider = { ...codexProvider(), authMode: 'apiKey', apiKey: 'sk-1' };
      store.getState().addProvider(provider);
      mocks.buildOfficialEnabledModels.mockReturnValue([]);

      await resyncProviderInStore(store, provider);

      expect(mocks.prepareOpenAISubscription).not.toHaveBeenCalled();
      expect(mocks.validateOfficialProviderKey).toHaveBeenCalled();
    });
  });

  it('classifies edit verification with the explicit product allowlist, not every request-builder field', () => {
    const model: Provider['models'][number] = {
      id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'],
      reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
    };
    const current: Provider = {
      id: 'relay-plan', kind: 'relay', status: { kind: 'connected' },
      models: [model], catalogModels: [model], apiKey: 'sk-current', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'custom',
      relayRequested: {
        transport: 'openai_chat_completions', authMode: 'bearer', securityMode: 'remote_https',
        reasoningEffort: 'automatic', stream: true,
      },
    };
    // At least one candidate comes from the same production builder used for the final persist,
    // rather than the test inventing its own auth=none semantics.
    const candidate = (relayRequested: NonNullable<Provider['relayRequested']>, extra: Partial<Provider> = {}) => (
      buildRelaySettingsCandidate(current, {
        relayKind: extra.relayKind ?? current.relayKind!,
        relayRequested,
        ...(extra.baseURLText !== undefined ? { baseURLText: extra.baseURLText } : {}),
        ...(extra.models ? { models: extra.models } : {}),
      })
    );
    const requested = current.relayRequested!;
    const cases: Array<[string, Provider, boolean, boolean]> = [
      ['endpoint', candidate(requested, { baseURLText: 'https://new.example/v1' }), true, true],
      ['transport', candidate({ ...requested, transport: 'openai_responses' }), true, true],
      ['relay kind', candidate(requested, { relayKind: 'codex_style' }), true, true],
      ['auth', candidate({ ...requested, authMode: 'x_api_key' }), true, true],
      ['security', candidate({ ...requested, securityMode: 'tofu_https' }), true, false],
      ['key', { ...current, apiKey: 'sk-rotated' }, true, true],
      ['name', { ...current, customName: 'Display only' }, false, false],
      ['catalog default', candidate(requested, { models: [{ ...model, isDefault: false }] }), false, false],
      ['reasoning', candidate({ ...requested, reasoningEffort: 'high' }), false, false],
      ['stream', candidate({ ...requested, stream: false }), false, false],
      ['user agent', candidate({ ...requested, customUserAgent: 'Custom/1' }), false, false],
      ['headers', candidate({ ...requested, headers: [{ key: 'X-Tenant', value: 'one' }] }), false, false],
      ['query', candidate({ ...requested, queryParams: [{ key: 'region', value: 'sg' }] }), false, false],
    ];

    for (const [label, next, needsVerification, needsCatalogRefresh] of cases) {
      expect(planRelaySettingsSave(current, next), label).toEqual({ needsVerification, needsCatalogRefresh });
    }
  });

  it('verifies a non-directory transport through generation without issuing an incompatible /models request', async () => {
    vi.mocked(fetch).mockResolvedValueOnce(new Response(JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
    const provider: Provider = {
      id: 'relay-anthropic-verify', kind: 'relay', status: { kind: 'issue', message: 'old' },
      models: [], catalogModels: [], apiKey: 'sk-ant', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'anthropic_compatible',
      relayRequested: { transport: 'anthropic_messages', authMode: 'x_api_key', modelID: 'claude-sonnet-4-5' },
    };

    const result = await verifyRelayProviderCandidate(provider, { refreshCatalog: true });

    expect(result).toMatchObject({ ok: true, catalogRefreshed: false });
    expect(fetch).toHaveBeenCalledTimes(1);
    expect(vi.mocked(fetch).mock.calls[0]?.[0]).toBe('/api/relay/forward');
    expect(vi.mocked(fetch).mock.calls[0]?.[1]).toMatchObject({
      method: 'POST',
      headers: expect.objectContaining({ 'X-Relay-Upstream-URL': 'https://relay.example/v1/messages' }),
    });
  });

  it('persists catalog failure as a connected soft error while preserving enabled and previous catalog models', async () => {
    vi.mocked(fetch).mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'catalog offline' } }), {
      status: 503,
      headers: { 'Content-Type': 'application/json' },
    }));
    const existingModel: Provider['models'][number] = {
      id: 'still-usable', name: 'Still usable', capabilities: ['text'],
      reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
    };
    const provider: Provider = {
      id: 'relay-catalog-soft-failure', kind: 'relay', status: { kind: 'connected' },
      models: [existingModel], catalogModels: [existingModel], apiKey: 'sk-test', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };
    const store = createAppStore();
    store.getState().addProvider(provider);
    const canonical = store.getState().providers[0];

    await expect(refreshRelayCatalogInStore(store, canonical)).resolves.toMatchObject({ state: 'failed' });

    expect(store.getState().providers[0]).toMatchObject({
      status: { kind: 'connected' },
      models: [existingModel],
      catalogModels: [existingModel],
      lastError: PROVIDER_VALIDATION_MESSAGES.catalogUnavailable,
    });
  });

  it('legacy catalog resync preserves an enabled model that disappeared from the returned catalog', async () => {
    vi.mocked(fetch).mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: 'catalog-only' }] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
    const missingModel: Provider['models'][number] = {
      id: 'enabled-but-missing', name: 'Enabled but missing', capabilities: ['text'],
      reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
    };
    const provider: Provider = {
      id: 'relay-preserve-missing', kind: 'relay', status: { kind: 'connected' },
      models: [missingModel], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };
    const store = createAppStore();
    store.getState().addProvider(provider);

    await resyncProviderInStore(store, store.getState().providers[0]);

    expect(store.getState().providers[0].models).toContainEqual(missingModel);
    expect(store.getState().providers[0].catalogModels).toContainEqual(expect.objectContaining({ id: 'catalog-only' }));
  });

  it('persists Connected from the production 1-token request without making catalog a connection prerequisite', async () => {
    const updateProvider = vi.fn();
    const fetchMock = vi.mocked(fetch);
    fetchMock
      .mockResolvedValueOnce(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    const provider: Provider = {
      id: 'relay-verify', kind: 'relay', status: { kind: 'issue', message: 'old' },
      models: [], catalogModels: [], apiKey: 'sk-new-key', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };
    const store = { getState: () => ({ providers: [provider], updateProvider }) } as never;

    await expect(verifyRelayProviderInStore(store, provider)).resolves.toMatchObject({
      probedEndpoint: 'POST /chat/completions',
    });

    expect(fetchMock.mock.calls.map((call) => (call[1] as RequestInit).method)).toEqual(['POST']);
    expect(updateProvider).toHaveBeenLastCalledWith(provider.id, expect.objectContaining({
      status: { kind: 'connected' },
      lastError: undefined,
      lastCheckedAt: expect.any(String),
      catalogModels: [],
    }));
  });

  it('never persists an upstream echo as connection status when 1-token verification fails', async () => {
    const updateProvider = vi.fn();
    const echoedSecret = 'sk-echoed-secret';
    vi.mocked(fetch).mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: echoedSecret } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));
    const provider: Provider = {
      id: 'relay-verify-fail', kind: 'relay', status: { kind: 'connected' },
      models: [], catalogModels: [], apiKey: echoedSecret, apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };
    const store = { getState: () => ({ providers: [provider], updateProvider }) } as never;

    await expect(verifyRelayProviderInStore(store, provider)).rejects.toMatchObject({ kind: 'invalidKey' });
    const finalPatch = updateProvider.mock.calls.at(-1)?.[1] as Record<string, unknown>;
    expect(finalPatch).toMatchObject({
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.invalidKey },
      lastError: PROVIDER_VALIDATION_MESSAGES.invalidKey,
      lastCheckedAt: undefined,
    });
    expect(JSON.stringify(finalPatch)).not.toContain(echoedSecret);
  });

  it('drops a successful in-flight validation after its provider is deleted instead of resurrecting it', async () => {
    let resolveFetch: ((response: Response) => void) | undefined;
    vi.mocked(fetch).mockImplementationOnce(() => new Promise<Response>((resolve) => {
      resolveFetch = resolve;
    }));
    const provider: Provider = {
      id: 'relay-deleted-midflight', kind: 'relay', status: { kind: 'issue', message: 'old' },
      models: [], catalogModels: [], apiKey: 'sk-original-key', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };
    const store = createAppStore();
    store.getState().addProvider(provider);

    const verifying = verifyRelayProviderInStore(store, provider);
    await vi.waitFor(() => expect(resolveFetch).toBeTypeOf('function'));
    store.getState().removeProvider(provider.id);
    resolveFetch?.(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));

    await expect(verifying).resolves.toBeNull();
    expect(store.getState().providers).toEqual([]);
    expect(mocks.didUpdateProvider).not.toHaveBeenCalled();
  });

  it('drops a failed in-flight validation after a second production key rotation', async () => {
    let resolveFetch: ((response: Response) => void) | undefined;
    vi.mocked(fetch).mockImplementationOnce(() => new Promise<Response>((resolve) => {
      resolveFetch = resolve;
    }));
    const provider: Provider = {
      id: 'relay-rotated-midflight', kind: 'relay', status: { kind: 'connected' },
      models: [], catalogModels: [], apiKey: 'sk-original-key', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };
    const store = createAppStore();
    store.getState().addProvider(provider);

    const verifying = verifyRelayProviderInStore(store, provider);
    await vi.waitFor(() => expect(resolveFetch).toBeTypeOf('function'));
    await updateProviderKey(store, store.getState().providers[0], 'sk-second-key');
    resolveFetch?.(new Response(JSON.stringify({ error: { message: 'old key rejected' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));

    await expect(verifying).resolves.toBeNull();
    expect(store.getState().providers[0]).toMatchObject({
      apiKey: 'sk-second-key',
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
    });
    expect(mocks.didUpdateProvider).toHaveBeenCalledTimes(1);
    expect(mocks.didUpdateProvider).toHaveBeenCalledWith(expect.objectContaining({ apiKey: 'sk-second-key' }));
    expect(JSON.stringify(mocks.didUpdateProvider.mock.calls)).not.toContain('sk-original-key');
  });

  it('does not spend a key when the provider entity has already been removed', async () => {
    const provider: Provider = {
      id: 'relay-missing-before-start', kind: 'relay', status: { kind: 'issue', message: 'old' },
      models: [], catalogModels: [], apiKey: 'sk-never-send', apiKeyPreview: '••••',
      baseURLText: 'https://relay.example/v1', relayKind: 'openai_compatible',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };

    await expect(verifyRelayProviderInStore(createAppStore(), provider)).resolves.toBeNull();
    expect(fetch).not.toHaveBeenCalled();
    expect(mocks.didUpdateProvider).not.toHaveBeenCalled();
  });

  it('preserves existing official models and stays available when metadata snapshot is unavailable', async () => {
    const updateProvider = vi.fn();
    const provider: Provider = {
      id: 'official-1',
      kind: 'openRouter',
      status: { kind: 'connected' },
      models: [
        {
          id: 'openai/gpt-4o',
          name: 'GPT-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
          groupKey: 'openai',
          groupName: 'OpenAI',
        },
      ],
      catalogModels: [],
      apiKey: 'sk-test',
      apiKeyPreview: 'sk-...',
      baseURLText: undefined,
      lastCheckedAt: undefined,
      lastError: undefined,
    };

    const store = {
      getState: () => ({
        updateProvider,
      }),
    } as never;

    await resyncProviderInStore(store, provider);

    expect(mocks.buildOfficialEnabledModels).not.toHaveBeenCalled();
    expect(updateProvider).toHaveBeenNthCalledWith(1, provider.id, {
      status: { kind: 'syncing' },
      lastError: undefined,
    });
    // Key validation returns valid: stays connected, clears lastError and keeps the existing models.
    expect(updateProvider).toHaveBeenNthCalledWith(
      2,
      provider.id,
      expect.objectContaining({
        status: { kind: 'connected' },
        lastError: undefined,
      }),
    );
    expect(mocks.didUpdateProvider).toHaveBeenCalledWith(
      expect.objectContaining({
        models: provider.models,
      }),
    );
  });

  it('writes back issue status + invalid-key error when official key validation returns invalid', async () => {
    mocks.validateOfficialProviderKey.mockResolvedValue('invalid');
    const updateProvider = vi.fn();
    const enabledModel = {
      id: 'gpt-4o',
      name: 'GPT-4o',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: true,
      priceTier: '',
    };
    mocks.getMetadataSnapshot.mockReturnValue({ providers: {} });
    mocks.buildOfficialEnabledModels.mockReturnValue({
      models: [enabledModel],
      catalogModels: [enabledModel],
    });

    const provider: Provider = {
      id: 'official-invalid',
      kind: 'openAI',
      status: { kind: 'connected' },
      models: [enabledModel],
      catalogModels: [enabledModel],
      apiKey: 'sk-bad',
      apiKeyPreview: 'sk-...',
      baseURLText: undefined,
      lastCheckedAt: undefined,
      lastError: undefined,
    };

    const store = { getState: () => ({ updateProvider }) } as never;

    await resyncProviderInStore(store, provider);

    // invalid: issue with the invalid_key copy, and lastError carries the same copy.
    expect(updateProvider).toHaveBeenLastCalledWith(
      provider.id,
      expect.objectContaining({
        status: {
          kind: 'issue',
          message: 'The API key could not be validated. Check the value or generate a new key.',
        },
        lastError: 'The API key could not be validated. Check the value or generate a new key.',
      }),
    );
  });

  it('keeps provider available with soft hint when official key validation is unverified', async () => {
    mocks.validateOfficialProviderKey.mockResolvedValue('unverified');
    const updateProvider = vi.fn();
    const enabledModel = {
      id: 'gpt-4o',
      name: 'GPT-4o',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: true,
      priceTier: '',
    };
    mocks.getMetadataSnapshot.mockReturnValue({ providers: {} });
    mocks.buildOfficialEnabledModels.mockReturnValue({
      models: [enabledModel],
      catalogModels: [enabledModel],
    });

    const provider: Provider = {
      id: 'official-unverified',
      kind: 'openAI',
      status: { kind: 'connected' },
      models: [enabledModel],
      catalogModels: [enabledModel],
      apiKey: 'sk-test',
      apiKeyPreview: 'sk-...',
      baseURLText: undefined,
      lastCheckedAt: undefined,
      lastError: undefined,
    };

    const store = { getState: () => ({ updateProvider }) } as never;

    await resyncProviderInStore(store, provider);

    // unverified: stays connected (innocent until proven otherwise, still usable) with a soft
    // hint in lastError, and never drops to issue.
    expect(updateProvider).toHaveBeenLastCalledWith(
      provider.id,
      expect.objectContaining({
        status: { kind: 'connected' },
        lastError: "We couldn't verify the connection. You can retry from the provider details.",
      }),
    );
  });

  it('resyncs relay models for a public endpoint via the server-side forward proxy', async () => {
    const updateProvider = vi.fn();
    const fetchMock = vi.mocked(fetch);
    fetchMock.mockResolvedValue({
      ok: true,
      json: async () => ({
        data: [
          { id: 'gpt-4o' },
          { id: 'text-embedding-3-small' },
        ],
      }),
    } as Response);

    const provider: Provider = {
      id: 'relay-1',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [],
      apiKey: 'sk-relay',
      apiKeyPreview: 'sk-...',
      baseURLText: 'https://relay.example',
      lastCheckedAt: undefined,
      lastError: undefined,
      relayKind: 'codex_style',
      relayRequested: {
        transport: 'openai_responses',
        authMode: 'x_api_key',
        modelID: 'gpt-4o',
        codexCompatIdentity: true,
        customUserAgent: 'Oriveo Test UA',
        headers: [{ key: 'X-Test', value: '1' }],
        queryParams: [{ key: 'debug', value: 'true' }],
      },
    };

    const store = {
      getState: () => ({
        updateProvider,
      }),
    } as never;

    await resyncProviderInStore(store, provider);

    expect(mocks.syncProviderModels).not.toHaveBeenCalled();
    // Public endpoint: /api/relay/forward, with auth, custom headers and query parameters folded
    // into X-Relay-Proxy-Config and applied to the real upstream request on the Node side, which
    // is free of browser CORS and forbidden-header restrictions.
    expect(fetchMock).toHaveBeenCalledWith('/api/relay/forward', expect.objectContaining({
      method: 'GET',
      credentials: 'omit',
      headers: expect.objectContaining({
        'X-Relay-Upstream-URL': 'https://relay.example/v1/models',
        'X-Relay-Upstream-Method': 'GET',
      }),
    }));
    const headers = fetchMock.mock.calls[0][1]?.headers as Record<string, string>;
    const proxyConfig = JSON.parse(headers['X-Relay-Proxy-Config']);
    expect(proxyConfig.apiKey).toBe('sk-relay');
    expect(proxyConfig.authMode).toBe('x_api_key');
    expect(proxyConfig.headers).toEqual([{ key: 'X-Test', value: '1' }]);
    expect(proxyConfig.queryParams).toEqual([{ key: 'debug', value: 'true' }]);
    expect(proxyConfig.customUserAgent).toBe('Oriveo Test UA');
    expect(updateProvider).toHaveBeenLastCalledWith(provider.id, expect.objectContaining({
      status: { kind: 'connected' },
      catalogModels: [expect.objectContaining({ id: 'gpt-4o' })],
    }));
    expect(mocks.enrichRelayCatalog).toHaveBeenCalledWith(
      [expect.objectContaining({ id: 'gpt-4o' })],
      'openai_responses',
      { version: 'test' },
    );
  });

  it('keeps relay provider available when background model sync fails after key edit', async () => {
    const updateProvider = vi.fn();
    const fetchMock = vi.mocked(fetch);
    fetchMock.mockResolvedValue({
      ok: false,
      status: 401,
      text: async () => '{"error":{"message":"bad relay key"}}',
    } as Response);

    const manualModel: Provider['models'][number] = {
      id: 'manual-relay-model',
      name: 'Manual Relay Model',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: true,
      priceTier: '',
    };
    const provider: Provider = {
      id: 'relay-key-edit',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [manualModel],
      catalogModels: [manualModel],
      apiKey: 'sk-new-relay',
      apiKeyPreview: 'sk-...relay',
      baseURLText: 'https://relay.example',
      lastCheckedAt: '2026-05-01T00:00:00.000Z',
      lastError: undefined,
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        modelID: 'manual-relay-model',
      },
    };

    const store = {
      getState: () => ({
        updateProvider,
      }),
    } as never;

    await resyncProviderInStore(store, provider);

    expect(fetchMock).toHaveBeenCalled();
    expect(updateProvider).toHaveBeenLastCalledWith(provider.id, expect.objectContaining({
      status: { kind: 'connected' },
      lastError: undefined,
    }));
    expect(mocks.didUpdateProvider).toHaveBeenLastCalledWith(expect.objectContaining({
      apiKey: 'sk-new-relay',
      apiKeyPreview: 'sk-...relay',
      models: [manualModel],
    }));
  });

  it('keeps manual relay models for non OpenAI transports instead of probing /models', async () => {
    const updateProvider = vi.fn();
    const fetchMock = vi.mocked(fetch);
    const manualModel: Provider['models'][number] = {
      id: 'claude-sonnet-4.5',
      name: 'Claude Sonnet 4.5',
      capabilities: ['text', 'image', 'file'],
      reasoningModeAvailable: true,
      isAvailable: true,
      isDefault: true,
      priceTier: '',
    };
    const provider: Provider = {
      id: 'relay-anthropic',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [manualModel],
      catalogModels: [manualModel],
      apiKey: 'sk-relay',
      apiKeyPreview: 'sk-...',
      baseURLText: 'https://relay.example',
      lastCheckedAt: undefined,
      lastError: undefined,
      relayRequested: {
        transport: 'anthropic_messages',
        authMode: 'x_api_key',
        modelID: 'claude-sonnet-4.5',
      },
    };

    const store = {
      getState: () => ({
        updateProvider,
      }),
    } as never;

    await resyncProviderInStore(store, provider);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(mocks.syncProviderModels).not.toHaveBeenCalled();
    expect(updateProvider).toHaveBeenLastCalledWith(provider.id, expect.objectContaining({
      status: { kind: 'connected' },
      models: [manualModel],
      catalogModels: [manualModel],
      lastError: undefined,
    }));
  });

  // Regression: local engine catalog sync must use the measured API root and carry securityMode,
  // or the default remote_https rejects http://192.168.x.x:1234 outright and the request never
  // leaves the client.
  it('resyncs a local engine relay against the probed API root over cleartext LAN', async () => {
    const updateProvider = vi.fn();
    const fetchMock = vi.mocked(fetch);
    fetchMock.mockResolvedValue({
      ok: true,
      json: async () => ({ data: [{ id: 'qwen/qwen3-0.6b' }] }),
    } as Response);

    const provider: Provider = {
      id: 'relay-local-engine',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [],
      apiKey: '',
      apiKeyPreview: '',
      baseURLText: 'http://192.168.31.250:1234',
      lastCheckedAt: undefined,
      lastError: undefined,
      relayKind: 'openai_compatible',
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'none',
        securityMode: 'local_http',
        engineProfile: 'lmstudio',
        resolvedAPIBaseURL: 'http://192.168.31.250:1234/v1',
      },
    };

    const store = { getState: () => ({ updateProvider }) } as never;

    await resyncProviderInStore(store, provider);

    // Connects directly to the measured root (no second /v1, no /api/relay/forward proxy), and
    // sends no auth header when the key is empty.
    expect(fetchMock).toHaveBeenCalledWith(
      'http://192.168.31.250:1234/v1/models',
      expect.objectContaining({ method: 'GET', credentials: 'omit' }),
    );
    const headers = fetchMock.mock.calls[0][1]?.headers as Record<string, string>;
    expect(headers.Authorization).toBeUndefined();
    expect(headers['X-Relay-Proxy-Config']).toBeUndefined();
    expect(updateProvider).toHaveBeenLastCalledWith(provider.id, expect.objectContaining({
      status: { kind: 'connected' },
      catalogModels: [expect.objectContaining({ id: 'qwen/qwen3-0.6b' })],
    }));
  });

    // Anchor: a cloud relay (no engineProfile) still rejects a plaintext endpoint under
    // remote_https; the local engine exemption must not widen the public-network boundary.
  it('still refuses a cleartext endpoint for a cloud relay without an engine profile', async () => {
    const updateProvider = vi.fn();
    const fetchMock = vi.mocked(fetch);

    const provider: Provider = {
      id: 'relay-cleartext-cloud',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [],
      apiKey: 'sk-relay',
      apiKeyPreview: 'sk-...',
      baseURLText: 'http://relay.example',
      lastCheckedAt: undefined,
      lastError: undefined,
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    };

    const store = { getState: () => ({ updateProvider }) } as never;

    await resyncProviderInStore(store, provider);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(updateProvider).toHaveBeenLastCalledWith(provider.id, expect.objectContaining({
      status: expect.objectContaining({ kind: 'issue' }),
    }));
  });
});
