/**
 * Startup: hydrate the local IndexedDB stores into the app store, then hand control to the UI.
 *
 * Everything here is local, so there is no network step to wait on and no reason for the first
 * paint to depend on one.
 */

import type { StoreApi } from 'zustand';
import type { Provider } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { hydrateStore } from './store/persistence';
import {
  getActiveUID,
  getActiveUIDSync,
  setActiveUID,
} from '../infra/storage/partition';
import {
  resetDBConnection,
} from '../infra/storage/idb';
import { resetImageDBConnection } from '../infra/storage/image-store';
import { migrateToPartitionedStorage } from '../infra/storage/migration';
import { detectStorageHealth, reportStorageHealth } from './storage-health';
import { reportSilentError } from '../sentry/report-silent';
import { collapseProvidersToDeterministicIds } from './provider-id-migration';
import {
  getMetadataContractVersion,
  getMetadataSnapshot,
  getRelayRuntimeConfig,
  initMetadata,
  isMetadataRefreshDue,
  refreshMetadata,
} from './metadata/metadata-client';
import { isContractVersionDegraded } from './metadata/metadata-runtime';
import { refreshAllSkills } from './skills/ops';
import { installStreamLifecycleListeners } from './chat/lifecycle-listeners';
import { buildOfficialEnabledModels } from './providers/official-model-sync';
import type { CatalogMetadataInput } from './providers/catalog-resolver';
import { enrichRelayCatalog } from './providers/relay-official-catalog-match';
import { resolveRelaySelectionTransport } from './providers/provider-selection-snapshot';

type Store = StoreApi<AppStore>;

const METADATA_HYDRATE_BUDGET_MS = 1500;

export interface BootstrapResult {
  initialUser: null;
  authResolution: 'observed' | 'timeout' | 'error' | 'cancelled';
}

function switchDB(uid: string) {
  resetDBConnection();
  resetImageDBConnection();
  return setActiveUID(uid);
}

export async function bootstrapApp(
  store: Store,
  signal: { cancelled: boolean },
): Promise<BootstrapResult> {
  store.setState({ hydrationPhase: 'booting' });
  installStreamLifecycleListeners();

  try {
    const storageHealth = await detectStorageHealth().catch(() => null);
    if (storageHealth) {
      store.setState({ storageHealth });
    }

    try {
      await migrateToPartitionedStorage();
    } catch (err) {
      reportSilentError('bootstrap.partition-migration', err);
    }
    if (signal.cancelled) return { initialUser: null, authResolution: 'cancelled' };

    const currentUID = await getActiveUID();
    if (currentUID !== 'guest') {
      await switchDB('guest');
      if (signal.cancelled) return { initialUser: null, authResolution: 'cancelled' };
    } else if (getActiveUIDSync() !== 'guest') {
      await switchDB('guest');
    }

    store.setState({
      account: null,
      providers: [],
      conversations: [],
      activeConversationId: null,
    });
    await hydrateStore(store);
    if (signal.cancelled) return { initialUser: null, authResolution: 'cancelled' };

    store.setState({ hydrationPhase: 'metadata-pending' });
    await hydrateMetadataAndReconcileProviders(store);
    if (signal.cancelled) return { initialUser: null, authResolution: 'cancelled' };

    store.setState({ hydrationPhase: 'ready' });
    refreshAllSkills(store).catch(() => {});
    if (storageHealth) reportStorageHealth(storageHealth);
    return { initialUser: null, authResolution: 'observed' };
  } catch (err) {
    console.error('[bootstrap] bootstrapApp failed:', err);
    return { initialUser: null, authResolution: 'error' };
  } finally {
    if (store.getState().hydrationPhase !== 'ready') {
      try {
        store.setState({ hydrationPhase: 'ready' });
      } catch {
        /* ignore */
      }
    }
  }
}

async function hydrateMetadataAndReconcileProviders(store: Store): Promise<void> {
  const started = Date.now();

  try {
    await withBudget(
      (async () => {
        await initMetadata();
        if (isMetadataRefreshDue()) {
          await refreshMetadata();
        }
      })(),
      METADATA_HYDRATE_BUDGET_MS,
    );
  } catch (err) {
    const elapsed = Date.now() - started;
    console.warn(
      `[bootstrap] metadata.hydrate.slow: ${elapsed}ms over ${METADATA_HYDRATE_BUDGET_MS}ms`,
      err,
    );
  }

  const snapshot = getMetadataSnapshot() as CatalogMetadataInput | null;
  const contractVersion = getMetadataContractVersion();
  const degraded = isContractVersionDegraded(contractVersion);
  if (degraded) {
    console.warn(
      `[bootstrap] metadata.contract_version.mismatch: client supports older contract; contractVersion=${contractVersion}`,
    );
  }
  const providers = store.getState().providers;
  if (providers.length === 0) return;

  let changed = false;
  const relayRuntimeConfig = getRelayRuntimeConfig();
  const nextProviders = providers.map((provider) => {
    if (provider.authMode === 'subscription') {
      return provider;
    }

    if (provider.kind === 'relay') {
      const transport = resolveRelaySelectionTransport(provider);
      const enrichedModels = enrichRelayCatalog(provider.models, transport, relayRuntimeConfig);
      const enrichedCatalogModels = provider.catalogModels.length > 0
        ? enrichRelayCatalog(provider.catalogModels, transport, relayRuntimeConfig)
        : provider.catalogModels;
      const sameModels = arraysShallowEqualByEnrichedFields(provider.models, enrichedModels);
      const sameCatalog = arraysShallowEqualByEnrichedFields(provider.catalogModels, enrichedCatalogModels);
      if (sameModels && sameCatalog) {
        return provider;
      }
      changed = true;
      return { ...provider, models: enrichedModels, catalogModels: enrichedCatalogModels };
    }

    const build = buildOfficialEnabledModels(provider.kind, snapshot, {
      prevEnabledIds: provider.models.map((m) => m.id),
      prevEnabledModels: provider.models,
      prevCatalogModels: provider.catalogModels,
      prevDefaultModelId: provider.models.find((m) => m.isDefault)?.id,
      updatedAt: provider.updatedAt,
    }, {
      contractVersionDegraded: degraded,
      repairLegacyAutoEnabledAll: true,
    });

    if (build.prunedModelIds.length > 0) {
      console.warn(
        `[bootstrap] metadata.resolver.miss: pruned ${build.prunedModelIds.length} ids from ${provider.kind}`,
        build.prunedModelIds,
      );
    }

    if (build.models.length === 0 && (provider.models.length > 0 || provider.catalogModels.length > 0)) {
      return provider;
    }

    const sameModels = arraysShallowEqualByMetadataFields(provider.models, build.models);
    const sameCatalog = provider.catalogModels.length === 0;
    if (sameModels && sameCatalog) {
      return provider;
    }
    changed = true;
    return { ...provider, models: build.models, catalogModels: [] };
  });

  if (changed) {
    store.setState({ providers: nextProviders });
  }

  await collapseProvidersToDeterministicIds(store);
}

function arraysShallowEqualByMetadataFields(
  lhs: Array<Provider['models'][number]>,
  rhs: Array<Provider['models'][number]>,
): boolean {
  if (lhs.length !== rhs.length) return false;
  for (let i = 0; i < lhs.length; i += 1) {
    const a = lhs[i];
    const b = rhs[i];
    if (
      a.id !== b.id
      || a.canonicalModelId !== b.canonicalModelId
      || a.name !== b.name
      || a.isDefault !== b.isDefault
      || a.isRecommended !== b.isRecommended
      || a.priceTier !== b.priceTier
      || a.summary !== b.summary
      || a.groupKey !== b.groupKey
      || a.groupName !== b.groupName
      || a.sortRank !== b.sortRank
      || a.promptPrice !== b.promptPrice
      || a.completionPrice !== b.completionPrice
      || a.contextLength !== b.contextLength
      || a.reasoningModeAvailable !== b.reasoningModeAvailable
      || a.reasoningProfile !== b.reasoningProfile
      || a.webSearchProfile !== b.webSearchProfile
      || a.imageGenProfile !== b.imageGenProfile
      || a.transport !== b.transport
      || a.minClientVersion !== b.minClientVersion
      || !arraysEqual(a.capabilities, b.capabilities)
      || !arraysEqual(a.badgeOrder, b.badgeOrder)
    ) {
      return false;
    }
  }
  return true;
}

function arraysEqual<T>(lhs: T[] | undefined, rhs: T[] | undefined): boolean {
  if (!lhs || lhs.length === 0) return !rhs || rhs.length === 0;
  if (!rhs || lhs.length !== rhs.length) return false;
  return lhs.every((value, index) => value === rhs[index]);
}

function arraysShallowEqualByEnrichedFields(
  lhs: Array<{
    id: string;
    priceTier: string;
    promptPrice?: number;
    completionPrice?: number;
    canonicalModelId?: string;
    capabilities: string[];
  }>,
  rhs: Array<{
    id: string;
    priceTier: string;
    promptPrice?: number;
    completionPrice?: number;
    canonicalModelId?: string;
    capabilities: string[];
  }>,
): boolean {
  if (lhs.length !== rhs.length) return false;
  for (let i = 0; i < lhs.length; i += 1) {
    const a = lhs[i];
    const b = rhs[i];
    if (
      a.id !== b.id
      || a.priceTier !== b.priceTier
      || a.promptPrice !== b.promptPrice
      || a.completionPrice !== b.completionPrice
      || a.canonicalModelId !== b.canonicalModelId
      || a.capabilities.length !== b.capabilities.length
      || a.capabilities.some((cap, idx) => cap !== b.capabilities[idx])
    ) {
      return false;
    }
  }
  return true;
}

function withBudget<T>(promise: Promise<T>, budgetMs: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('metadata.hydrate.budget_exceeded')), budgetMs);
    promise
      .then((value) => {
        clearTimeout(timer);
        resolve(value);
      })
      .catch((err) => {
        clearTimeout(timer);
        reject(err);
      });
  });
}
