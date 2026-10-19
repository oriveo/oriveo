/**
 * Startup: hydrate the local IndexedDB stores into the app store, then hand control to the UI.
 *
 * Everything here is local, so there is no network step to wait on and no reason for the first
 * paint to depend on one.
 */

import type { StoreApi } from 'zustand';
import type { AIModel, Provider } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { hydrateStore } from './store/persistence';
import { createMemoryItemRepository } from './memory/memory-item-repository';
import { hydrateMcpStore } from './mcp/mcp-store';
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
import { backfillOfficialEndpointSources } from './providers/endpoint-source';
import { migrateLlamacppConnectionsToChatChannelIfNeeded } from './providers/llamacpp-channel-migration';
import {
  ensureProviderCatalogs,
  getMetadataContractVersion,
  getMetadataSnapshot,
  getProviderCatalogStatus,
  getRelayRuntimeConfig,
  initMetadata,
  isMetadataRefreshDue,
  refreshMetadata,
  setMetadataCatalogDemandSource,
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

async function hydrateStoreForPartition(store: Store, uid: string): Promise<void> {
  await hydrateStore(store);
  startMemoryLegacySync(store, uid);
}

/** The memoryText subscription of each store; the previous partition's one is unsubscribed before switching. */
const memoryLegacySyncByStore = new WeakMap<Store, () => void>();

/**
 * Memory item legacy sync: after hydration, run reconcileLegacy once (migration / edits coming back from older clients),
 * then run it again whenever memoryText or its digest changes. It does not block startup.
 */
function startMemoryLegacySync(store: Store, uid: string): void {
  memoryLegacySyncByStore.get(store)?.();
  memoryLegacySyncByStore.delete(store);
  try {
    const repository = createMemoryItemRepository({ store, uid, deviceId: getOrCreateStableWebDeviceId() });
    const reconcile = () => {
      if (getActiveUIDSync() !== uid) return;
      void repository.reconcileLegacy().catch((error) => reportSilentError('memory-items.reconcileLegacy', error));
    };
    const unsubscribe = store.subscribe((state, prev) => {
      if (
        state.preferences.memoryText !== prev.preferences.memoryText
        || state.preferences.memoryTextDigest !== prev.preferences.memoryTextDigest
      ) {
        reconcile();
      }
    });
    memoryLegacySyncByStore.set(store, unsubscribe);
    reconcile();
  } catch (error) {
    reportSilentError('memory-items.start', error);
  }
}

const WEB_DEVICE_ID_KEY = 'oriveo.sync.deviceId';

/** A device id that stays stable across launches, used to attribute memory item mutations. */
export function getOrCreateStableWebDeviceId(): string {
  if (typeof localStorage === 'undefined') {
    return 'web-device-unknown';
  }
  const existing = localStorage.getItem(WEB_DEVICE_ID_KEY);
  if (existing && existing.length > 0) {
    return existing;
  }
  const fallback = `web-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
  const generated = typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function'
    ? `web-${crypto.randomUUID()}`
    : fallback;
  localStorage.setItem(WEB_DEVICE_ID_KEY, generated);
  return generated;
}

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
    // When the probe gets no callback in time it returns `slow` so startup can continue; once the
    // same open() settles, the revised result is written back and the degraded-mode banner
    // follows the final verdict.
    const storageHealth = await detectStorageHealth({
      onRevised: (revised) => store.setState({ storageHealth: revised }),
    }).catch(() => null);
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
    await hydrateStoreForPartition(store, 'guest');
    await hydrateMcpStore('guest');
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

/**
 * The set of catalogs metadata needs comes from the configured providers. The source is registered
 * once, and when the provider set changes (a provider is added or a backup is restored) only the
 * providers that newly appeared and are not loaded yet are fetched.
 */
let metadataDemandStore: Store | null = null;
let metadataDemandUnsubscribe: (() => void) | null = null;

function metadataCatalogDemand(providers: AppStore['providers']): { providerKinds: string[]; hasRelay: boolean } {
  const kinds = new Set<string>();
  let hasRelay = false;
  for (const provider of providers) {
    if (provider.kind === 'relay') {
      hasRelay = true;
      continue;
    }
    kinds.add(provider.kind);
  }
  return { providerKinds: [...kinds], hasRelay };
}

function ensureMetadataCatalogDemand(store: Store): void {
  setMetadataCatalogDemandSource(() => metadataCatalogDemand(store.getState().providers));
  if (metadataDemandStore === store && metadataDemandUnsubscribe) return;
  metadataDemandUnsubscribe?.();
  metadataDemandStore = store;
  metadataDemandUnsubscribe = store.subscribe((state, prevState) => {
    if (state.providers === prevState.providers) return;
    const demand = metadataCatalogDemand(state.providers);
    const pendingKinds = demand.providerKinds.filter(
      (kind) => getProviderCatalogStatus(kind) === 'pending',
    );
    if (demand.hasRelay && !prevState.providers.some((provider) => provider.kind === 'relay')) {
      for (const kind of getRelayRuntimeConfig().officialProviderWhitelist) {
        if (getProviderCatalogStatus(kind) === 'pending') pendingKinds.push(kind);
      }
    }
    if (pendingKinds.length > 0) void ensureProviderCatalogs(pendingKinds).catch(() => {});
  });
}

async function hydrateMetadataAndReconcileProviders(store: Store): Promise<void> {
  const started = Date.now();
  ensureMetadataCatalogDemand(store);

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
      // Enrich each model by its own protocol (the protocol is a property of the model).
      const enrich = (models: AIModel[]) => models.flatMap((model) => enrichRelayCatalog(
        [model], resolveRelaySelectionTransport(provider, model), relayRuntimeConfig,
      ));
      const enrichedModels = enrich(provider.models);
      const enrichedCatalogModels = provider.catalogModels.length > 0
        ? enrich(provider.catalogModels)
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
  // Backfill endpointSource on unclassified official records from metadata; written locally only (updatedAt untouched, nothing uploaded).
  await backfillOfficialEndpointSources(store);
  // One-time switch of existing llama.cpp native-channel connections to the chat channel (the marker is partitioned per uid and runs only once).
  await migrateLlamacppConnectionsToChatChannelIfNeeded(store);
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
