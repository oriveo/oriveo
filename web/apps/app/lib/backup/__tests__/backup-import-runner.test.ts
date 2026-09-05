import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import type { ImportPreview, ImportResult } from '../backup-types';

const mocks = vi.hoisted(() => ({
  executeImport: vi.fn(),
  getAllProviders: vi.fn(),
  getSyncAdapter: vi.fn(),
  hydrateStore: vi.fn(),
  tryGetVanillaStore: vi.fn(),
  unregisterPendingProviderDeletion: vi.fn(),
  activeUID: 'user-1',
}));

vi.mock('../backup-import', () => ({
  executeImport: (...args: unknown[]) => mocks.executeImport(...args),
}));

vi.mock('../../infra/storage/idb', () => ({
  getAllProviders: (...args: unknown[]) => mocks.getAllProviders(...args),
}));

vi.mock('../../core/sync-port', () => ({
  getSyncAdapter: (...args: unknown[]) => mocks.getSyncAdapter(...args),
  unregisterPendingProviderDeletion: (...args: unknown[]) => (
    mocks.unregisterPendingProviderDeletion(...args)
  ),
}));

vi.mock('../../core/store/persistence', () => ({
  hydrateStore: (...args: unknown[]) => mocks.hydrateStore(...args),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: (...args: unknown[]) => mocks.tryGetVanillaStore(...args),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUIDSync: () => mocks.activeUID,
}));

import { executeImportAndRefreshStore } from '../backup-import-runner';
import { serializeProviderSyncMutation } from '../../core/providers/provider-sync-serial';

const preview = {
  backupFile: {
    version: 1,
    createdAt: '2026-06-19T00:00:00.000Z',
    appVersion: '1.0.0',
    platform: 'Web',
    containsKeys: false,
    encryptedKeys: null,
    data: { conversations: [], providers: [] },
  },
  imageEntries: new Map(),
} as unknown as ImportPreview;

const result = {
  conversationsImported: 1,
  conversationsSkipped: 0,
  conversationsMerged: 0,
  providersImported: 0,
  providersSkipped: 0,
  providersMerged: 0,
  skillsImported: 0,
  skillsSkipped: 0,
  skillsMerged: 0,
  skillsRequiringKnowledgeReupload: 0,
  notesImported: 0,
  notesSkipped: 0,
  notesMerged: 0,
  noteFoldersImported: 0,
  noteFoldersSkipped: 0,
  noteFoldersMerged: 0,
  keysRestored: 0,
  imagesRestored: 0,
  restoredPreferences: false,
  restoredLastUsedModel: false,
} satisfies ImportResult;

describe('executeImportAndRefreshStore', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.activeUID = 'user-1';
    mocks.getAllProviders.mockResolvedValue([]);
    mocks.getSyncAdapter.mockReturnValue(null);
    const store = {
      getState: vi.fn(() => ({ hydrationPhase: 'ready' })),
      setState: vi.fn(),
    };
    mocks.tryGetVanillaStore.mockReturnValue(store);
    mocks.hydrateStore.mockResolvedValue(undefined);
    mocks.executeImport.mockResolvedValue(result);
  });

  it('closes the persistence subscribers for the whole replaceAll critical section, and persists user edits normally once it is ready again', async () => {
    type FakeState = {
      hydrationPhase: 'metadata-pending' | 'ready';
      providers: string[];
    };
    let state: FakeState = { hydrationPhase: 'ready', providers: [] };
    const listeners = new Set<(next: FakeState) => void>();
    const store = {
      getState: vi.fn(() => state),
      setState: vi.fn((partial: Partial<FakeState>) => {
        state = { ...state, ...partial };
        listeners.forEach((listener) => listener(state));
      }),
      subscribe: vi.fn((listener: (next: FakeState) => void) => {
        listeners.add(listener);
        return () => listeners.delete(listener);
      }),
    };
    mocks.tryGetVanillaStore.mockReturnValue(store);

    const persistSpy = vi.fn();
    let previousProviders = state.providers;
    store.subscribe((next) => {
      if (next.hydrationPhase !== 'ready') {
        previousProviders = next.providers;
        return;
      }
      if (next.providers !== previousProviders) persistSpy(next.providers);
      previousProviders = next.providers;
    });

    mocks.executeImport.mockImplementation(async () => {
      store.setState({ providers: ['imported'] });
      return result;
    });
    mocks.hydrateStore.mockImplementation(async () => {
      store.setState({ providers: ['hydrated'] });
    });

    await executeImportAndRefreshStore(preview, 'replaceAll');

    expect(persistSpy).not.toHaveBeenCalled();
    expect(state.hydrationPhase).toBe('ready');

    store.setState({ providers: ['user-change'] });
    expect(persistSpy).toHaveBeenCalledOnce();
    expect(persistSpy).toHaveBeenCalledWith(['user-change']);
  });

  it('runs the import, clears the stale deletion queue for the restored providers, then refreshes the store', async () => {
    const calls: string[] = [];
    mocks.getAllProviders.mockImplementation(async () => {
      calls.push('providers');
      return [{ id: 'p1', kind: 'openAI' }] as Provider[];
    });
    mocks.executeImport.mockImplementation(async () => {
      calls.push('execute');
      return result;
    });
    mocks.hydrateStore.mockImplementation(async () => {
      calls.push('hydrate');
    });

    await expect(executeImportAndRefreshStore(preview, 'replaceAll', 'secret')).resolves.toBe(result);

    expect(calls).toEqual(['execute', 'providers', 'hydrate']);
    expect(mocks.executeImport).toHaveBeenCalledWith(preview, 'replaceAll', 'secret', 'user-1');
    // A deletion still queued for a provider the user just restored would delete it again.
    expect(mocks.unregisterPendingProviderDeletion).toHaveBeenCalledWith('user-1', 'p1');
  });

  it('holds an exclusive provider write sequence for the whole replaceAll critical section', async () => {
    const calls: string[] = [];
    let releaseImport: (() => void) | undefined;
    mocks.executeImport.mockImplementation(async () => {
      calls.push('replace-start');
      await new Promise<void>((resolve) => { releaseImport = resolve; });
      calls.push('replace-finished');
      return result;
    });

    const importing = executeImportAndRefreshStore(preview, 'replaceAll');
    await vi.waitFor(() => expect(releaseImport).toBeTypeOf('function'));
    const concurrent = serializeProviderSyncMutation('user-1', () => {
      calls.push('concurrent-enqueued');
    });
    expect(calls).toEqual(['replace-start']);

    releaseImport?.();
    await Promise.all([importing, concurrent]);

    expect(calls).toEqual(['replace-start', 'replace-finished', 'concurrent-enqueued']);
  });

  it('still passes the original UID down and aborts when the partition switches after the runner checked it', async () => {
    mocks.executeImport.mockImplementation(async () => {
      mocks.activeUID = 'user-2';
      return result;
    });

    await expect(executeImportAndRefreshStore(preview, 'replaceAll'))
      .rejects.toThrow('Backup import storage partition changed from user-1');

    expect(mocks.executeImport).toHaveBeenCalledWith(preview, 'replaceAll', undefined, 'user-1');
    expect(mocks.hydrateStore).not.toHaveBeenCalled();
    const store = mocks.tryGetVanillaStore();
    expect(store.setState).toHaveBeenCalledWith({ hydrationPhase: 'metadata-pending' });
    expect(store.setState).not.toHaveBeenCalledWith({ hydrationPhase: 'ready' });
  });

  it.each(['merge', 'importNew'] as const)(
    '%s mode skips the critical section and only refreshes the local store',
    async (mode) => {
      const calls: string[] = [];
      const adapter = {
        isActive: true,
        boundUID: 'user-1',
        pauseSyncListenersForCriticalSection: vi.fn(),
        resumeSyncListenersAfterCriticalSection: vi.fn(),
      };
      mocks.getSyncAdapter.mockReturnValue(adapter);
      mocks.executeImport.mockImplementation(async () => {
        calls.push('execute');
        return result;
      });
      mocks.hydrateStore.mockImplementation(async () => {
        calls.push('hydrate');
      });

      await expect(executeImportAndRefreshStore(preview, mode, 'secret')).resolves.toBe(result);

      expect(adapter.pauseSyncListenersForCriticalSection).not.toHaveBeenCalled();
      expect(adapter.resumeSyncListenersAfterCriticalSection).not.toHaveBeenCalled();
      expect(calls).toEqual(['execute', 'hydrate']);
    },
  );

  it('restores the replaceAll listeners when the local import fails', async () => {
    const adapter = {
      isActive: true,
      boundUID: 'user-1',
      pauseSyncListenersForCriticalSection: vi.fn(),
      resumeSyncListenersAfterCriticalSection: vi.fn(),
    };
    mocks.getSyncAdapter.mockReturnValue(adapter);
    mocks.executeImport.mockRejectedValue(new Error('WRONG_PASSWORD'));

    await expect(executeImportAndRefreshStore(preview, 'replaceAll', 'bad'))
      .rejects.toThrow('WRONG_PASSWORD');

    expect(adapter.pauseSyncListenersForCriticalSection).toHaveBeenCalledTimes(1);
    expect(adapter.resumeSyncListenersAfterCriticalSection).toHaveBeenCalledTimes(1);
  });
});
