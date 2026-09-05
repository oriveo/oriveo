import type { AIModel, Provider } from '@oriveo/shared';
import { getProviderDefaultModelId, getRelayRuntimeConfig, resolveCatalogModel } from '../metadata/metadata-client';
import { buildCatalogModel } from './catalog-model';
import { findModelByIdentifier } from './model-display-lookup';
import { enrichRelayCatalog } from './relay-official-catalog-match';
import type { RelayTransportKey } from '../metadata/metadata-client';

export interface ProviderSelectionSnapshot {
  provider: Provider;
  enabledModels: AIModel[];
  currentModel: AIModel | null;
  defaultModel: AIModel | null;
}

interface SelectionOptions {
  requestedModelId?: string | null;
}

export function createProviderSelectionSnapshot(
  provider: Provider | undefined,
  options: SelectionOptions = {},
): ProviderSelectionSnapshot | null {
  if (!provider) return null;

  const enabledModels = provider.kind === 'relay'
    ? enrichRelayCatalog(provider.models, resolveRelaySelectionTransport(provider), getRelayRuntimeConfig())
    : provider.models;
  const defaultModel = resolveDefaultEnabledModel(provider, enabledModels);
  const currentModel = findModelByIdentifier(enabledModels, options.requestedModelId)
    ?? resolveHistoricalModel(provider, options.requestedModelId)
    ?? defaultModel;

  return {
    provider,
    enabledModels,
    currentModel: currentModel ?? null,
    defaultModel,
  };
}

/**
 * Resolve the effective transport of a Relay provider: prefer the already resolved one, and fall
 * back to the transport the user requested when it is not auto. Exported so write-time enrichment
 * (`provider-model-ops.ts:patchProviderModels`) and bootstrap re-enrichment can share it instead
 * of repeating the resolution at several call sites.
 */
export function resolveRelaySelectionTransport(
  provider: Provider,
): RelayTransportKey | undefined {
  if (provider.relayResolvedTransport && provider.relayResolvedTransport !== 'llamacpp_native') {
    return provider.relayResolvedTransport;
  }
  const requestedTransport = provider.relayRequested?.transport;
  if (!requestedTransport || requestedTransport === 'auto' || requestedTransport === 'llamacpp_native') return undefined;
  return requestedTransport;
}

function resolveDefaultEnabledModel(
  provider: Provider,
  enabledModels: AIModel[],
): AIModel | null {
  if (enabledModels.length === 0) return null;

  const userDefault = enabledModels.find((model) => model.isDefault);
  if (userDefault) return userDefault;

  if (provider.kind !== 'relay') {
    const metadataDefaultId = getProviderDefaultModelId(provider.kind);
    const metadataDefault = findModelByIdentifier(enabledModels, metadataDefaultId);
    if (metadataDefault) return metadataDefault;
  }

  return enabledModels[0] ?? null;
}

function resolveHistoricalModel(
  provider: Provider,
  requestedModelId: string | null | undefined,
): AIModel | null {
  const trimmed = requestedModelId?.trim();
  if (!trimmed || provider.kind === 'relay') return null;

  const resolved = resolveCatalogModel(trimmed, provider.kind);
  if (!resolved) return null;

  return buildCatalogModel({
    providerKind: provider.kind,
    runtimeModelId: resolved.canonicalModelId,
    fallbackName: resolved.displayName ?? trimmed,
    fallbackContextLength: resolved.contextLength,
  });
}
