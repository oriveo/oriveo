import type { AIModel, LastUsedModelRef, Provider } from '@oriveo/shared';
import { sameNormalizedID } from '../../utils/id-utils';
import { getProviderDefaultModelId, getRelayRuntimeConfig, resolveCatalogModel } from '../metadata/metadata-client';
import { buildCatalogModel } from './catalog-model';
import { findModelByIdentifier } from './model-display-lookup';
import { resolveRelayStoredModel } from './relay-model-identity';
import { enrichRelayCatalog } from './relay-official-catalog-match';
import type { RelayRuntimeConfig, RelayTransportKey } from '../metadata/metadata-client';
import { effectiveTransport } from '@oriveo/core/providers/relay-effective';

export interface ProviderSelectionSnapshot {
  provider: Provider;
  enabledModels: AIModel[];
  currentModel: AIModel | null;
  defaultModel: AIModel | null;
}

interface SelectionOptions {
  requestedModelId?: string | null;
  /** A relay's fallback model looks at the last-used model; official providers do not read it. */
  lastUsedModelRef?: LastUsedModelRef | null;
}

export function createProviderSelectionSnapshot(
  provider: Provider | undefined,
  options: SelectionOptions = {},
): ProviderSelectionSnapshot | null {
  if (!provider) return null;

  const enabledModels = provider.kind === 'relay'
    ? enrichRelayModelsByTransport(provider, provider.models, getRelayRuntimeConfig())
    : provider.models;
  const defaultModel = resolveDefaultEnabledModel(provider, enabledModels, options.lastUsedModelRef);
  // A relay resolves the stored value with read compatibility: a literal hit, otherwise a unique canonical hit; no date-stripping fold.
  const requestedModel = provider.kind === 'relay'
    ? resolveRelayStoredModel(enabledModels, options.requestedModelId)
    : findModelByIdentifier(enabledModels, options.requestedModelId);
  const currentModel = requestedModel
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
 * Resolve the transport a Relay model uses for enrichment (through the Relay 2.0 `effectiveTransport`; no model = the connection default).
 * Exported so write-time enrichment (`provider-model-ops.ts:patchProviderModels`) and bootstrap
 * re-enrichment can share it instead of repeating the resolution at several call sites.
 * The llama.cpp native channel has no envelope and returns undefined.
 */
export function resolveRelaySelectionTransport(
  provider: Provider,
  model?: Pick<AIModel, 'relayTransport'> | null,
): RelayTransportKey | undefined {
  const transport = effectiveTransport(provider, model);
  return transport === 'llamacpp_native' ? undefined : transport;
}

/** Enrich each model with its own protocol (Relay 2.0: the protocol is a property of the model, so the envelope intersection is per model too). */
export function enrichRelayModelsByTransport(
  provider: Provider,
  models: AIModel[],
  runtimeConfig: RelayRuntimeConfig,
): AIModel[] {
  return models.flatMap((model) => enrichRelayCatalog([model], resolveRelaySelectionTransport(provider, model), runtimeConfig));
}

/**
 * Fallback model of a relay (including the local engine): if the last-used model points at this connection and is still
 * enabled, use it; otherwise the first enabled model. A relay has no default model, so a legacy `isDefault` is never read.
 */
export function resolveRelayFallbackModel<T extends Pick<AIModel, 'id' | 'canonicalModelId'>>(
  providerID: string,
  enabledModels: readonly T[],
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): T | null {
  if (lastUsedModelRef && sameNormalizedID(lastUsedModelRef.providerID, providerID)) {
    const lastUsed = resolveRelayStoredModel(enabledModels, lastUsedModelRef.modelID);
    if (lastUsed) return lastUsed;
  }
  return enabledModels[0] ?? null;
}

/**
 * Relay verification sample: fallback model -> first catalog model -> null.
 * On null the caller sends no request and takes the existing "missing model" error.
 */
export function resolveRelayVerificationSampleModelID(
  provider: Pick<Provider, 'id' | 'models' | 'catalogModels'>,
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): string | null {
  return resolveRelayFallbackModel(provider.id, provider.models, lastUsedModelRef)?.id
    ?? provider.catalogModels[0]?.id
    ?? null;
}

function resolveDefaultEnabledModel(
  provider: Provider,
  enabledModels: AIModel[],
  lastUsedModelRef: LastUsedModelRef | null | undefined,
): AIModel | null {
  if (enabledModels.length === 0) return null;
  if (provider.kind === 'relay') return resolveRelayFallbackModel(provider.id, enabledModels, lastUsedModelRef);

  const userDefault = enabledModels.find((model) => model.isDefault);
  if (userDefault) return userDefault;

  const metadataDefaultId = getProviderDefaultModelId(provider.kind);
  const metadataDefault = findModelByIdentifier(enabledModels, metadataDefaultId);
  if (metadataDefault) return metadataDefault;

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
