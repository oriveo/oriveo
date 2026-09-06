import { act, renderHook, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { createAppStore } from '../core/store/app-store';
import { PROVIDER_VALIDATION_MESSAGES } from '../core/providers/validation-messages';
import { useProviderActions } from './useProviderActions';

const storeHolder = vi.hoisted(() => ({ current: null as unknown }));

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
      catalogModels: [],
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
      catalogModels: [],
    });
    expect(view.result.current.catalogLoadState).toBe('idle');
    expect(view.result.current.relaySettingsSaveFailure).toMatchObject({
      phase: 'generation',
      canSaveUnverified: false,
    });
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it('drops stale unverified-save and retry actions after another writer replaces the canonical provider', async () => {
    const store = storeHolder.current as ReturnType<typeof createAppStore>;
    vi.mocked(fetch).mockResolvedValue(new Response(JSON.stringify({ error: { message: 'rejected' } }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    }));
    const canonical = store.getState().providers[0];
    const view = renderHook(() => useProviderActions(canonical));
    const patch = {
      baseURLText: 'https://rejected.example/v1',
      relayKind: canonical.relayKind!,
      relayRequested: canonical.relayRequested!,
    };

    await act(async () => {
      await expect(view.result.current.saveRelaySettings(patch)).resolves.toBe(false);
    });
    act(() => store.getState().updateProvider(canonical.id, { customName: 'Concurrent writer' }));
    await act(async () => {
      await expect(view.result.current.saveRelaySettingsUnverified()).resolves.toBe(false);
    });
    expect(store.getState().providers[0]).toMatchObject({
      customName: 'Concurrent writer',
      baseURLText: canonical.baseURLText,
    });

    const secondCanonical = store.getState().providers[0];
    await act(async () => {
      await expect(view.result.current.saveRelaySettings(patch)).resolves.toBe(false);
    });
    act(() => store.getState().updateProvider(secondCanonical.id, { customName: 'Second writer' }));
    const fetchCountBeforeRetry = vi.mocked(fetch).mock.calls.length;
    await act(async () => {
      await expect(view.result.current.retryRelaySettingsSave()).resolves.toBe(false);
    });
    expect(fetch).toHaveBeenCalledTimes(fetchCountBeforeRetry);
    expect(store.getState().providers[0]).toMatchObject({
      customName: 'Second writer',
      baseURLText: canonical.baseURLText,
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
