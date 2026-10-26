'use client';

import { useMemo, useSyncExternalStore } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  PRICE_TIER_NON_STANDARD_BILLING_LABEL,
  PRICE_TIER_UNKNOWN_LABEL,
  resolveModelPricePresentation,
} from '../../lib/core/providers/catalog-model';
import {
  getCachedMetadataVersion,
  getRelayRuntimeConfig,
  onVersionChange,
  resolveCatalogModel,
  type ResolvedModelMetadata,
} from '../../lib/core/metadata/metadata-client';
import {
  connectionRegionId,
  pricingCurrencyOf,
  selectRegionPricing,
} from '../../lib/core/cost/region-pricing';
import { resolveRelayOfficialMatch } from '../../lib/core/providers/relay-official-catalog-match';
import { resolveRelaySelectionTransport } from '../../lib/core/providers/provider-selection-snapshot';

/**
 * `priceTier` is persisted and synced across clients (`sync-mappings` stores it verbatim), so changing
 * the stored value would pollute synced data. The English sentinel strings therefore stay as they are
 * and are only translated into the current locale at render time. Non-sentinel values such as
 * "$1.5/$6" pass through unchanged.
 */
export function useModelPriceTierLabel(priceTier: string | undefined | null): string {
  const t = useTranslations('modelPricing');
  if (!priceTier) return '';
  switch (priceTier) {
    case PRICE_TIER_UNKNOWN_LABEL:
      return t('unknown');
    case PRICE_TIER_NON_STANDARD_BILLING_LABEL:
      return t('nonStandardBilling');
    case 'Free':
      return t('free');
    default:
      return priceTier;
  }
}

/** Unit prices of one model under one connection's selected region pricing (contract §5.7). */
export interface ConnectionModelPricing {
  /** Same sentinel vocabulary as the stored `priceTier`; priced values are already formatted in `currencyCode`. */
  priceTier: string;
  promptPrice: number | undefined;
  completionPrice: number | undefined;
  cacheReadInputPerMToken: number | undefined;
  cacheCreationInputPerMToken: number | undefined;
  cacheWrite5mPerMToken: number | undefined;
  cacheWrite1hPerMToken: number | undefined;
  currencyCode: string;
}

/**
 * Selects the price shown for a model under a connection through the same selection the cost path uses
 * (`connectionRegionId` + `selectRegionPricing`).
 *
 * Relay / custom endpoints never select a region; their label keeps the model-level price but is shown in
 * that price's own currency (a Relay model matched to an official CNY model shows ¥). When that currency
 * is USD the stored label already says the same thing, so null is returned and the stored price stays
 * (Relay falls back to the user's own price when the official one is missing).
 *
 * Without a connection no region is selected: the model-level catalog price of `providerKind` is shown in
 * its own currency (contract §5.7). Returns null on a catalog miss (or without a provider kind / for Relay
 * without a connection): the caller keeps the stored price string, e.g. a user-entered Relay price.
 */
export function connectionModelPricing(
  model: Pick<AIModel, 'id' | 'canonicalModelId' | 'relayTransport'>,
  provider: Provider | undefined,
  locale: string | undefined,
  providerKind?: string,
): ConnectionModelPricing | null {
  if (!provider) {
    if (!providerKind || !hasOfficialCatalog(providerKind)) return null;
    const modelLevel = resolveCatalogModel(model.id, providerKind);
    return modelLevel ? presentationOf(modelLevel, locale) : null;
  }
  const regionId = connectionRegionId(provider);
  if (regionId) {
    const catalog = resolveCatalogModel(model.id, provider.kind);
    return catalog ? presentationOf(selectRegionPricing(catalog, regionId), locale) : null;
  }
  const modelLevel = modelLevelCatalog(model, provider);
  if (!modelLevel || pricingCurrencyOf(modelLevel) === 'USD') return null;
  return presentationOf(modelLevel, locale);
}

function modelLevelCatalog(
  model: Pick<AIModel, 'id' | 'canonicalModelId' | 'relayTransport'>,
  provider: Provider,
): ResolvedModelMetadata | null {
  if (provider.kind === 'relay') {
    const runtimeConfig = getRelayRuntimeConfig();
    return resolveRelayOfficialMatch(model, resolveRelaySelectionTransport(provider, model), runtimeConfig)?.metadata
      ?? null;
  }
  if (!hasOfficialCatalog(provider.kind)) return null;
  return resolveCatalogModel(model.id, provider.kind);
}

function hasOfficialCatalog(providerKind: string): boolean {
  return providerKind !== 'relay';
}

function presentationOf(selected: ResolvedModelMetadata, locale: string | undefined): ConnectionModelPricing {
  const currencyCode = pricingCurrencyOf(selected);
  if (!currencyCode) {
    return {
      priceTier: PRICE_TIER_UNKNOWN_LABEL,
      promptPrice: undefined,
      completionPrice: undefined,
      cacheReadInputPerMToken: undefined,
      cacheCreationInputPerMToken: undefined,
      cacheWrite5mPerMToken: undefined,
      cacheWrite1hPerMToken: undefined,
      currencyCode: 'USD',
    };
  }
  const presentation = resolveModelPricePresentation(selected, { currencyCode, locale });
  const priced = presentation.promptPrice !== undefined || presentation.completionPrice !== undefined;
  return {
    ...presentation,
    cacheReadInputPerMToken: priced ? finiteOrUndefined(selected.pricing?.cacheReadInputPerMToken) : undefined,
    cacheCreationInputPerMToken: priced ? finiteOrUndefined(selected.pricing?.cacheCreationInputPerMToken) : undefined,
    cacheWrite5mPerMToken: priced ? finiteOrUndefined(selected.pricing?.cacheWrite5mPerMToken) : undefined,
    cacheWrite1hPerMToken: priced ? finiteOrUndefined(selected.pricing?.cacheWrite1hPerMToken) : undefined,
    currencyCode,
  };
}

/**
 * Render-time hook around {@link connectionModelPricing}. The metadata revision is part of the key so a
 * late cold-start load or a region price refresh recomputes even when the stored `priceTier` is unchanged.
 */
export function useConnectionModelPricing(
  model: Pick<AIModel, 'id' | 'canonicalModelId' | 'priceTier' | 'relayTransport'>,
  provider: Provider | undefined,
  providerKind?: string,
): ConnectionModelPricing | null {
  const locale = useLocale();
  const metadataRevision = useSyncExternalStore(onVersionChange, getCachedMetadataVersion, () => 0);
  const { id, priceTier, relayTransport } = model;
  return useMemo(
    () => connectionModelPricing({ id, relayTransport }, provider, locale, providerKind),
    // priceTier and metadataRevision only key the recompute after a metadata change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [id, priceTier, relayTransport, provider, providerKind, locale, metadataRevision],
  );
}

function finiteOrUndefined(value: number | null | undefined): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}
