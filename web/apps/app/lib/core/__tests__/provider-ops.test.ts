import 'fake-indexeddb/auto';
import { afterEach, describe, it, expect, beforeEach, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';
import {
  addProvider,
  beginRelaySecurityModeReconnect,
  clearRelayCredentials,
  finishRelaySecurityModeReconnect,
  updateProviderKey,
  updateProviderBaseURL,
  updateProviderName,
  updateProviderRelaySettings,
  deleteProvider,
  switchProviderToApiKeyMode,
} from '../provider-ops';
import { relayProviderCredentialState } from '../providers/relay-runtime-support';
import { PROVIDER_VALIDATION_MESSAGES } from '../providers/validation-messages';
import { probeRelayEndpoint } from '../providers/probe/probe-runner';
import {
  exportGenerationParameterSyncPayload,
  saveConnectionGenerationParameterDefaults,
  saveGenerationParameterOverrides,
  saveGenerationParameterPreset,
  valueOverride,
} from '../chat/generation-parameter-settings';
import { createProviderSelectionSnapshot } from '../providers/provider-selection-snapshot';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  readCapabilityEvidenceIdentity,
} from '../providers/capability-evidence-identity';
import {
  capabilityRejectionIsDormant,
  recordCapabilityRejection,
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
} from '../chat/capability-recovery-runtime';

const mockSyncAdapter = {
  boundUID: 'user-1',
  didUpdateProvider: vi.fn(),
};

const telemetryMocks = vi.hoisted(() => ({ trackEvent: vi.fn() }));

const deletionMocks = vi.hoisted(() => ({
  deleteStoredProvider: vi.fn(async (..._args: unknown[]) => {}),
  deleteProviderFromPartition: vi.fn(async (..._args: unknown[]) => {}),
  deleteAndEnqueue: vi.fn(async (..._args: unknown[]) => {}),
  putProvider: vi.fn(async (..._args: unknown[]) => {}),
  putProviderIfCurrent: vi.fn(async (..._args: unknown[]) => true),
  putAndCancel: vi.fn(async (..._args: unknown[]) => {}),
  putAndCancelIfCurrent: vi.fn(async (..._args: unknown[]) => true),
  flush: vi.fn(async (..._args: unknown[]) => {}),
  register: vi.fn((..._args: unknown[]) => {}),
  unregister: vi.fn((..._args: unknown[]) => {}),
  activeUID: 'user-1',
}));

vi.mock('../sync-port', () => ({
  getSyncAdapter: vi.fn(() => mockSyncAdapter),
  flushPendingProviderDeletions: (...args: unknown[]) => deletionMocks.flush(...args),
  registerPendingProviderDeletion: (...args: unknown[]) => deletionMocks.register(...args),
  unregisterPendingProviderDeletion: (...args: unknown[]) => deletionMocks.unregister(...args),
}));

vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn() }));

vi.mock('../telemetry', () => ({
  trackEvent: (...args: unknown[]) => telemetryMocks.trackEvent(...args),
  telemetryProviderKind: (kind: string) => kind,
  // provider_added also reports which address was connected, redacted the same way as the failure path.
  telemetryEndpointHost: (raw: string | null | undefined) =>
    raw ? raw.replace(/^https?:\/\//, '').split('/')[0] : '',
}));

vi.mock('../../infra/storage/idb', () => ({
  deleteProvider: (...args: unknown[]) => deletionMocks.deleteStoredProvider(...args),
  deleteProviderFromPartition: (...args: unknown[]) => deletionMocks.deleteProviderFromPartition(...args),
  deleteProviderAndEnqueuePendingDeletion: (...args: unknown[]) => deletionMocks.deleteAndEnqueue(...args),
  putProvider: (...args: unknown[]) => deletionMocks.putProvider(...args),
  putProviderIfCurrent: (...args: unknown[]) => deletionMocks.putProviderIfCurrent(...args),
  putProviderAndCancelPendingDeletion: (...args: unknown[]) => deletionMocks.putAndCancel(...args),
  putProviderAndCancelPendingDeletionIfCurrent: (...args: unknown[]) => deletionMocks.putAndCancelIfCurrent(...args),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUIDSync: () => deletionMocks.activeUID,
}));

const baseProvider: Provider = {
  id: 'p1', kind: 'openRouter', name: 'OpenRouter',
  apiKey: 'sk-old', apiKeyPreview: 'sk-...old',
  status: { kind: 'connected' },
  models: [], catalogModels: [],
  createdAt: '', updatedAt: '',
};

describe('provider-ops', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    vi.clearAllMocks();
    localStorage.clear();
    deletionMocks.activeUID = 'user-1';
    mockSyncAdapter.boundUID = 'user-1';
    deletionMocks.deleteStoredProvider.mockResolvedValue(undefined);
    deletionMocks.deleteProviderFromPartition.mockResolvedValue(undefined);
    deletionMocks.deleteAndEnqueue.mockResolvedValue(undefined);
    deletionMocks.putProvider.mockResolvedValue(undefined);
    deletionMocks.putProviderIfCurrent.mockResolvedValue(true);
    deletionMocks.putAndCancel.mockResolvedValue(undefined);
    deletionMocks.putAndCancelIfCurrent.mockResolvedValue(true);
  });

  it('addProvider — store.addProvider + sync.didUpdateProvider', async () => {
    await addProvider(store, baseProvider);
    expect(store.getState().providers).toHaveLength(1);
    expect(store.getState().providers[0].id).toBe('p1');
    expect(deletionMocks.putAndCancel).toHaveBeenCalledWith(baseProvider, 'user-1');
    expect(deletionMocks.unregister).toHaveBeenCalledWith('user-1', 'p1');
    expect(mockSyncAdapter.didUpdateProvider).toHaveBeenCalledWith(baseProvider);
    expect(readCapabilityEvidenceIdentity('user-1', 'p1')).not.toBeNull();
    expect(mockSyncAdapter.didUpdateProvider.mock.calls[0]?.[0]).not.toHaveProperty('connectionGeneration');
    expect(mockSyncAdapter.didUpdateProvider.mock.calls[0]?.[0]).not.toHaveProperty('credentialEpoch');
    // An official provider has no custom address, so the field is reported as an empty string rather than
    // a placeholder; a catalog model is not manually entered.
    expect(telemetryMocks.trackEvent).toHaveBeenCalledWith('provider_added', expect.objectContaining({
      provider_kind: 'openRouter', endpoint_host: '', is_manual_model: false,
    }));
  });

  it('relay provider_added reports the same address the send path uses, and reports a manually entered model as true', async () => {
    await addProvider(store, {
      ...baseProvider,
      id: 'p-relay', kind: 'relay', relayKind: 'openai_compatible',
      // When the shorthand the user typed and the probe's resolved result have different hosts, telemetry
      // must report the same one the send path uses.
      baseURLText: 'relay.example.com',
      relayResolvedBaseURLText: 'https://api.relay.example.com/v1',
      models: [{
        id: 'my-model', name: 'my-model', capabilities: ['text'],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
        isManual: true,
      }],
    });
    expect(telemetryMocks.trackEvent).toHaveBeenCalledWith('provider_added', expect.objectContaining({
      provider_kind: 'relay',
      relay_kind: 'openai_compatible',
      endpoint_host: 'api.relay.example.com',
      is_manual_model: true,
      model_count: 1,
    }));
  });

  it('a cancellable create that expires during deferred persistence writes neither store nor sync', async () => {
    let current = true;
    let releasePersistence: (() => void) | undefined;
    deletionMocks.putAndCancelIfCurrent.mockImplementationOnce(async (
      _provider: unknown,
      _uid: unknown,
      shouldCommit: unknown,
    ) => {
      await new Promise<void>((resolve) => { releasePersistence = resolve; });
      return (shouldCommit as () => boolean)();
    });

    const adding = addProvider(store, baseProvider, { shouldCommit: () => current });
    await vi.waitFor(() => expect(releasePersistence).toBeTypeOf('function'));
    current = false;
    releasePersistence?.();

    await expect(adding).resolves.toBe(false);
    expect(store.getState().providers).toHaveLength(0);
    expect(deletionMocks.unregister).not.toHaveBeenCalled();
    expect(mockSyncAdapter.didUpdateProvider).not.toHaveBeenCalled();
    expect(telemetryMocks.trackEvent).not.toHaveBeenCalled();
  });

  it('a signed-in guarded add returns false and writes no store or sync when the UID changes while persistence is pending', async () => {
    let releasePersistence: (() => void) | undefined;
    deletionMocks.putAndCancelIfCurrent.mockImplementationOnce(async (
      _provider: unknown,
      _uid: unknown,
      shouldCommit: unknown,
    ) => {
      await new Promise<void>((resolve) => { releasePersistence = resolve; });
      return (shouldCommit as () => boolean)();
    });

    const adding = addProvider(store, baseProvider, { shouldCommit: () => true });
    await vi.waitFor(() => expect(releasePersistence).toBeTypeOf('function'));
    deletionMocks.activeUID = 'user-2';
    releasePersistence?.();

    await expect(adding).resolves.toBe(false);
    expect(store.getState().providers).toHaveLength(0);
    expect(deletionMocks.unregister).not.toHaveBeenCalled();
    expect(mockSyncAdapter.didUpdateProvider).not.toHaveBeenCalled();
    expect(telemetryMocks.trackEvent).not.toHaveBeenCalled();
  });

  it('a guest guarded add returns false and writes no store when the UID changes while persistence is pending', async () => {
    deletionMocks.activeUID = 'guest';
    let releasePersistence: (() => void) | undefined;
    deletionMocks.putProviderIfCurrent.mockImplementationOnce(async (
      _provider: unknown,
      _uid: unknown,
      shouldCommit: unknown,
    ) => {
      await new Promise<void>((resolve) => { releasePersistence = resolve; });
      return (shouldCommit as () => boolean)();
    });

    const adding = addProvider(store, baseProvider, { shouldCommit: () => true });
    await vi.waitFor(() => expect(releasePersistence).toBeTypeOf('function'));
    deletionMocks.activeUID = 'user-2';
    releasePersistence?.();

    await expect(adding).resolves.toBe(false);
    expect(store.getState().providers).toHaveLength(0);
    expect(mockSyncAdapter.didUpdateProvider).not.toHaveBeenCalled();
    expect(telemetryMocks.trackEvent).not.toHaveBeenCalled();
  });

  it('updateProviderKey — updates apiKey, apiKeyPreview and sync', async () => {
    store.getState().addProvider(baseProvider);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', baseProvider.id)!;
    await updateProviderKey(store, baseProvider, 'sk-new-key');
    const p = store.getState().providers[0];
    expect(p.apiKey).toBe('sk-new-key');
    expect(p.apiKeyPreview).toBeTruthy();
    expect(mockSyncAdapter.didUpdateProvider).toHaveBeenCalled();
    const identityAfter = readCapabilityEvidenceIdentity('user-1', baseProvider.id)!;
    expect(identityAfter.connectionGeneration).toBe(identityBefore.connectionGeneration);
    expect(identityAfter.credentialEpoch).not.toBe(identityBefore.credentialEpoch);
  });

  it('relay key rotation immediately clears old Connected evidence before verification starts', async () => {
    const relay: Provider = {
      ...baseProvider,
      id: 'relay-key-rotation',
      kind: 'relay',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
      lastCheckedAt: '2026-08-08T00:00:00.000Z',
    };
    store.getState().addProvider(relay);

    await updateProviderKey(store, relay, 'sk-new-key');

    expect(store.getState().providers[0]).toMatchObject({
      apiKey: 'sk-new-key',
      status: { kind: 'issue', message: "We couldn't verify the connection. You can retry from the provider details." },
      lastCheckedAt: undefined,
    });
  });

  // ── Credential state machine T3 / T4 / T2 ──────────────────────────
  // The assertions consume objects produced by the production path: the provider in the store is written
  // by provider-ops and its state is derived from that object by the production
  // relayProviderCredentialState. The test never fabricates a provider shape.

  const relayProvider: Provider = {
    ...baseProvider,
    id: 'relay-1',
    kind: 'relay',
    apiKey: 'sk-relay-secret-0123456789',
    apiKeyPreview: 'sk-r...6789',
    baseURLText: 'http://192.168.1.20:1234/v1',
    relayKind: 'openai_compatible',
    relayRequested: {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      stream: true,
      securityMode: 'local_http',
      headers: [{ key: 'X-Api-Token', value: 'secret' }],
    },
    relayResolvedAuthMode: 'bearer',
  };

  it('T3 removing the key only falls back to S1 and leaves authMode unchanged', async () => {
    store.getState().addProvider(relayProvider);
    await updateProviderKey(store, relayProvider, '');
    const saved = store.getState().providers[0];
    expect(saved.apiKey).toBe('');
    // masked('') must be an empty string: never draw mask dots for a key that does not exist.
    expect(saved.apiKeyPreview).toBe('');
    expect(saved.relayRequested?.authMode).toBe('bearer');
    expect(saved.relayResolvedAuthMode).toBe('bearer');
  });

  it('T4 when authMode drops to none, one write removes both the key and the sensitive headers', async () => {
    store.getState().addProvider(relayProvider);
    await updateProviderRelaySettings(store, relayProvider, {
      relayKind: 'openai_compatible',
      relayRequested: { ...relayProvider.relayRequested!, authMode: 'none' },
    });
    const saved = store.getState().providers[0];
    expect(saved.apiKey).toBe('');
    expect(saved.apiKeyPreview).toBe('');
    expect(saved.relayRequested?.headers).toBeUndefined();
    expect(saved.relayRequested?.queryParams).toBeUndefined();
    expect(saved.relayResolvedAuthMode).toBe('none');
    // The synced copy must not still carry the key that was just deleted, or the cloud would push it back.
    const synced = mockSyncAdapter.didUpdateProvider.mock.calls.at(-1)?.[0] as Provider;
    expect(synced.apiKey).toBe('');
    // Cleartext connection with no credentials is S0, not the S3 blocked state.
    expect(relayProviderCredentialState(saved)).toBe('not_required');
  });

  it('T4 does not touch credentials when it is not triggered, since authMode still requires a key', async () => {
    store.getState().addProvider(relayProvider);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', relayProvider.id)!;
    await updateProviderRelaySettings(store, relayProvider, {
      relayKind: 'openai_compatible',
      relayRequested: { ...relayProvider.relayRequested!, transport: 'openai_responses' },
    });
    const saved = store.getState().providers[0];
    expect(saved.apiKey).toBe('sk-relay-secret-0123456789');
    expect(saved.relayRequested?.transport).toBe('openai_responses');
    const identityAfter = readCapabilityEvidenceIdentity('user-1', relayProvider.id)!;
    expect(identityAfter.connectionGeneration).not.toBe(identityBefore.connectionGeneration);
  });

  it('T2 clearing credentials removes authMode, key and headers in a single write', async () => {
    store.getState().addProvider(relayProvider);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', relayProvider.id)!;
    // The starting point really is the blocked state (a cleartext connection carrying credentials);
    // otherwise this case proves nothing.
    expect(relayProviderCredentialState(store.getState().providers[0])).toBe('conflict');
    await clearRelayCredentials(store, relayProvider);
    const saved = store.getState().providers[0];
    expect(saved.apiKey).toBe('');
    expect(saved.apiKeyPreview).toBe('');
    expect(saved.relayRequested?.authMode).toBe('none');
    expect(saved.relayRequested?.headers).toBeUndefined();
    expect(relayProviderCredentialState(saved)).toBe('not_required');
    const identityAfter = readCapabilityEvidenceIdentity('user-1', relayProvider.id)!;
    expect(identityAfter.connectionGeneration).not.toBe(identityBefore.connectionGeneration);
    expect(identityAfter.credentialEpoch).not.toBe(identityBefore.credentialEpoch);
  });

  it('switching to cleartext atomically clears credentials, drops the stale resolved root and flags an issue', async () => {
    const remote = {
      ...relayProvider,
      baseURLText: 'https://relay.example.com/v1',
      relayRequested: {
        ...relayProvider.relayRequested!,
        transport: 'anthropic_messages' as const,
        securityMode: 'remote_https' as const,
        resolvedAPIBaseURL: 'https://relay.example.com/v1',
        queryParams: [{ key: 'token', value: 'secret' }],
      },
      relayResolvedBaseURLText: 'https://relay.example.com/v1',
      relayResolvedTransport: 'anthropic_messages' as const,
      relayResolvedAuthMode: 'bearer' as const,
      relayResolvedHeaderProfile: 'anthropic_v2023_06_01' as const,
      relayResolvedFamilyHint: 'anthropic' as const,
      relayProbeVersion: 7,
      relayCapabilityBitmap: {
        modelsList: true,
        responses: false,
        chatCompletions: false,
        messages: true,
        geminiGenerateContent: false,
      },
      relayLastProbeAt: '2026-08-08T00:00:00.000Z',
      relayLastProbeErrorClass: 'rate_limited' as const,
      relayFingerprintKey: 'old-fingerprint',
      lastCheckedAt: '2026-08-08T00:00:00.000Z',
      models: [{
        id: 'old-model', name: 'old-model', capabilities: ['text' as const],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
      }],
      catalogModels: [{
        id: 'old-model', name: 'old-model', capabilities: ['text' as const],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
      }],
    };
    store.getState().addProvider(remote);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', remote.id)!;

    const pending = await beginRelaySecurityModeReconnect(store, remote, {
      securityMode: 'local_http',
      normalizedEndpoint: 'http://192.168.1.20:8080/v1',
      unverifiedMessage: 'Connection has not been verified.',
    });
    const saved = store.getState().providers[0];
    expect(saved).toMatchObject({
      baseURLText: 'http://192.168.1.20:8080/v1',
      apiKey: '',
      apiKeyPreview: '',
      status: { kind: 'issue', message: 'Connection has not been verified.' },
      relayResolvedBaseURLText: undefined,
      relayResolvedTransport: undefined,
      relayResolvedAuthMode: undefined,
      relayResolvedHeaderProfile: undefined,
      relayResolvedFamilyHint: undefined,
      relayProbeVersion: undefined,
      relayCapabilityBitmap: undefined,
      relayLastProbeAt: undefined,
      relayLastProbeErrorClass: undefined,
      relayFingerprintKey: undefined,
      lastCheckedAt: undefined,
      models: remote.models,
      catalogModels: [],
      relayRequested: {
        transport: 'anthropic_messages',
        securityMode: 'local_http',
        authMode: 'none',
        resolvedAPIBaseURL: undefined,
        headers: undefined,
        queryParams: undefined,
      },
    });
    expect(pending).toEqual(saved);
    expect(relayProviderCredentialState(saved)).toBe('not_required');
    const identityAfter = readCapabilityEvidenceIdentity('user-1', remote.id)!;
    expect(identityAfter.connectionGeneration).not.toBe(identityBefore.connectionGeneration);
    expect(identityAfter.credentialEpoch).not.toBe(identityBefore.credentialEpoch);
  });

  it('ordinary KV pairs under auth=none are not credential material and survive a switch to cleartext', async () => {
    const noCredential = {
      ...relayProvider,
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: {
        ...relayProvider.relayRequested!,
        authMode: 'none' as const,
        securityMode: 'remote_https' as const,
        headers: [{ key: 'X-Tenant', value: 'alpha' }],
        queryParams: [{ key: 'region', value: 'local' }],
      },
      relayResolvedAuthMode: 'none' as const,
    };
    store.getState().addProvider(noCredential);

    await beginRelaySecurityModeReconnect(store, noCredential, {
      securityMode: 'local_http',
      normalizedEndpoint: 'http://192.168.1.20:8080/v1',
      unverifiedMessage: 'Connection has not been verified.',
    });

    expect(store.getState().providers[0].relayRequested).toMatchObject({
      authMode: 'none',
      headers: [{ key: 'X-Tenant', value: 'alpha' }],
      queryParams: [{ key: 'region', value: 'local' }],
    });
  });

  it('a single sensitive KV hit clears the entire header and query table when switching to cleartext', async () => {
    const sensitive = {
      ...relayProvider,
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: {
        ...relayProvider.relayRequested!,
        authMode: 'none' as const,
        securityMode: 'remote_https' as const,
        headers: [
          { key: 'X-Tenant', value: 'alpha' },
          { key: 'X-Internal-Token', value: 'secret' },
        ],
        queryParams: [{ key: 'region', value: 'local' }],
      },
      relayResolvedAuthMode: 'none' as const,
    };
    store.getState().addProvider(sensitive);

    await beginRelaySecurityModeReconnect(store, sensitive, {
      securityMode: 'private_vpn',
      normalizedEndpoint: 'http://100.101.102.103:8080/v1',
      unverifiedMessage: 'Connection has not been verified.',
    });

    expect(store.getState().providers[0].relayRequested).toMatchObject({ authMode: 'none' });
    expect(store.getState().providers[0].relayRequested?.headers).toBeUndefined();
    expect(store.getState().providers[0].relayRequested?.queryParams).toBeUndefined();
  });

  it('only a production probe with a verified shape can complete a mode reconnect and refresh the resolved root and catalog', async () => {
    const pending = {
      ...relayProvider,
      apiKey: '',
      apiKeyPreview: '',
      baseURLText: 'http://192.168.1.20:8080/v1',
      relayRequested: {
        ...relayProvider.relayRequested!,
        authMode: 'none' as const,
        securityMode: 'local_http' as const,
        resolvedAPIBaseURL: undefined,
        headers: undefined,
        queryParams: undefined,
      },
      status: { kind: 'issue', message: 'Connection has not been verified.' } as const,
    };
    store.getState().addProvider(pending);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', pending.id)!;
    const pendingInStore = await beginRelaySecurityModeReconnect(store, pending, {
      securityMode: 'local_http',
      normalizedEndpoint: 'http://192.168.1.20:8080/v1',
      unverifiedMessage: 'Connection has not been verified.',
    });
    expect(pendingInStore).not.toBeNull();
    const catalogModel = {
      id: 'local-model',
      name: 'local-model',
      capabilities: ['text' as const],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
    };

    finishRelaySecurityModeReconnect(store, pendingInStore!, {
      transport: 'openai_chat_completions',
      authMode: 'none',
      apiBaseURL: 'http://192.168.1.20:8080/v1',
      modelIDs: ['local-model'],
      catalogModels: [catalogModel],
      generationVerified: true,
      catalogEvidenceSucceeded: true,
      detectionEvidence: 'catalog',
    });

    expect(store.getState().providers[0]).toMatchObject({
      status: { kind: 'connected' },
      relayResolvedBaseURLText: 'http://192.168.1.20:8080/v1',
      relayResolvedTransport: 'openai_chat_completions',
      relayResolvedAuthMode: 'none',
      relayRequested: { resolvedAPIBaseURL: 'http://192.168.1.20:8080/v1' },
      catalogModels: [{ id: 'local-model' }],
      models: [{ id: 'local-model', isDefault: true }],
    });
    const identityAfter = readCapabilityEvidenceIdentity('user-1', pending.id)!;
    expect(identityAfter.connectionGeneration).not.toBe(identityBefore.connectionGeneration);
    expect(identityAfter.credentialEpoch).toBe(identityBefore.credentialEpoch);
  });

  it('a stale-generation probe cannot overwrite any provider write made after begin', async () => {
    store.getState().addProvider(relayProvider);
    const pending = await beginRelaySecurityModeReconnect(store, relayProvider, {
      securityMode: 'remote_https',
      normalizedEndpoint: 'https://new.example/v1',
      unverifiedMessage: 'Connection has not been verified.',
    });
    expect(pending).not.toBeNull();
    store.getState().updateProvider(relayProvider.id, { customName: 'newer user edit' });

    const committed = finishRelaySecurityModeReconnect(store, pending!, {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      apiBaseURL: 'https://stale.example/v1',
      modelIDs: [],
      catalogModels: [],
      generationVerified: true,
      catalogEvidenceSucceeded: false,
      detectionEvidence: 'generation_probe',
    });

    expect(committed).toBeNull();
    expect(store.getState().providers[0]).toMatchObject({
      customName: 'newer user edit',
      status: { kind: 'issue' },
      relayResolvedBaseURLText: undefined,
      catalogModels: [],
    });
  });

  it('when the UID changes from A to B before a relay probe returns, finish writes no store and does not advance the same-ID identity for B', async () => {
    store.getState().addProvider(relayProvider);
    const pending = await beginRelaySecurityModeReconnect(store, relayProvider, {
      securityMode: 'remote_https',
      normalizedEndpoint: 'https://relay.example/v1',
      unverifiedMessage: PROVIDER_VALIDATION_MESSAGES.unverified,
    });
    expect(pending).not.toBeNull();
    const identityA = readCapabilityEvidenceIdentity('user-1', relayProvider.id)!;
    const identityB = beginCapabilityEvidenceIdentityIfAbsent('user-2', relayProvider.id)!;

    deletionMocks.activeUID = 'user-2';
    const result = finishRelaySecurityModeReconnect(store, pending!, {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      apiBaseURL: 'https://relay.example/v1',
      modelIDs: ['remote-model'],
      catalogModels: [{
        id: 'remote-model', name: 'remote-model', capabilities: ['text'],
        reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
      }],
      catalogEvidenceSucceeded: true,
      generationVerified: true,
      detectionEvidence: 'catalog',
    });

    expect(result).toBeNull();
    expect(store.getState().providers[0]).toBe(pending);
    expect(readCapabilityEvidenceIdentity('user-1', relayProvider.id)).toEqual(identityA);
    expect(readCapabilityEvidenceIdentity('user-2', relayProvider.id)).toEqual(identityB);
  });

  it('when the catalog fails entirely but user models can still be generated, a mode reconnect stays connected and keeps enabled models', async () => {
    const oldModel = {
      id: 'old-model', name: 'old-model', capabilities: ['text' as const],
      reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
    };
    const current = {
      ...relayProvider,
      baseURLText: 'https://old-relay.local/v1',
      models: [oldModel],
      catalogModels: [oldModel],
      relayRequested: {
        ...relayProvider.relayRequested!,
        securityMode: 'remote_https' as const,
        modelID: 'user-model',
      },
    };
    store.getState().addProvider(current);
    const pending = await beginRelaySecurityModeReconnect(store, current, {
      securityMode: 'remote_https',
      normalizedEndpoint: 'https://relay.local/v1/chat/completions',
      unverifiedMessage: 'Connection has not been verified.',
    });
    expect(pending).not.toBeNull();
    expect(pending).toMatchObject({ status: { kind: 'issue' }, models: [oldModel], catalogModels: [] });

    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('/models')) return new Response('missing', { status: 404 });
      if (url.endsWith('/chat/completions')) {
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        });
      }
      return new Response('missing', { status: 404 });
    });
    const result = await probeRelayEndpoint({
      endpoint: 'https://relay.local/v1/chat/completions',
      apiKey: pending!.apiKey,
      modelHint: 'user-model',
      forcedTransport: 'openai_chat_completions',
      securityMode: 'remote_https',
      retryBackoffMs: [],
    });

    expect(result).toMatchObject({
      state: 'verified',
      detection: {
        generationVerified: true,
        catalogEvidenceSucceeded: false,
        detectionEvidence: 'generation_probe',
      },
    });
    expect(finishRelaySecurityModeReconnect(store, pending!, result.detection!)).toMatchObject({
      status: { kind: 'connected' },
      relayCapabilityBitmap: {
        modelsList: false,
        responses: false,
        chatCompletions: true,
        messages: false,
        geminiGenerateContent: false,
      },
    });
    expect(store.getState().providers[0]).toMatchObject({
      status: { kind: 'connected' },
      models: [oldModel],
      catalogModels: [],
      relayResolvedBaseURLText: 'https://relay.local/v1',
    });
  });







  it('updateProviderBaseURL — trim + sync', () => {
    store.getState().addProvider(baseProvider);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', baseProvider.id)!;
    updateProviderBaseURL(store, baseProvider, '  https://api.example.com  ');
    const p = store.getState().providers[0];
    expect(p.baseURLText).toBe('https://api.example.com');
    expect(mockSyncAdapter.didUpdateProvider).toHaveBeenCalled();
    const identityAfter = readCapabilityEvidenceIdentity('user-1', baseProvider.id)!;
    expect(identityAfter.connectionGeneration).not.toBe(identityBefore.connectionGeneration);
    expect(identityAfter.credentialEpoch).toBe(identityBefore.credentialEpoch);
  });

  it('relay header and query writes only advance the credential epoch and never derive identity from credential values', async () => {
    const relay = { ...relayProvider, id: 'relay-kv-write' };
    store.getState().addProvider(relay);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', relay.id)!;

    await updateProviderRelaySettings(store, relay, {
      relayKind: relay.relayKind!,
      relayRequested: {
        ...relay.relayRequested!,
        headers: [{ key: 'Authorization', value: 'top-secret-that-must-not-be-an-epoch' }],
        queryParams: undefined,
      },
    });

    const identityAfter = readCapabilityEvidenceIdentity('user-1', relay.id)!;
    expect(identityAfter.connectionGeneration).toBe(identityBefore.connectionGeneration);
    expect(identityAfter.credentialEpoch).not.toBe(identityBefore.credentialEpoch);
    expect(identityAfter.credentialEpoch).not.toContain('top-secret');
    expect(localStorage.getItem('oriveo.capability-evidence-identity.v1')).not.toContain('top-secret');
  });

  it('unchanged relay headers and queries, and an undefined to [] serialization change, do not advance the credential epoch', async () => {
    const relay = { ...relayProvider, id: 'relay-kv-noop' };
    store.getState().addProvider(relay);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', relay.id)!;

    await updateProviderRelaySettings(store, relay, {
      relayKind: relay.relayKind!,
      relayRequested: {
        ...relay.relayRequested!,
        headers: relay.relayRequested?.headers?.map((item) => ({ ...item })),
        queryParams: [],
      },
    });

    expect(readCapabilityEvidenceIdentity('user-1', relay.id)).toEqual(identityBefore);
  });

  it('repeated cleanup on a relay with no credentials left does not advance any identity generation', async () => {
    const relay: Provider = {
      ...relayProvider,
      id: 'relay-clear-noop',
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: {
        ...relayProvider.relayRequested!,
        authMode: 'none',
        headers: undefined,
        queryParams: undefined,
      },
      relayResolvedAuthMode: 'none',
    };
    store.getState().addProvider(relay);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', relay.id)!;

    await clearRelayCredentials(store, relay);

    expect(readCapabilityEvidenceIdentity('user-1', relay.id)).toEqual(identityBefore);
  });

  it('updateProviderName — trim + sync', () => {
    store.getState().addProvider(baseProvider);
    updateProviderName(store, baseProvider, '  My Provider  ');
    const p = store.getState().providers[0];
    expect(p.customName).toBe('My Provider');
    expect(mockSyncAdapter.didUpdateProvider).toHaveBeenCalled();
  });

  it('deleteProvider — removes from the store only after the atomic IDB delete and enqueue complete, then replays immediately', async () => {
    store.getState().addProvider(baseProvider);
    const identityBefore = beginCapabilityEvidenceIdentityIfAbsent('user-1', baseProvider.id)!;
    await expect(deleteProvider(store, 'p1')).resolves.toBe(true);

    expect(store.getState().providers).toHaveLength(0);
    expect(deletionMocks.deleteAndEnqueue).toHaveBeenCalledWith('p1', 'user-1');
    expect(deletionMocks.register).toHaveBeenCalledWith('user-1', 'p1');
    expect(deletionMocks.flush).toHaveBeenCalledWith('user-1');
    const tombstone = readCapabilityEvidenceIdentity('user-1', baseProvider.id)!;
    expect(tombstone.connectionGeneration).not.toBe(identityBefore.connectionGeneration);
    expect(tombstone.credentialEpoch).not.toBe(identityBefore.credentialEpoch);

    await addProvider(store, baseProvider);
    expect(readCapabilityEvidenceIdentity('user-1', baseProvider.id)).toEqual(tombstone);
  });

  it('deleteProvider clears every local rejection identity variant for only that connection', async () => {
    store.getState().addProvider(baseProvider);
    const baseIdentity = {
      connectionId: 'p1', canonicalModelId: 'model-a', finalTransport: 'openai_responses', runtimeRevision: 'runtime-r7',
    };
    const descriptor = {
      version: 1 as const,
      action: 'user_confirmed_resend_without_located_setting' as const,
      source: 'custom' as const,
      owners: ['generation'] as const,
      locatedPointers: ['/temperature'],
    };
    const variants = [
      baseIdentity,
      { ...baseIdentity, canonicalModelId: 'model-b' },
      { ...baseIdentity, finalTransport: 'openai_chat' },
      { ...baseIdentity, runtimeRevision: 'runtime-r8' },
    ];
    for (const identity of variants) recordCapabilityRejection(identity, { ...descriptor, owners: [...descriptor.owners] });
    const retained = { ...baseIdentity, connectionId: 'p2' };
    recordCapabilityRejection(retained, { ...descriptor, owners: [...descriptor.owners] });
    const toolVariants = [
      { accountId: 'user-1', connectionId: 'p1', authMode: 'apiKey' as const, canonicalModelId: 'model-a', finalTransport: 'openai_chat' },
      { accountId: 'user-1', connectionId: 'p1', authMode: 'subscription' as const, canonicalModelId: 'model-b', finalTransport: 'openai_responses' },
    ];
    for (const identity of toolVariants) recordToolCallSupportFalse(identity);
    const retainedTool = { ...toolVariants[0], connectionId: 'p2' };
    recordToolCallSupportFalse(retainedTool);

    await expect(deleteProvider(store, 'p1')).resolves.toBe(true);

    for (const identity of variants) expect(capabilityRejectionIsDormant(identity, 'generation', 'custom')).toBe(false);
    expect(capabilityRejectionIsDormant(retained, 'generation', 'custom')).toBe(true);
    for (const identity of toolVariants) expect(toolCallSupportIsRememberedFalse(identity)).toBe(false);
    expect(toolCallSupportIsRememberedFalse(retainedTool)).toBe(true);
  });

  it('key and endpoint mutations clear the connection tool-call observation', async () => {
    store.getState().addProvider(baseProvider);
    const identity = {
      accountId: 'user-1', connectionId: 'p1', authMode: 'apiKey' as const,
      canonicalModelId: 'model-a', finalTransport: 'openai_chat',
    };
    recordToolCallSupportFalse(identity);
    await updateProviderKey(store, baseProvider, 'sk-replaced');
    expect(toolCallSupportIsRememberedFalse(identity)).toBe(false);

    const current = store.getState().providers[0];
    recordToolCallSupportFalse(identity);
    updateProviderBaseURL(store, current, 'https://new.example.com/v1');
    expect(toolCallSupportIsRememberedFalse(identity)).toBe(false);
  });

  it('deleting a provider does not delete existing conversations; history stays in the store until the model-unavailable marker consumes it', async () => {
    store.getState().addProvider(baseProvider);
    const conversation = { id: 'conversation-1', providerID: 'p1', messages: [] };
    store.getState().setConversations([conversation] as never);

    await expect(deleteProvider(store, 'p1')).resolves.toBe(true);

    expect(store.getState().conversations).toEqual([conversation]);
  });

  it('deleting a provider writes tombstones only for its own generation scopes and leaves existing conversations unchanged', async () => {
    store.getState().addProvider(baseProvider);
    const conversation = { id: 'conversation-1', providerID: 'p1', messages: [] };
    store.getState().setConversations([conversation] as never);
    // Seed all three scope kinds through the production write entry points rather than assembling a
    // localStorage fixture.
    saveConnectionGenerationParameterDefaults('p1', { top_p: valueOverride(0.8) });
    saveGenerationParameterOverrides({ providerId: 'p1', modelId: 'model-a' }, { temperature: valueOverride(0.4) });
    saveGenerationParameterOverrides(
      { providerId: 'p1', modelId: 'model-a', conversationId: conversation.id },
      { top_k: valueOverride(40) },
    );
    saveGenerationParameterOverrides({ providerId: 'p2', modelId: 'model-a' }, { temperature: valueOverride(0.2) });

    await expect(deleteProvider(store, 'p1')).resolves.toBe(true);

    const sync = exportGenerationParameterSyncPayload();
    expect(sync.records).toEqual([expect.objectContaining({ providerId: 'p2' })]);
    expect(sync.tombstones.map((item) => item.recordId)).toEqual(expect.arrayContaining([
      'scope:connection:p1',
      'scope:model:p1:model-a',
      'scope:conversation:p1:model-a:conversation-1',
    ]));
    expect(store.getState().conversations).toEqual([conversation]);
  });

  it('deleting a custom LLM clears the connection, key, models, defaults and every parameter record while keeping historical conversations', async () => {
    // This fixture is built through store.addProvider and the generation parameter write entry points, so
    // the post-delete assertions read the real store, selector and parameter sync payload rather than a
    // hand-built delete result.
    const relay: Provider = {
      ...relayProvider,
      id: 'relay-delete-e2e',
      apiKey: 'sk-delete-me',
      apiKeyPreview: 'sk-d...e',
      status: { kind: 'connected' },
      relayRequested: {
        transport: 'openai_chat_completions',
        authMode: 'bearer',
        modelID: 'default-model',
      },
      models: [
        {
          id: 'default-model', name: 'Default model', capabilities: ['text'],
          reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
        },
        {
          id: 'other-model', name: 'Other model', capabilities: ['text'],
          reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '',
        },
      ],
      catalogModels: [
        {
          id: 'default-model', name: 'Default model', capabilities: ['text'],
          reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
        },
      ],
    };
    const conversation = {
      id: 'conversation-kept-after-provider-delete',
      title: 'Historical conversation', hasCustomTitle: true,
      providerID: relay.id, modelID: 'default-model', providerKind: 'relay',
      previewText: 'Keep this record', estimatedCost: 0, isDraft: false,
      messages: [], draftText: '', createdAt: '2026-08-09T00:00:00.000Z', updatedAt: '2026-08-09T00:00:00.000Z',
    };
    store.getState().addProvider(relay);
    store.getState().setConversations([conversation] as never);
    saveConnectionGenerationParameterDefaults(relay.id, { top_p: valueOverride(0.8) });
    saveGenerationParameterOverrides({ providerId: relay.id, modelId: 'default-model' }, { temperature: valueOverride(0.4) });
    saveGenerationParameterOverrides(
      { providerId: relay.id, modelId: 'default-model', conversationId: conversation.id },
      { top_k: valueOverride(40) },
    );
    const deletedPreset = saveGenerationParameterPreset({
      id: 'preset-deleted-with-relay', name: 'Relay preset', providerId: relay.id,
      modelId: 'default-model', profileFingerprint: 'relay|openai_chat_completions',
      values: { frequency_penalty: valueOverride(0.2) },
    });

    vi.resetModules();
    vi.doMock('../sync-port', () => ({
      getSyncAdapter: () => mockSyncAdapter,
      flushPendingProviderDeletions: (...args: unknown[]) => deletionMocks.flush(...args),
      registerPendingProviderDeletion: (...args: unknown[]) => deletionMocks.register(...args),
      unregisterPendingProviderDeletion: (...args: unknown[]) => deletionMocks.unregister(...args),
    }));
    const { deleteProvider: deleteProviderScoped } = await import('../provider-ops');

    await expect(deleteProviderScoped(store, relay.id)).resolves.toBe(true);

    expect(store.getState().providers.find((provider) => provider.id === relay.id)).toBeUndefined();
    expect(createProviderSelectionSnapshot(store.getState().providers.find((provider) => provider.id === relay.id))).toBeNull();
    expect(store.getState().conversations).toEqual([conversation]);

    const sync = exportGenerationParameterSyncPayload();
    expect(sync.records.some((record) => record.providerId === relay.id)).toBe(false);
    expect(sync.presets.some((preset) => preset.providerId === relay.id)).toBe(false);
    expect(sync.tombstones.map((item) => item.recordId)).toEqual(expect.arrayContaining([
      `scope:connection:${relay.id}`,
      `scope:model:${relay.id}:default-model`,
      `scope:conversation:${relay.id}:default-model:${conversation.id}`,
      `preset:${deletedPreset.id}`,
    ]));
    vi.doUnmock('../sync-port');
  });


  it('a failed delete transaction keeps the store and produces no guard and no cloud replay', async () => {
    store.getState().addProvider(baseProvider);
    deletionMocks.deleteAndEnqueue.mockRejectedValueOnce(new Error('idb unavailable'));

    await expect(deleteProvider(store, 'p1')).resolves.toBe(false);

    expect(store.getState().providers.map((provider) => provider.id)).toEqual(['p1']);
    expect(deletionMocks.register).not.toHaveBeenCalled();
    expect(deletionMocks.flush).not.toHaveBeenCalled();
  });

  it('a guest delete is a local hard delete only and creates no cloud tombstone for a signed-in account', async () => {
    deletionMocks.activeUID = 'guest';
    store.getState().addProvider(baseProvider);

    await expect(deleteProvider(store, 'p1')).resolves.toBe(true);

    expect(deletionMocks.deleteStoredProvider).toHaveBeenCalledWith('p1', 'guest');
    expect(deletionMocks.deleteAndEnqueue).not.toHaveBeenCalled();
    expect(deletionMocks.flush).not.toHaveBeenCalled();
  });

  it('a relay is still a provider that participates in cloud sync', async () => {
    const relay = { ...baseProvider, id: 'relay-1', kind: 'relay' as const };
    store.getState().addProvider(relay);

    await expect(deleteProvider(store, 'relay-1')).resolves.toBe(true);

    expect(deletionMocks.deleteAndEnqueue).toHaveBeenCalledWith('relay-1', 'user-1');
    expect(deletionMocks.flush).toHaveBeenCalledWith('user-1');
  });

  it('a deterministic-ID delete followed immediately by re-add atomically cancels the pending write before writing the active record remotely', async () => {
    store.getState().addProvider(baseProvider);
    await deleteProvider(store, 'p1');
    vi.clearAllMocks();

    await addProvider(store, baseProvider);

    expect(deletionMocks.putAndCancel).toHaveBeenCalledWith(baseProvider, 'user-1');
    expect(deletionMocks.unregister).toHaveBeenCalledWith('user-1', 'p1');
    expect(mockSyncAdapter.didUpdateProvider).toHaveBeenCalledWith(baseProvider);
    expect(deletionMocks.putAndCancel.mock.invocationCallOrder[0]).toBeLessThan(
      mockSyncAdapter.didUpdateProvider.mock.invocationCallOrder[0],
    );
  });

  it('a re-add must not overtake an unfinished delete and write active early', async () => {
    store.getState().addProvider(baseProvider);
    let releaseDelete: (() => void) | undefined;
    deletionMocks.deleteAndEnqueue.mockImplementationOnce(async () => {
      await new Promise<void>((resolve) => { releaseDelete = resolve; });
    });

    const deleting = deleteProvider(store, 'p1');
    await vi.waitFor(() => expect(releaseDelete).toBeTypeOf('function'));
    const readding = addProvider(store, baseProvider);

    expect(deletionMocks.putAndCancel).not.toHaveBeenCalled();
    expect(mockSyncAdapter.didUpdateProvider).not.toHaveBeenCalled();

    releaseDelete?.();
    await Promise.all([deleting, readding]);

    expect(deletionMocks.deleteAndEnqueue.mock.invocationCallOrder[0]).toBeLessThan(
      deletionMocks.putAndCancel.mock.invocationCallOrder[0],
    );
    expect(deletionMocks.putAndCancel.mock.invocationCallOrder[0]).toBeLessThan(
      mockSyncAdapter.didUpdateProvider.mock.invocationCallOrder[0],
    );
  });

  it('when the re-add cancel-pending transaction fails, neither the store nor the remote active record is written', async () => {
    deletionMocks.putAndCancel.mockRejectedValueOnce(new Error('idb unavailable'));

    await expect(addProvider(store, baseProvider)).rejects.toThrow('idb unavailable');

    expect(store.getState().providers).toHaveLength(0);
    expect(deletionMocks.unregister).not.toHaveBeenCalled();
    expect(mockSyncAdapter.didUpdateProvider).not.toHaveBeenCalled();
  });

  describe('upstream revocation when a Grok subscription is disconnected', () => {
    const subscribed: Provider = {
      ...baseProvider,
      id: 'grok-1',
      kind: 'grok',
      name: 'Grok',
      authMode: 'subscription',
      grokSubscription: { accessToken: 'access-1', refreshToken: 'refresh-1', obtainedAt: 0 },
    };

    afterEach(() => {
      vi.unstubAllGlobals();
    });

    /** Revocation is best effort: even when the upstream is unreachable the local credential must be cleared, otherwise disconnecting leaves a working token behind. */
    it('switching back to an API key still completes the local cleanup when revocation fails', async () => {
      const fetchMock = vi.fn(async () => {
        throw new Error('offline');
      });
      vi.stubGlobal('fetch', fetchMock);
      store.getState().addProvider(subscribed);

      await expect(switchProviderToApiKeyMode(store, 'grok-1')).resolves.toBe(true);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/providers/grok-subscription/revoke');
      expect(JSON.parse((fetchMock.mock.calls[0]?.[1] as RequestInit).body as string)).toEqual({
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
      });
      const next = store.getState().providers.find((item) => item.id === 'grok-1');
      expect(next?.grokSubscription).toBeUndefined();
      expect(next?.authMode).toBe('apiKey');
    });

    it('deleting the connection still completes the local deletion when revocation fails', async () => {
      const fetchMock = vi.fn(async () => new Response('', { status: 500 }));
      vi.stubGlobal('fetch', fetchMock);
      store.getState().addProvider(subscribed);

      await expect(deleteProvider(store, 'grok-1')).resolves.toBe(true);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(store.getState().providers).toHaveLength(0);
      expect(deletionMocks.deleteAndEnqueue).toHaveBeenCalled();
    });

    it('a non-subscription instance does not issue an extra revocation', async () => {
      const fetchMock = vi.fn();
      vi.stubGlobal('fetch', fetchMock);
      store.getState().addProvider(baseProvider);

      await expect(deleteProvider(store, 'p1')).resolves.toBe(true);

      expect(fetchMock).not.toHaveBeenCalled();
    });
  });

});
