import type { StoreApi } from 'zustand';
import type { AIModel, ModelCapability, Provider } from '@oriveo/shared';
import type { AppStore } from './store/app-store';
import { sameNormalizedID } from '../utils/id-utils';
import { selectResolvedCatalog } from './store/selectors';
import { findModelByIdentifier } from './providers/model-display-lookup';
import { enrichRelayCatalog } from './providers/relay-official-catalog-match';
import { resolveRelaySelectionTransport } from './providers/provider-selection-snapshot';
import { getRelayRuntimeConfig } from './metadata/metadata-client';
import { getActiveUIDSync } from '../infra/storage/partition';
import { clearToolCallMemoryForConnection } from './chat/capability-recovery-runtime';

/**
 * Default capability ceiling for a manually entered model: general chat.
 * `imageGeneration` is excluded because image generation is a dedicated mode for a handful of
 * specific models (gpt-image-*, dall-e-* and so on) and makes a poor default for a manual entry;
 * image models that match the backend catalog have it injected by the enrichment path.
 *
 * The actual entry point is narrowed further by the model capabilities and the transport/runtime route.
 */
export const DEFAULT_MANUAL_MODEL_CAPABILITIES: ModelCapability[] = ['text'];

function uniqueModels(models: AIModel[]): AIModel[] {
  const seen = new Set<string>();
  return models.filter((model) => {
    if (seen.has(model.id)) return false;
    seen.add(model.id);
    return true;
  });
}

/**
 * Runs one catalog enrichment pass over a Relay provider's models and writes the result back.
 * Triggered on every `patchProviderModels` write.
 *
 * Why enrich on write: enriching at write time merges the persisted fields (priceTier, promptPrice,
 * completionPrice, canonicalModelId and so on) back into the model. Enriching lazily on read paths
 * only, such as chat selection and catalog views, left the ModelSwitcher main view reading
 * `provider.models` directly and showing the un-enriched placeholder state, for instance
 * priceTier='?' instead of the real tier for a manually entered model.
 *
 * When metadata has not loaded, `enrichRelayCatalog` runs with the default runtimeConfig and returns
 * unmatched models unchanged, so it is a safe no-op. Once loading finishes, bootstrap runs another
 * enrichment pass and writes it back (`hydrateMetadataAndReconcileProviders`).
 */
export function enrichRelayProviderModels(provider: Provider, models: AIModel[]): AIModel[] {
  if (provider.kind !== 'relay') return models;
  const transport = resolveRelaySelectionTransport(provider);
  return enrichRelayCatalog(models, transport, getRelayRuntimeConfig());
}

/**
 * Runs enrichment over a whole Relay provider's `models` and `catalogModels` and writes it back.
 * Used on the provider creation path (`addProvider`): `patchProviderModels` only covers model-level
 * writes, and creating a provider writes to the store through addProvider without going through it.
 *
 * Non-Relay providers are returned unchanged.
 */
export function enrichRelayProvider(provider: Provider): Provider {
  if (provider.kind !== 'relay') return provider;
  return {
    ...provider,
    models: enrichRelayProviderModels(provider, provider.models),
    catalogModels: enrichRelayProviderModels(provider, provider.catalogModels),
  };
}

function patchProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  models: AIModel[],
) {
  clearToolCallMemoryForConnection(getActiveUIDSync(), provider.id);
  const enriched = enrichRelayProviderModels(provider, models);
  store.getState().updateProvider(provider.id, {
    models: uniqueModels(enriched),
    status: { kind: 'connected' },
    updatedAt: new Date().toISOString(),
  });
}

function resolveProvider(store: StoreApi<AppStore>, provider: Provider): Provider {
  return store.getState().providers.find((item) => sameNormalizedID(item.id, provider.id)) ?? provider;
}

export function createManualModel(modelId: string, isDefault = false): AIModel {
  const trimmed = modelId.trim();
  const [groupName, ...rest] = trimmed.split('/');
  const hasGroup = rest.length > 0;

  return {
    id: trimmed,
    name: hasGroup ? rest.join('/') : trimmed,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault,
    // Empty-string placeholder. When the model matches the backend catalog, the enrichment path
    // overwrites it with the real tier; when it does not, keeping '' makes the UI showPriceTier
    // check false so no pill is rendered.
    priceTier: '',
    groupKey: hasGroup ? groupName : undefined,
    groupName: hasGroup ? groupName : undefined,
    isManual: true,
  };
}

export function createRelayManualModel(
  modelId: string,
  isDefault = false,
): AIModel {
  const model = createManualModel(modelId, isDefault);
  const capabilities = [...DEFAULT_MANUAL_MODEL_CAPABILITIES];
  return {
    ...model,
    capabilities,
    reasoningModeAvailable: capabilities.includes('reasoning'),
    imageGenProfile: capabilities.includes('imageGeneration') ? 'default' : undefined,
  };
}

export function enableProviderModel(
  store: StoreApi<AppStore>,
  provider: Provider,
  model: AIModel,
): AIModel {
  const latestProvider = resolveProvider(store, provider);
  const existing = latestProvider.models.find((item) => item.id === model.id);
  if (existing) return existing;

  patchProviderModels(store, latestProvider, [...latestProvider.models, model]);
  return model;
}

export function disableProviderModel(
  store: StoreApi<AppStore>,
  provider: Provider,
  modelId: string,
) {
  const latestProvider = resolveProvider(store, provider);
  patchProviderModels(
    store,
    latestProvider,
    latestProvider.models.filter((model) => model.id !== modelId),
  );
}

export function replaceProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  models: AIModel[],
) {
  patchProviderModels(store, resolveProvider(store, provider), models);
}

export function addManualProviderModels(
  store: StoreApi<AppStore>,
  provider: Provider,
  modelIds: string[],
): AIModel[] {
  const latestProvider = resolveProvider(store, provider);
  const existingIds = new Set(latestProvider.models.map((model) => model.id));
  const trimmedIds = [...new Set(modelIds.map((id) => id.trim()).filter(Boolean))];
  const newModels = trimmedIds
    .filter((id) => !existingIds.has(id))
    .map((id, index) => latestProvider.kind === 'relay'
      ? createRelayManualModel(id, latestProvider.models.length === 0 && index === 0)
      : createManualModel(id, latestProvider.models.length === 0 && index === 0));

  if (newModels.length === 0) {
    return [];
  }

  patchProviderModels(store, latestProvider, [...latestProvider.models, ...newModels]);
  return newModels;
}

export function findModelInProvider(
  provider: Provider | undefined,
  modelId: string | null | undefined,
): AIModel | undefined {
  if (!provider || !modelId) return undefined;

  return findModelByIdentifier(provider.models, modelId)
    ?? findModelByIdentifier(provider.catalogModels, modelId);
}

/** Whether a Provider still has catalog models available to add */
export function providerHasCatalogModels(provider: Provider): boolean {
  if (provider.kind === 'relay') return false;
  const resolved = selectResolvedCatalog(provider);
  return resolved.catalog.some((m) => !m.isEnabled);
}
