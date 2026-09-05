/**
 * bootstrapApp hydrationPhase safety net.
 *
 * Scenario: a metadata refresh, hydrate or IDB step throws. hydrationPhase must still converge
 * to 'ready' so the UI never sticks on a skeleton.
 */

import 'fake-indexeddb/auto';

import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';

// Make hydrateStore controllable: it succeeds by default, and individual tests switch it to throw.
const hydrateStoreMock = vi.fn(async () => {});
vi.mock('../store/persistence', async () => {
  const actual = await vi.importActual<typeof import('../store/persistence')>('../store/persistence');
  return {
    ...actual,
    hydrateStore: (...args: Parameters<typeof actual.hydrateStore>) =>
      hydrateStoreMock(...(args as unknown as [])),
  };
});

// Metadata refresh: succeeds by default, individual tests switch it to throw.
// Note that a throw from initMetadata / refreshMetadata is swallowed by the withBudget
// try/catch inside hydrateMetadataAndReconcileProviders, which falls back to the local cache,
// so making that function actually throw means injecting the error further down the path, for
// example in getMetadataSnapshot.
const initMetadataMock = vi.fn(async () => {});
const refreshMetadataMock = vi.fn(async () => {});
const isMetadataRefreshDueMock = vi.fn(() => false);
const getMetadataSnapshotMock = vi.fn(() => null as unknown);
const getMetadataContractVersionMock = vi.fn(() => 1 as number | null);
const getRelayRuntimeConfigMock = vi.fn(() => ({
  transportEnvelopes: {},
  transportRules: {},
  relayDefaults: {},
  probePolicy: null,
}));
vi.mock('../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../metadata/metadata-client')>(
    '../metadata/metadata-client',
  );
  return {
    ...actual,
    initMetadata: () => initMetadataMock(),
    refreshMetadata: () => refreshMetadataMock(),
    isMetadataRefreshDue: () => isMetadataRefreshDueMock(),
    getMetadataSnapshot: () => getMetadataSnapshotMock(),
    getMetadataContractVersion: () => getMetadataContractVersionMock(),
    getRelayRuntimeConfig: () => getRelayRuntimeConfigMock(),
  };
});

// Keep side effects from the other storage-related modules to a minimum.
vi.mock('../../infra/storage/migration', () => ({
  migrateToPartitionedStorage: vi.fn(async () => {}),
}));
vi.mock('../../infra/storage/partition', async () => {
  const actual = await vi.importActual<typeof import('../../infra/storage/partition')>(
    '../../infra/storage/partition',
  );
  return {
    ...actual,
    getActiveUID: vi.fn(async () => 'guest'),
    setActiveUID: vi.fn(async () => {}),
    copyGuestImages: vi.fn(() => {}),
  };
});
vi.mock('../../infra/storage/idb', async () => {
  const actual = await vi.importActual<typeof import('../../infra/storage/idb')>(
    '../../infra/storage/idb',
  );
  return {
    ...actual,
    resetDBConnection: vi.fn(),
    getAllConversations: vi.fn(async () => []),
    putConversation: vi.fn(async () => {}),
    putProvider: vi.fn(async () => {}),
    putFolder: vi.fn(async () => {}),
  };
});
vi.mock('../../infra/storage/image-store', () => ({
  resetImageDBConnection: vi.fn(),
}));

import { createAppStore } from '../store/app-store';
import { bootstrapApp } from '../bootstrap';

// This file replaces resetDBConnection with a no-op while getDB stays actual, so it really does
// open a connection on the global fake-indexeddb instance and never closes it.
// `fake-indexeddb/auto` installs a process-wide global: later test files in the same fork get a
// fresh idb module instance (dbPromise=null, so their own resetDBConnection has nothing to
// close), but the leftover connection is still attached to the global DB. Their deleteDatabase()
// is then blocked and putConversation() hangs forever on open, which shows up as a 5000ms
// timeout. Running this file together with conversation-bootstrap.test.ts reproduces it, while
// each file alone passes.
afterAll(async () => {
  const actual = await vi.importActual<typeof import('../../infra/storage/idb')>(
    '../../infra/storage/idb',
  );
  actual.resetDBConnection();
});

describe('bootstrapApp hydrationPhase safety net', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Let hydrateStore succeed so the test focuses on a failure in the metadata stage.
    hydrateStoreMock.mockImplementation(async () => {});
    initMetadataMock.mockImplementation(async () => {});
    refreshMetadataMock.mockImplementation(async () => {});
    isMetadataRefreshDueMock.mockReturnValue(false);
    getMetadataSnapshotMock.mockImplementation(() => null);
    getMetadataContractVersionMock.mockImplementation(() => 1);
  });

  it('converges hydrationPhase to "ready" when hydrateMetadataAndReconcileProviders throws', async () => {
    // Make hydrateMetadataAndReconcileProviders throw outside the withBudget try/catch:
    // getMetadataSnapshot is called after the catch, so the error reaches the outer try/finally
    // in bootstrapApp.
    getMetadataSnapshotMock.mockImplementation(() => {
      throw new Error('simulated metadata snapshot failure');
    });

    const store = createAppStore();
    const signal = { cancelled: false };

    // The inner throw must not propagate; the outer finally still pushes hydrationPhase to ready.
    await expect(bootstrapApp(store, signal)).resolves.toBeDefined();

    expect(store.getState().hydrationPhase).toBe('ready');
  });

  it('keeps a fresh metadata snapshot off the blocking bootstrap refresh path', async () => {
    isMetadataRefreshDueMock.mockReturnValue(false);

    await bootstrapApp(createAppStore(), { cancelled: false });

    expect(initMetadataMock).toHaveBeenCalledTimes(1);
    expect(isMetadataRefreshDueMock).toHaveBeenCalledTimes(1);
    expect(refreshMetadataMock).not.toHaveBeenCalled();
  });

  it('blocks on refresh when the metadata TTL says the snapshot is due', async () => {
    isMetadataRefreshDueMock.mockReturnValue(true);

    await bootstrapApp(createAppStore(), { cancelled: false });

    expect(initMetadataMock).toHaveBeenCalledTimes(1);
    expect(isMetadataRefreshDueMock).toHaveBeenCalledTimes(1);
    expect(refreshMetadataMock).toHaveBeenCalledTimes(1);
  });

  it('writes refreshed official model metadata when enabled model ids are unchanged', async () => {
    const persistedProvider = {
        id: 'P1',
        kind: 'openAI',
        status: { kind: 'connected' },
        models: [{
          id: 'gpt-4o',
          name: 'GPT-4o',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        }],
        catalogModels: [],
        apiKey: 'sk-test',
        apiKeyPreview: 'test',
      } as const;
    const store = createAppStore();
    hydrateStoreMock.mockImplementation(async (targetStore) => {
      targetStore.setState({ providers: [persistedProvider] });
    });
    getMetadataSnapshotMock.mockImplementation(() => ({
      providers: {
        openAI: {
          defaultModelId: 'gpt-4o',
          models: {
            'gpt-4o': {
              canonicalModelId: 'gpt-4o',
              displayName: 'GPT-4o',
              capabilities: ['text', 'image', 'file', 'web'],
              profiles: { webSearch: 'oai_responses_web' },
              transport: 'openai_responses',
              pricingStatus: 'priced',
              pricing: { promptPerMToken: 2.5, completionPerMToken: 10 },
              uiHints: { badgeOrder: ['image', 'file', 'web'] },
            },
          },
        },
      },
    }));

    await expect(bootstrapApp(store, { cancelled: false })).resolves.toBeDefined();

    const model = store.getState().providers[0]?.models[0];
    expect(model?.capabilities).toEqual(['text', 'image', 'file', 'web']);
    expect(model?.webSearchProfile).toBe('oai_responses_web');
    expect(model?.transport).toBe('openai_responses');
  });

  it('converges hydrationPhase to "ready" when hydrateStore throws early', async () => {
    hydrateStoreMock.mockImplementation(async () => {
      throw new Error('simulated hydrate failure');
    });

    const store = createAppStore();
    const signal = { cancelled: false };

    await expect(bootstrapApp(store, signal)).resolves.toBeDefined();

    expect(store.getState().hydrationPhase).toBe('ready');
  });
});
