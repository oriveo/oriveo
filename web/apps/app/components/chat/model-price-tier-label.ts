'use client';

import { useTranslations } from 'next-intl';
import {
  PRICE_TIER_NON_STANDARD_BILLING_LABEL,
  PRICE_TIER_UNKNOWN_LABEL,
} from '../../lib/core/providers/catalog-model';

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
