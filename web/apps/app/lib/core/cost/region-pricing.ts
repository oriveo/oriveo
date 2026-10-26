/**
 * Region price selection (contract "model catalog and capability truth" §5.7; fixture provider-pricing/region-pricing.v1.json)。
 *
 * Pure function: for the connection's effective region, pick the `regionPricing[]` entry with the same regionScope and
 * replace the model-level five keys as a group (currencyCode / pricingStatus / pricingUnit / pricing / pricingV2;
 * an entry without pricingV2 means there is none); with no match the model level is used as is. Estimates use the selected currency, no conversion.
 * Relay / custom-endpoint connections never select a region price.
 */
import type { Provider } from '@oriveo/shared';
import { isOfficialEndpointKind } from '@oriveo/core/providers/transport/endpoint-resolver';
import {
  getCachedMetadataVersion,
  hasPublicProviderConfigSource,
  listProviderModelIds,
  listPublicProviderConfigs,
  resolveCatalogModel,
  type PublicProviderConfig,
  type ResolvedModelMetadata,
} from '../metadata/metadata-client';
import { normalizeCostCurrency } from './cost-currency';
import { resolveRegionId } from '../provider-id-migration';
import {
  resolveProviderSetupCatalog,
  resolveRegionLookupCatalog,
  type ProviderSetupCatalog,
} from '../../../app/providers/new/provider-config-catalog';

/** Price selection only looks at these connection fields. */
export type RegionPricingConnection = Pick<Provider, 'kind' | 'baseURLText' | 'endpointSource'>;

/**
 * Effective region option id of a connection: use the stored `region:<id>` if it is among the options; otherwise look it up by baseURL; otherwise take the first option.
 * Returns null for non-official providers (Relay etc.) or user-defined endpoints; those connections never select a region price.
 */
export function effectiveRegionId(
  connection: RegionPricingConnection | undefined,
  catalog: ProviderSetupCatalog,
): string | null {
  if (!connection || !isOfficialEndpointKind(connection.kind)) return null;
  if (connection.endpointSource === 'custom') return null;
  return resolveRegionId(connection, catalog) || null;
}

/**
 * Region catalog used for region price selection: regions delivered by metadata first, then ids from the frozen identity region table that are not listed.
 * When metadata is not loaded only the frozen table exists, so a cn address still matches the cn region instead of being mis-billed at the model-level USD price;
 * regions delivered outside the frozen table (e.g. a new qwen region) can be selected once they arrive.
 */
export function pricingRegionCatalog(): ProviderSetupCatalog {
  // Called for every row label and every cost record: the frozen table and the merged catalog are each cached, and the merged catalog is invalidated by the metadata revision.
  // The revision restarts from 0 after the metadata client resets, so also check that the delivered entries are the same objects (reference comparison only).
  frozenRegionCatalog ??= resolveRegionLookupCatalog();
  const frozen = frozenRegionCatalog;
  if (!hasPublicProviderConfigSource()) return frozen;
  const revision = getCachedMetadataVersion();
  const configs = listPublicProviderConfigs();
  const held = mergedRegionCatalog;
  if (held && held.revision === revision && sameEntries(held.configs, configs)) return held.catalog;
  const catalog = mergeDeliveredRegions(frozen, configs);
  mergedRegionCatalog = { revision, configs, catalog };
  return catalog;
}

let frozenRegionCatalog: ProviderSetupCatalog | null = null;
let mergedRegionCatalog: {
  revision: number;
  configs: readonly PublicProviderConfig[];
  catalog: ProviderSetupCatalog;
} | null = null;

function sameEntries<T>(left: readonly T[], right: readonly T[]): boolean {
  return left.length === right.length && left.every((item, index) => item === right[index]);
}

function mergeDeliveredRegions(frozen: ProviderSetupCatalog, configs: PublicProviderConfig[]): ProviderSetupCatalog {
  const delivered = resolveProviderSetupCatalog(configs);
  const configsByKind = { ...frozen.configsByKind };
  for (const config of configs) {
    const kind = config.kind as keyof typeof configsByKind;
    const frozenConfig = configsByKind[kind];
    const deliveredOptions = delivered.configsByKind[kind]?.regionOptions;
    if (!frozenConfig || !deliveredOptions) continue;
    const listed = new Set(deliveredOptions.map((option) => option.id));
    configsByKind[kind] = {
      ...frozenConfig,
      regionOptions: [
        ...deliveredOptions,
        ...frozenConfig.regionOptions.filter((option) => !listed.has(option.id)),
      ],
    };
  }
  return { ...frozen, configsByKind, qwenRegions: configsByKind.qwen.regionOptions };
}

/** Effective region used for a connection's region price ({@link pricingRegionCatalog}); null for Relay / custom endpoints. */
export function connectionRegionId(connection: RegionPricingConnection | undefined): string | null {
  if (!connection || !isOfficialEndpointKind(connection.kind) || connection.endpointSource === 'custom') return null;
  return effectiveRegionId(connection, pricingRegionCatalog());
}

/** Currency of the selected price: pricingV2's currency first, otherwise the model level; defaults to USD, null when unrecognized (same rule as Android pricingCurrency). */
export function pricingCurrencyOf(pricing: ResolvedModelMetadata): string | null {
  return normalizeCostCurrency(pricing.pricingV2?.currencyCode ?? pricing.currencyCode);
}

/**
 * Whether every price of this provider in the catalog is USD (each model's model-level price and region prices). When the catalog misses a model,
 * this decides whether the selected currency can be determined to be USD; returns false when metadata is not loaded or the provider has no catalog models.
 */
export function providerPricedAllInUsd(providerKind: string): boolean {
  const ids = listProviderModelIds(providerKind);
  if (ids.length === 0) return false;
  return ids.every((id) => {
    const model = resolveCatalogModel(id, providerKind);
    if (!model || pricingCurrencyOf(model) !== 'USD') return false;
    return (model.regionPricing ?? []).every((entry) =>
      normalizeCostCurrency(entry.pricingV2?.currencyCode ?? entry.currencyCode) === 'USD');
  });
}

/**
 * Replace the model-level five keys by effective region; returns the input as is on no match (including a null regionId).
 * Does not mutate the input: the result of resolveCatalogModel is a shared projection.
 */
export function selectRegionPricing(
  resolved: ResolvedModelMetadata,
  regionId: string | null,
): ResolvedModelMetadata {
  if (!regionId) return resolved;
  const entry = resolved.regionPricing?.find((item) => item.regionScope === regionId);
  if (!entry) return resolved;
  const { pricingV2: _modelLevelV2, ...rest } = resolved;
  return {
    ...rest,
    currencyCode: entry.currencyCode,
    pricingStatus: entry.pricingStatus,
    pricingUnit: entry.pricingUnit,
    pricing: entry.pricing,
    ...(entry.pricingV2 ? { pricingV2: entry.pricingV2 } : {}),
  };
}
