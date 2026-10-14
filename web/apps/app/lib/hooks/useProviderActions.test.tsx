import { act, renderHook, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { createAppStore } from '../core/store/app-store';
import { PROVIDER_VALIDATION_MESSAGES } from '../core/providers/validation-messages';
import { useProviderActions } from './useProviderActions';
import { loadGenerationParameterOverrides, saveGenerationParameterOverrides } from '../core/chat/generation-parameter-settings';
import { encodeCapabilityTransportIdentity, exportCapabilityPreferenceSyncPayload, saveCapabilityPreferences } from '../core/chat/capability-preference-settings';
import {
  relayEditDraftFromProvider,
  relayEditSavePatch,
  relayEditSavePatchFor,
} from '../../app/providers/[providerId]/relay-edit-board';
import { relayFormNormalizedEndpoint } from '@oriveo/core/providers/relay-form-validation';

const storeHolder = vi.hoisted(() => ({ current: null as unknown }));
// Official provider catalogs are driven by metadata; null falls back to the real implementation.
const metadataHolder = vi.hoisted(() => ({ current: null as unknown }));

vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('../../providers/StoreProvider', () => ({
  getVanillaStore: () => storeHolder.current,
}));
vi.mock('../core/sync-port', () => ({ getSyncAdapter: () => undefined }));
vi.mock('../core/metadata/metadata-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../core/metadata/metadata-client')>();
  return {
    ...actual,
    getRelayRuntimeConfig: () => actual.DEFAULT_RELAY_RUNTIME_CONFIG,
    getMetadataSnapshot: () => (metadataHolder.current ?? actual.getMetadataSnapshot()) as ReturnType<typeof actual.getMetadataSnapshot>,
  };
});

const existingModel: Provider['models'][number] = {
  id: 'existing-model',
  name: 'Existing model',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
};

function relayProvider(): Provider {
  return {
    id: 'relay-hook',
    kind: 'relay',
    customName: 'Original',
    status: { kind: 'connected' },
    models: [existingModel],
    catalogModels: [existingModel],
    apiKey: 'sk-hook-secret',
    apiKeyPreview: '••••',
    baseURLText: 'https://relay.example/v1',
    relayKind: 'openai_compatible',
    relayRequested: {
      transport: 'openai_chat_completions',
      authMode: 'bearer',
      modelID: existingModel.id,
    },
  };
}

describe('useProviderActions relay edit transaction', () => {
  beforeEach(() => {
    const store = createAppStore();
    store.getState().addProvider(relayProvider());
    storeHolder.current = store;
    vi.stubGlobal('fetch', vi.fn());
  });

  it('saves a generation-verified candidate as connected, invalidates stale catalog, and persists catalog failure across remount', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch)
      .mockResolvedValueOnce(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'catalog unavailable' } }), {
        status: 503,
        headers: { 'Content-Type': 'application/json' },
      }));
    const canonical = store.getState().providers[0];
    const view = renderHook(({ provider }) => useProviderActions(provider), {
      initialProps: { provider: canonical },
    });

    await act(async () => {
      await expect(view.result.current.saveRelaySettings({
        baseURLText: 'https://new-relay.example/v1',
        relayKind: canonical.relayKind!,
        relayRequested: canonical.relayRequested!,
      })).resolves.toBe(true);
    });

    await waitFor(() => expect(store.getState().providers[0].lastError)
      .toBe(PROVIDER_VALIDATION_MESSAGES.catalogUnavailable));
    expect(store.getState().providers[0]).toMatchObject({
      baseURLText: 'https://new-relay.example/v1',
      status: { kind: 'connected' },
      models: [existingModel],
      catalogModels: [],
    });
    expect(view.result.current.relaySettingsSaveFailure).toBeNull();
    expect(view.result.current.catalogLoadState).toBe('failed');

    view.unmount();
    const remounted = renderHook(() => useProviderActions(store.getState().providers[0]));
    expect(remounted.result.current.catalogLoadState).toBe('failed');
  });

  it('after the address is normalized and verification fails, "save anyway (unverified)" stores the normalized draft (production save path of the edit page)', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'nope' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));
    const canonical = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(canonical), endpoint: '  new-relay.example/v2/  ' };
    const normalized = relayFormNormalizedEndpoint({
      endpoint: draft.endpoint,
      apiKey: '',
      authMode: draft.authMode,
      securityMode: 'remote_https',
      transport: draft.transport,
      modelID: existingModel.id,
      headers: draft.headers,
      queryParams: draft.queryParams,
      hasSavedCredential: true,
    }, 'edit');
    expect(normalized).toBe('https://new-relay.example/v2');
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await expect(view.result.current.saveRelaySettings(relayEditSavePatch(canonical, draft, normalized!)))
        .resolves.toBe(false);
    });
    expect(view.result.current.relaySettingsSaveFailure?.canSaveUnverified).toBe(true);

    await act(async () => {
      await expect(view.result.current.saveRelaySettingsUnverified()).resolves.toBe(true);
    });
    expect(store.getState().providers[0]).toMatchObject({
      baseURLText: 'https://new-relay.example/v2',
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
    });
  });

  it('rotates a key through generation success then catalog success without deleting enabled models', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch)
      .mockResolvedValueOnce(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: 'catalog-model' }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await view.result.current.saveKey('sk-rotated-success');
    });
    await waitFor(() => expect(view.result.current.catalogLoadState).toBe('loaded'));

    expect(store.getState().providers[0]).toMatchObject({
      apiKey: 'sk-rotated-success',
      status: { kind: 'connected' },
      lastError: undefined,
      models: [existingModel],
      catalogModels: [expect.objectContaining({ id: 'catalog-model' })],
    });
    expect(vi.mocked(fetch).mock.calls.map((call) => (call[1] as RequestInit).method)).toEqual(['POST', 'GET']);
  });

  it('multi-key connection swapping the primary key value re-fetches only the primary key, leaving the other keys untouched', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const kbStatus = { state: 'invalid' as const, httpStatus: 401 };
    store.getState().updateProvider('relay-hook', {
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-b', apiKey: 'sk-b', status: kbStatus }],
      models: [{ ...existingModel, relayKeyID: 'initial' }],
      catalogModels: [
        { ...existingModel, relayListedByKeyIDs: ['initial'] },
        { ...existingModel, id: 'claude-opus-4', name: 'claude-opus-4', relayListedByKeyIDs: ['k-b'] },
      ],
    });
    vi.mocked(fetch)
      .mockResolvedValueOnce(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ data: [{ id: 'existing-model' }, { id: 'gpt-4.1' }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await view.result.current.saveKey('sk-primary-2');
    });
    await waitFor(() => expect(view.result.current.catalogLoadState).toBe('loaded'));

    const calls = vi.mocked(fetch).mock.calls;
    expect(calls.map((call) => (call[1] as RequestInit).method)).toEqual(['POST', 'GET']);
    expect(JSON.stringify(calls[1]![1]?.headers)).toContain('sk-primary-2');
    const after = store.getState().providers[0];
    expect(after.apiKey).toBe('sk-primary-2');
    expect(Object.fromEntries(after.catalogModels.map((item) => [item.id, item.relayListedByKeyIDs]))).toEqual({
      'existing-model': ['initial'],
      'gpt-4.1': ['initial'],
      'claude-opus-4': ['k-b'],
    });
    expect(after.relayKeys![1]).toEqual({ id: 'k-b', apiKey: 'sk-b', status: kbStatus });
    expect(after.relayKeys![0]!.status?.state).toBe('ok');
  });

  it('keeps a generation-verified rotated key connected when its separate catalog refresh fails', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch)
      .mockResolvedValueOnce(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'catalog offline' } }), {
        status: 503,
        headers: { 'Content-Type': 'application/json' },
      }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await view.result.current.saveKey('sk-rotated-catalog-failure');
    });
    await waitFor(() => expect(view.result.current.catalogLoadState).toBe('failed'));

    expect(store.getState().providers[0]).toMatchObject({
      apiKey: 'sk-rotated-catalog-failure',
      status: { kind: 'connected' },
      lastError: PROVIDER_VALIDATION_MESSAGES.catalogUnavailable,
      models: [existingModel],
      // Swapping the key does not clear the catalog: when re-verification or the catalog refresh fails, the catalog is kept as is.
      catalogModels: [existingModel],
    });
  });

  it('keeps a generation-rejected rotated key, marks issue, and never starts catalog refresh', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'invalid key' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await expect(view.result.current.saveKey('sk-rotated-invalid')).rejects.toMatchObject({ kind: 'invalidKey' });
    });

    expect(store.getState().providers[0]).toMatchObject({
      apiKey: 'sk-rotated-invalid',
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.invalidKey },
      // Swapping the key does not clear the catalog: when re-verification or the catalog refresh fails, the catalog is kept as is.
      catalogModels: [existingModel],
    });
    expect(view.result.current.catalogLoadState).toBe('idle');
    expect(view.result.current.relaySettingsSaveFailure).toMatchObject({
      phase: 'generation',
      canSaveUnverified: false,
    });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('after the failure card, a change made elsewhere to the connection: "save anyway (unverified)" and retry both merge into the live record instead of being discarded', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ error: { message: 'rejected' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));
    const draft = { ...relayEditDraftFromProvider(canonical), endpoint: 'https://rejected.example/v1' };
    const patch = relayEditSavePatchFor(canonical, draft, draft.endpoint);

    await act(async () => {
      await expect(view.result.current.saveRelaySettings(patch)).resolves.toBe(false);
    });
    act(() => store.getState().updateProvider(canonical.id, { customName: 'Concurrent writer' }));
    await act(async () => {
      await expect(view.result.current.saveRelaySettingsUnverified()).resolves.toBe(true);
    });
    expect(store.getState().providers[0]).toMatchObject({
      customName: 'Concurrent writer',
      baseURLText: 'https://rejected.example/v1',
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
    });

    const retryDraft = { ...draft, endpoint: 'https://retry.example/v1' };
    await act(async () => {
      await expect(view.result.current.saveRelaySettings(relayEditSavePatchFor(canonical, retryDraft, retryDraft.endpoint)))
        .resolves.toBe(false);
    });
    act(() => store.getState().updateProvider(canonical.id, { customName: 'Second writer' }));
    const fetchCountBeforeRetry = vi.mocked(fetch).mock.calls.length;
    await act(async () => {
      await expect(view.result.current.retryRelaySettingsSave()).resolves.toBe(false);
    });
    expect(vi.mocked(fetch).mock.calls.length).toBeGreaterThan(fetchCountBeforeRetry);
    expect(view.result.current.relaySettingsSaveFailure?.canSaveUnverified).toBe(true);
    expect(store.getState().providers[0]).toMatchObject({
      customName: 'Second writer',
      baseURLText: 'https://rejected.example/v1',
    });
  });

  it('keeps unverified connection status while persisting a later catalog failure for remount', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch)
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'generation rejected' } }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ error: { message: 'catalog unavailable' } }), {
        status: 503,
        headers: { 'Content-Type': 'application/json' },
      }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));
    const patch = {
      baseURLText: 'https://unverified.example/v1',
      relayKind: canonical.relayKind!,
      relayRequested: canonical.relayRequested!,
    };

    await act(async () => {
      await expect(view.result.current.saveRelaySettings(patch)).resolves.toBe(false);
    });
    await act(async () => {
      await expect(view.result.current.saveRelaySettingsUnverified()).resolves.toBe(true);
    });
    await waitFor(() => expect(store.getState().providers[0].lastError)
      .toBe(PROVIDER_VALIDATION_MESSAGES.catalogUnavailable));
    expect(store.getState().providers[0]).toMatchObject({
      baseURLText: 'https://unverified.example/v1',
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
      models: [existingModel],
      catalogModels: [],
    });

    view.unmount();
    const remounted = renderHook(() => useProviderActions(store.getState().providers[0]));
    expect(remounted.result.current.catalogLoadState).toBe('failed');
  });
});

describe('useProviderActions official provider key rotation', () => {
  beforeEach(() => {
    const store = createAppStore();
    store.getState().addProvider({
      id: 'official-hook',
      kind: 'openRouter',
      status: { kind: 'connected' },
      models: [existingModel],
      catalogModels: [existingModel],
      apiKey: 'sk-or-old',
      apiKeyPreview: '••••',
    });
    storeHolder.current = store;
    vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => (
      String(input).includes('/api/providers/validate')
        ? new Response(JSON.stringify({ result: 'valid' }), { status: 200, headers: { 'Content-Type': 'application/json' } })
        : new Response('{}', { status: 503 })
    )));
  });

  afterEach(() => {
    metadataHolder.current = null;
  });

  it('validates a rotated official key through the official path instead of relay verification', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const view = renderHook(() => useProviderActions(store.getState().providers[0]));

    await act(async () => {
      await expect(view.result.current.saveKey('sk-or-new')).resolves.toBeUndefined();
    });

    expect(store.getState().providers[0]).toMatchObject({
      apiKey: 'sk-or-new',
      status: { kind: 'connected' },
      lastError: undefined,
      models: [existingModel],
    });
    const validateCall = vi.mocked(fetch).mock.calls.find((call) => String(call[0]).includes('/api/providers/validate'));
    expect(JSON.parse((validateCall![1] as RequestInit).body as string)).toMatchObject({
      providerKind: 'openRouter',
      apiKey: 'sk-or-new',
    });
  });

  it('resyncs an official provider through official validation and restores connected status', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    store.getState().updateProvider('official-hook', {
      status: { kind: 'issue', message: PROVIDER_VALIDATION_MESSAGES.unverified },
      lastError: PROVIDER_VALIDATION_MESSAGES.unverified,
    });
    const view = renderHook(() => useProviderActions(store.getState().providers[0]));

    await act(async () => {
      await view.result.current.resync();
    });

    expect(store.getState().providers[0]).toMatchObject({
      status: { kind: 'connected' },
      lastError: undefined,
      models: [existingModel],
    });
    expect(view.result.current.isSyncing).toBe(false);
  });

  // Deleting an official connection is covered in provider-ops.test.ts; the hook only forwards the call.
  it('writes rename, enable all, disable all and single toggles for an official provider to the store', () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const second = { ...existingModel, id: 'second-model', name: 'Second model', isDefault: false };
    metadataHolder.current = { providers: { openRouter: { models: { 'existing-model': {}, 'second-model': {} } } } };
    const current = () => store.getState().providers[0];
    const actions = () => renderHook(() => useProviderActions(current())).result.current;

    const rename = actions();
    act(() => rename.saveName('My OpenRouter'));
    expect(current().customName).toBe('My OpenRouter');

    const enableAll = actions();
    act(() => enableAll.enableAllModels());
    expect(current().models.map((model) => model.id).sort()).toEqual(['existing-model', 'second-model']);

    const toggle = actions();
    act(() => toggle.toggleModel(second));
    expect(current().models.map((model) => model.id)).toEqual(['existing-model']);

    const disableAll = actions();
    act(() => disableAll.disableAllModels());
    expect(current().models).toEqual([]);
  });
});

describe('editing the draft while a save is in flight (production save path)', () => {
  beforeEach(() => {
    const store = createAppStore();
    store.getState().addProvider(relayProvider());
    storeHolder.current = store;
    vi.stubGlobal('fetch', vi.fn());
  });

  it('does not lose later edits: when the draft changed after verification passed, nothing is written back and no failure card appears', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));
    await act(async () => {
      await expect(view.result.current.saveRelaySettings({
        baseURLText: 'https://new-relay.example/v1',
        relayKind: canonical.relayKind!,
        relayRequested: canonical.relayRequested!,
      }, { isStale: () => true })).resolves.toBe(false);
    });
    expect(vi.mocked(fetch)).toHaveBeenCalled();
    expect(store.getState().providers[0]).toBe(canonical);
    expect(view.result.current.relaySettingsSaveFailure).toBeNull();
  });

  it('shows no failure card either when the draft changed and verification failed', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify({ error: { message: 'nope' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));
    await act(async () => {
      await expect(view.result.current.saveRelaySettings({
        baseURLText: 'https://new-relay.example/v1',
        relayKind: canonical.relayKind!,
        relayRequested: canonical.relayRequested!,
      }, { isStale: () => true })).resolves.toBe(false);
    });
    expect(store.getState().providers[0]).toBe(canonical);
    expect(view.result.current.relaySettingsSaveFailure).toBeNull();
  });
});

describe('edit save colliding with changes made elsewhere merges field by field', () => {
  const okResponse = () => new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
  const syncedModel: Provider['models'][number] = { ...existingModel, id: 'synced-model', name: 'Synced model', isDefault: false };

  beforeEach(() => {
    const store = createAppStore();
    store.getState().addProvider(relayProvider());
    storeHolder.current = store;
    vi.stubGlobal('fetch', vi.fn());
  });

  /** The first verification request hangs until the test releases it; every later request succeeds immediately. */
  function holdFirstFetch() {
    let release: (response: Response) => void = () => {};
    vi.mocked(fetch)
      .mockImplementationOnce(() => new Promise<Response>((resolve) => { release = resolve; }))
      .mockImplementation(() => Promise.resolve(okResponse()));
    return (response: Response) => release(response);
  }

  function postHeaders(callIndex: number): string {
    const posts = vi.mocked(fetch).mock.calls.filter((call) => (call[1] as RequestInit | undefined)?.method === 'POST');
    return JSON.stringify(posts[callIndex]?.[1]?.headers ?? {});
  }

  it('a sync that changes the name / models during verification: the commit has the address the user edited plus the synced fields, and the verification status is written', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const release = holdFirstFetch();
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: 'https://new-relay.example/v1' };
    const view = renderHook(() => useProviderActions(baseline));

    let pending!: Promise<boolean>;
    act(() => { pending = view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, draft.endpoint)); });
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    act(() => store.getState().updateProvider(baseline.id, {
      customName: 'Synced name',
      models: [existingModel, syncedModel],
    }));
    release(okResponse());
    await act(async () => { await expect(pending).resolves.toBe(true); });

    const saved = store.getState().providers[0];
    expect(saved).toMatchObject({
      customName: 'Synced name',
      baseURLText: 'https://new-relay.example/v1',
      status: { kind: 'connected' },
    });
    expect(saved.models.map((model) => model.id)).toContain('synced-model');
    expect(saved.lastCheckedAt).toBeTruthy();
    expect(vi.mocked(fetch).mock.calls.filter((call) => (call[1] as RequestInit).method === 'POST')).toHaveLength(1);
  });

  it('a sync that changes a request header the user did not touch during verification: the second probe goes out with the merged value and both sides are committed', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const release = holdFirstFetch();
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: 'https://new-relay.example/v1' };
    const view = renderHook(() => useProviderActions(baseline));

    let pending!: Promise<boolean>;
    act(() => { pending = view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, draft.endpoint)); });
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    act(() => store.getState().updateProvider(baseline.id, {
      relayRequested: { ...baseline.relayRequested!, headers: [{ key: 'X-Synced', value: 'from-sync' }] },
    }));
    release(okResponse());
    await act(async () => { await expect(pending).resolves.toBe(true); });

    expect(postHeaders(0)).not.toContain('from-sync');
    expect(postHeaders(1)).toContain('from-sync');
    const saved = store.getState().providers[0];
    expect(saved).toMatchObject({
      baseURLText: 'https://new-relay.example/v1',
      status: { kind: 'connected' },
    });
    expect(saved.relayRequested?.headers).toEqual([{ key: 'X-Synced', value: 'from-sync' }]);
  });

  it('colliding again during the second probe commits the merge without writing the verification status', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    store.getState().updateProvider('relay-hook', { status: { kind: 'issue', message: 'live status' } });
    const releases: Array<(response: Response) => void> = [];
    vi.mocked(fetch).mockImplementation(() => new Promise<Response>((resolve) => { releases.push(resolve); }));
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: 'https://new-relay.example/v1' };
    const view = renderHook(() => useProviderActions(baseline));

    let pending!: Promise<boolean>;
    act(() => { pending = view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, draft.endpoint)); });
    await waitFor(() => expect(releases).toHaveLength(1));
    act(() => store.getState().updateProvider(baseline.id, {
      relayRequested: { ...baseline.relayRequested!, headers: [{ key: 'X-Synced', value: 'one' }] },
    }));
    releases[0]!(okResponse());
    await waitFor(() => expect(releases).toHaveLength(2));
    act(() => store.getState().updateProvider(baseline.id, {
      relayRequested: { ...baseline.relayRequested!, headers: [{ key: 'X-Synced', value: 'two' }] },
    }));
    releases[1]!(okResponse());
    await act(async () => { await expect(pending).resolves.toBe(true); });

    const saved = store.getState().providers[0];
    expect(saved.baseURLText).toBe('https://new-relay.example/v1');
    expect(saved.relayRequested?.headers).toEqual([{ key: 'X-Synced', value: 'two' }]);
    expect(saved.status).toEqual({ kind: 'issue', message: 'live status' });
  });

  it('first verification fails while a request header the user did not touch changes elsewhere: a second probe goes out with the merged value and its result decides the commit and the failure card', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const rejected = () => new Response(JSON.stringify({ error: { message: 'rejected' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
    let release: (response: Response) => void = () => {};
    vi.mocked(fetch)
      .mockImplementationOnce(() => new Promise<Response>((resolve) => { release = resolve; }))
      .mockImplementation(() => Promise.resolve(okResponse()));
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: 'https://new-relay.example/v1' };
    const view = renderHook(() => useProviderActions(baseline));

    let pending!: Promise<boolean>;
    act(() => { pending = view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, draft.endpoint)); });
    await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
    act(() => store.getState().updateProvider(baseline.id, {
      relayRequested: { ...baseline.relayRequested!, headers: [{ key: 'X-Synced', value: 'from-sync' }] },
    }));
    release(rejected());
    await act(async () => { await expect(pending).resolves.toBe(true); });

    const posts = vi.mocked(fetch).mock.calls.filter((call) => (call[1] as RequestInit).method === 'POST');
    expect(posts).toHaveLength(2);
    expect(postHeaders(1)).toContain('from-sync');
    expect(view.result.current.relaySettingsSaveFailure).toBeNull();
    const saved = store.getState().providers[0];
    expect(saved).toMatchObject({ baseURLText: 'https://new-relay.example/v1', status: { kind: 'connected' } });
    expect(saved.relayRequested?.headers).toEqual([{ key: 'X-Synced', value: 'from-sync' }]);
  });

  it('the user only added a trailing slash to the address while a sync changed the address: the address does not count as user-edited, so the synced address is kept and no probe is sent', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockImplementation(() => Promise.resolve(okResponse()));
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: `${baseline.baseURLText}/` };
    act(() => store.getState().updateProvider(baseline.id, { baseURLText: 'https://synced-relay.example/v1' }));
    const view = renderHook(() => useProviderActions(store.getState().providers[0]));

    await act(async () => {
      await expect(view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, 'https://relay.example/v1')))
        .resolves.toBe(true);
    });

    expect(fetch).not.toHaveBeenCalled();
    expect(store.getState().providers[0].baseURLText).toBe('https://synced-relay.example/v1');
  });

  it('second probe fails and a verification field the user did not touch collides again: commit the merge, write no verification status, show no failure card, two probes in total', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    store.getState().updateProvider('relay-hook', { status: { kind: 'issue', message: 'live status' } });
    const rejected = () => new Response(JSON.stringify({ error: { message: 'rejected' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    });
    const releases: Array<(response: Response) => void> = [];
    vi.mocked(fetch).mockImplementation(() => new Promise<Response>((resolve) => { releases.push(resolve); }));
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: 'https://new-relay.example/v1' };
    const view = renderHook(() => useProviderActions(baseline));

    let pending!: Promise<boolean>;
    act(() => { pending = view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, draft.endpoint)); });
    await waitFor(() => expect(releases).toHaveLength(1));
    act(() => store.getState().updateProvider(baseline.id, {
      relayRequested: { ...baseline.relayRequested!, headers: [{ key: 'X-Synced', value: 'one' }] },
    }));
    releases[0]!(rejected());
    await waitFor(() => expect(releases).toHaveLength(2));
    act(() => store.getState().updateProvider(baseline.id, {
      relayRequested: { ...baseline.relayRequested!, authMode: 'x_api_key', headers: [{ key: 'X-Synced', value: 'two' }] },
    }));
    releases[1]!(rejected());
    await act(async () => { await expect(pending).resolves.toBe(true); });

    expect(vi.mocked(fetch).mock.calls.filter((call) => (call[1] as RequestInit).method === 'POST')).toHaveLength(2);
    expect(view.result.current.relaySettingsSaveFailure).toBeNull();
    const saved = store.getState().providers[0];
    expect(saved.baseURLText).toBe('https://new-relay.example/v1');
    expect(saved.relayRequested).toMatchObject({ authMode: 'x_api_key', headers: [{ key: 'X-Synced', value: 'two' }] });
    expect(saved.status).toEqual({ kind: 'issue', message: 'live status' });
  });

  it('a sync that changes fields the user did not touch after the page opened and before save was clicked: the commit keeps the synced values', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockImplementation(() => Promise.resolve(okResponse()));
    const baseline = store.getState().providers[0];
    const draft = { ...relayEditDraftFromProvider(baseline), endpoint: 'https://new-relay.example/v1' };
    act(() => store.getState().updateProvider(baseline.id, {
      customName: 'Synced name',
      relayRequested: { ...baseline.relayRequested!, headers: [{ key: 'X-Synced', value: 'from-sync' }], customUserAgent: 'SyncedUA/1' },
    }));
    const view = renderHook(() => useProviderActions(store.getState().providers[0]));

    await act(async () => {
      await expect(view.result.current.saveRelaySettings(relayEditSavePatchFor(baseline, draft, draft.endpoint)))
        .resolves.toBe(true);
    });

    expect(postHeaders(0)).toContain('from-sync');
    const saved = store.getState().providers[0];
    expect(saved).toMatchObject({
      customName: 'Synced name',
      baseURLText: 'https://new-relay.example/v1',
      status: { kind: 'connected' },
    });
    expect(saved.relayRequested).toMatchObject({
      headers: [{ key: 'X-Synced', value: 'from-sync' }],
      customUserAgent: 'SyncedUA/1',
    });
  });
});

describe('useProviderActions endpoint editing', () => {
  function officialProvider(): Provider {
    return {
      id: 'official-hook',
      kind: 'qwen',
      customName: 'Qwen',
      status: { kind: 'connected' },
      models: [existingModel],
      catalogModels: [existingModel],
      apiKey: 'sk-official',
      apiKeyPreview: '\u2022\u2022\u2022\u2022',
      baseURLText: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    };
  }

  beforeEach(() => {
    const store = createAppStore();
    store.getState().addProvider(officialProvider());
    storeHolder.current = store;
    vi.stubGlobal('fetch', vi.fn());
  });

  // Regression: an official provider carries no relayRequested, and the editor used to bail out on
  // that, so choosing the vendor's other published endpoint collapsed the row and changed nothing.
  it('persists an endpoint change on an official provider, which has no relay request to verify', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const view = renderHook(() => useProviderActions(store.getState().providers[0]));

    await act(async () => {
      await expect(view.result.current.saveBaseURL('https://dashscope.aliyuncs.com/compatible-mode/v1'))
        .resolves.toBe(true);
    });

    expect(store.getState().providers[0].baseURLText)
      .toBe('https://dashscope.aliyuncs.com/compatible-mode/v1');
    // No probe is fired: the vendor's own endpoints need no verification round trip.
    expect(vi.mocked(fetch)).not.toHaveBeenCalled();
  });

  it('clears the endpoint back to the provider default when the field is emptied', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const view = renderHook(() => useProviderActions(store.getState().providers[0]));

    await act(async () => {
      await expect(view.result.current.saveBaseURL('   ')).resolves.toBe(true);
    });

    expect(store.getState().providers[0].baseURLText).toBeUndefined();
  });
});

describe('disabling a model through the production disable entry deletes its parameter keys', () => {
  const model = (id: string, canonicalModelId: string): Provider['models'][number] => ({
    ...existingModel, id, name: id, canonicalModelId, isDefault: false,
  });
  const providerId = 'relay-ident-07';
  const value = { temperature: { state: 'value' as const, value: 0.5 } };

  beforeEach(() => {
    localStorage.clear();
    const store = createAppStore();
    store.getState().addProvider({
      ...relayProvider(),
      id: providerId,
      models: [model('gpt-4o-2024-08-06', 'gpt-4o'), model('gpt-4o-2024-11-20', 'gpt-4o'), model('claude-sonnet-4-5', 'claude-sonnet-4-5')],
    });
    storeHolder.current = store;
  });

  it('toggleModel / removeModel delete the literal key; the canonical key goes only once no enabled model shares that canonical', () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    for (const modelId of ['gpt-4o-2024-08-06', 'gpt-4o-2024-11-20', 'gpt-4o', 'claude-sonnet-4-5']) {
      saveGenerationParameterOverrides({ providerId, modelId }, value);
    }
    const current = () => store.getState().providers.find((item) => item.id === providerId)!;
    const view = renderHook(({ provider }) => useProviderActions(provider), { initialProps: { provider: current() } });

    act(() => view.result.current.toggleModel(current().models[0]!));
    expect(current().models.map((item) => item.id)).toEqual(['gpt-4o-2024-11-20', 'claude-sonnet-4-5']);
    expect(loadGenerationParameterOverrides({ providerId, modelId: 'gpt-4o-2024-08-06' })).toBeUndefined();
    // Another snapshot still has gpt-4o as its canonical: the canonical key stays for it to read back.
    expect(loadGenerationParameterOverrides({ providerId, modelId: 'gpt-4o' })).toEqual(value);
    expect(loadGenerationParameterOverrides({ providerId, modelId: 'gpt-4o-2024-11-20' })).toEqual(value);

    view.rerender({ provider: current() });
    act(() => { view.result.current.removeModel('gpt-4o-2024-11-20'); });
    expect(current().models.map((item) => item.id)).toEqual(['claude-sonnet-4-5']);
    expect(loadGenerationParameterOverrides({ providerId, modelId: 'gpt-4o-2024-11-20' })).toBeUndefined();
    expect(loadGenerationParameterOverrides({ providerId, modelId: 'gpt-4o' })).toBeUndefined();
    expect(loadGenerationParameterOverrides({ providerId, modelId: 'claude-sonnet-4-5' })).toEqual(value);
  });

  it('capability preferences share one key set with generation parameters: disabling deletes the literal key, and the canonical key goes only once no enabled model shares that canonical', () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    const transportIdentity = encodeCapabilityTransportIdentity('openai_chat', 'r1');
    for (const canonicalModelId of ['gpt-4o-2024-08-06', 'gpt-4o-2024-11-20', 'gpt-4o', 'claude-sonnet-4-5']) {
      saveCapabilityPreferences({
        scope: 'connection_model', providerId, canonicalModelId,
        finalTransport: 'openai_chat', runtimeRevision: 'r1', transportIdentity,
      }, { web: 'force' });
    }
    const remainingKeys = () => exportCapabilityPreferenceSyncPayload().records
      .filter((record) => record.providerId === providerId)
      .map((record) => record.canonicalModelId)
      .sort();
    const current = () => store.getState().providers.find((item) => item.id === providerId)!;
    const view = renderHook(({ provider }) => useProviderActions(provider), { initialProps: { provider: current() } });

    act(() => view.result.current.toggleModel(current().models[0]!));
    expect(remainingKeys()).toEqual(['claude-sonnet-4-5', 'gpt-4o', 'gpt-4o-2024-11-20']);

    view.rerender({ provider: current() });
    act(() => { view.result.current.removeModel('gpt-4o-2024-11-20'); });
    expect(remainingKeys()).toEqual(['claude-sonnet-4-5']);
  });
});

describe('swapping the primary key / edit save / test connection write the key status', () => {
  const generationOK = () => new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), {
    status: 200, headers: { 'Content-Type': 'application/json' },
  });
  const invalid401 = () => new Response(JSON.stringify({ error: { message: 'Invalid API key' } }), {
    status: 401, headers: { 'Content-Type': 'application/json' },
  });
  const okStatus = { state: 'ok', checkedAt: expect.any(String) };
  const invalidStatus = { state: 'invalid', httpStatus: 401, checkedAt: expect.any(String) };

  function seed(extra: Partial<Provider> = {}) {
    const store = createAppStore();
    store.getState().addProvider({ ...relayProvider(), ...extra });
    storeHolder.current = store;
    vi.stubGlobal('fetch', vi.fn());
    return store;
  }

  it('after a single key swaps its primary value, fail-closed verification returning 401 marks the primary key invalid (one entry materialized)', async () => {
    const store = seed();
    vi.mocked(fetch).mockResolvedValueOnce(invalid401());
    const view = renderHook(() => useProviderActions(store.getState().providers[0]!));

    await act(async () => {
      await expect(view.result.current.saveKey('sk-rotated-invalid')).rejects.toMatchObject({ kind: 'invalidKey' });
    });

    expect(store.getState().providers[0]!.relayKeys).toEqual([{ id: 'initial', apiKey: '', status: invalidStatus }]);
  });

  it('"save anyway (unverified)" that empties the primary key value (auth changed to none) clears that key status first; a verification that sent no key writes nothing', async () => {
    const store = seed({ relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: '2026-10-01T00:00:00.000Z' } }] });
    vi.mocked(fetch).mockResolvedValue(invalid401());
    const canonical = store.getState().providers[0]!;
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await expect(view.result.current.saveRelaySettings({
        relayKind: canonical.relayKind!,
        relayRequested: { ...canonical.relayRequested!, authMode: 'none' },
      })).resolves.toBe(false);
    });
    // Not committed: the status is unchanged.
    expect(store.getState().providers[0]!.relayKeys).toEqual([
      { id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: '2026-10-01T00:00:00.000Z' } },
    ]);

    await act(async () => {
      await expect(view.result.current.saveRelaySettingsUnverified()).resolves.toBe(true);
    });
    const after = store.getState().providers[0]!;
    expect(after.apiKey).toBe('');
    expect(after.relayKeys).toEqual([{ id: 'initial', apiKey: '' }]);
  });

  it('edit save: a passing verification writes the key actually sent when committing; a failed verification that is not committed writes nothing, and "save anyway" writes it when committing', async () => {
    const store = seed();
    // Generation returns 200; the catalog refresh after the commit hangs so its result cannot leak into the assertions.
    vi.mocked(fetch)
      .mockResolvedValueOnce(generationOK())
      .mockImplementationOnce(() => new Promise<Response>(() => {}));
    const canonical = store.getState().providers[0]!;
    const view = renderHook(() => useProviderActions(canonical));

    await act(async () => {
      await expect(view.result.current.saveRelaySettings({
        baseURLText: 'https://new-relay.example/v1',
        relayKind: canonical.relayKind!,
        relayRequested: canonical.relayRequested!,
      })).resolves.toBe(true);
    });
    expect(store.getState().providers[0]!.relayKeys).toEqual([{ id: 'initial', apiKey: '', status: okStatus }]);

    const failing = seed();
    vi.mocked(fetch)
      .mockResolvedValueOnce(invalid401())
      .mockImplementation(() => new Promise<Response>(() => {}));
    const failingCanonical = failing.getState().providers[0]!;
    const failingView = renderHook(() => useProviderActions(failingCanonical));
    await act(async () => {
      await expect(failingView.result.current.saveRelaySettings({
        baseURLText: 'https://other-relay.example/v1',
        relayKind: failingCanonical.relayKind!,
        relayRequested: failingCanonical.relayRequested!,
      })).resolves.toBe(false);
    });
    expect(failing.getState().providers[0]).not.toHaveProperty('relayKeys');

    await act(async () => {
      await expect(failingView.result.current.saveRelaySettingsUnverified()).resolves.toBe(true);
    });
    expect(failing.getState().providers[0]!.relayKeys).toEqual([{ id: 'initial', apiKey: '', status: invalidStatus }]);
  });

  it('test connection: the result is written to the connection status when the draft equals the saved connection; a different draft writes nothing', async () => {
    const store = seed();
    vi.mocked(fetch).mockResolvedValueOnce(invalid401());
    const view = renderHook(() => useProviderActions(store.getState().providers[0]!));

    await act(async () => {
      await view.result.current.testRelayDraft({ ...store.getState().providers[0]!, baseURLText: 'https://draft.example/v1' }, false)
        .catch(() => null);
    });
    expect(store.getState().providers[0]).not.toHaveProperty('relayKeys');

    vi.mocked(fetch).mockResolvedValueOnce(generationOK());
    await act(async () => {
      await view.result.current.testRelayDraft(store.getState().providers[0]!, true);
    });
    expect(store.getState().providers[0]!.relayKeys).toEqual([{ id: 'initial', apiKey: '', status: okStatus }]);
  });
});
