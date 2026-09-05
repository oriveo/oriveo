import type { ImportMode, ImportPreview, ImportResult } from './backup-types';
import { executeImport } from './backup-import';
import { getAllProviders } from '../infra/storage/idb';
import { getSyncAdapter } from '../core/sync-port';
import { hydrateStore } from '../core/store/persistence';
import { tryGetVanillaStore } from '../../providers/StoreProvider';
import { getActiveUIDSync } from '../infra/storage/partition';
import { unregisterPendingProviderDeletion } from '../core/sync-port';
import { serializeProviderSyncMutation } from '../core/providers/provider-sync-serial';

function assertExpectedUID(expectedUID: string): void {
  if (getActiveUIDSync() !== expectedUID) {
    throw new Error(`Backup import storage partition changed from ${expectedUID}`);
  }
}

async function hydrateActiveStoreAfterImport(expectedUID?: string): Promise<void> {
  if (expectedUID) assertExpectedUID(expectedUID);
  const store = tryGetVanillaStore();
  if (!store) return;
  await hydrateStore(store, expectedUID);
  if (expectedUID) assertExpectedUID(expectedUID);
}

/**
 * Runs a backup import and brings the running app back in step with the database it just rewrote.
 *
 * `replaceAll` is the destructive mode, and it is the only one that needs a critical section: it is
 * run inside the per-profile provider mutation queue so a concurrent provider edit cannot interleave
 * with it, persistence subscribers are held closed for its duration so their fire-and-forget writes
 * cannot land in a partition that is being replaced, and the store is re-hydrated from the database
 * afterwards. The other modes only add rows, so they go straight through.
 */
export async function executeImportAndRefreshStore(
  preview: ImportPreview,
  mode: ImportMode,
  password?: string,
): Promise<ImportResult> {
  if (mode !== 'replaceAll') {
    return executeImportAndRefreshStoreImpl(preview, mode, password);
  }

  const uid = getActiveUIDSync();
  return serializeProviderSyncMutation(uid, () => (
    executeImportAndRefreshStoreImpl(preview, mode, password, uid)
  ));
}

async function executeImportAndRefreshStoreImpl(
  preview: ImportPreview,
  mode: ImportMode,
  password?: string,
  serializedUID?: string,
): Promise<ImportResult> {
  if (serializedUID && getActiveUIDSync() !== serializedUID) {
    throw new Error(`Backup import storage partition changed from ${serializedUID}`);
  }
  const adapter = getSyncAdapter();
  if (serializedUID && adapter?.isActive && adapter.boundUID !== serializedUID) {
    throw new Error(`Backup import sync adapter changed from ${serializedUID}`);
  }
  const shouldPauseListeners = mode === 'replaceAll' && adapter?.isActive === true;
  const store = mode === 'replaceAll' ? tryGetVanillaStore() : null;
  const previousHydrationPhase = store?.getState().hydrationPhase ?? 'ready';
  const shouldPausePersistence = serializedUID !== undefined && store !== null;

  if (shouldPauseListeners) {
    adapter.pauseSyncListenersForCriticalSection();
  }
  if (shouldPausePersistence && store) {
    // store.setState during replaceAll only displays the import result; the main database has
    // already been written in a single transaction. Persistence subscribers are paused so their
    // fire-and-forget writes cannot land in the new partition during an await.
    store.setState({ hydrationPhase: 'metadata-pending' });
  }

  try {
    const result = await executeImport(preview, mode, password, serializedUID);
    if (serializedUID && getActiveUIDSync() !== serializedUID) {
      throw new Error(`Backup import storage partition changed from ${serializedUID}`);
    }
    if (mode === 'replaceAll' && serializedUID && getActiveUIDSync() === serializedUID) {
      // The imported providers are present again, so any deletion still queued for them is stale:
      // leaving it would delete a provider the user just restored.
      const providers = await getAllProviders(serializedUID);
      assertExpectedUID(serializedUID);
      for (const provider of providers) {
        unregisterPendingProviderDeletion(serializedUID, provider.id);
      }
    }
    await hydrateActiveStoreAfterImport(serializedUID);
    return result;
  } finally {
    const canResumeCapturedAdapter = !serializedUID || (
      getActiveUIDSync() === serializedUID && adapter?.boundUID === serializedUID
    );
    if (shouldPauseListeners && adapter.isActive && canResumeCapturedAdapter) {
      adapter.resumeSyncListenersAfterCriticalSection();
    }
    if (
      shouldPausePersistence &&
      getActiveUIDSync() === serializedUID &&
      store !== null &&
      store === tryGetVanillaStore()
    ) {
      store.setState({ hydrationPhase: previousHydrationPhase });
    }
  }
}
