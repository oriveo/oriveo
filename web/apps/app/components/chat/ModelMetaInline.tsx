'use client';

import type { AIModel, Provider } from '@oriveo/shared';
import { useLocale, useTranslations } from 'next-intl';
import { formatPerMillionPrice } from '../../lib/utils/format-utils';
import { formatContextLength } from './ModelSwitcher/model-switcher-data';
import { MODEL_ROW_MAX_CAPABILITY_BADGES, ModelCapabilityBadges } from './ModelCapabilityBadge';
import { useConnectionModelPricing, useModelPriceTierLabel } from './model-price-tier-label';
import {
  visibleModelCapabilityBadges,
  type ModelCapabilityPresentation,
} from '../../lib/core/chat/model-capability-presentation';
import { useCapabilityEvidenceExpiry } from '../../lib/core/chat/use-capability-evidence-expiry';

interface ModelMetaInlineProps {
  model: AIModel;
  provider?: Provider;
  /** Catalog provider kind used for the model-level price when there is no connection context. */
  providerKind?: string;
  containerClassName: string;
  priceClassName: string;
  size?: 'xs' | 'sm' | 'md';
  /** Parent collections already observing TTL set this false to avoid duplicate subscriptions. */
  observeEvidenceExpiry?: boolean;
  /** Parent collection's one-per-model projection for this render/TTL generation. */
  capabilityPresentation?: ModelCapabilityPresentation;
}

interface ModelCommercialMetaInlineProps {
  model: Pick<
    AIModel,
    | 'id'
    | 'priceTier'
    | 'relayTransport'
    | 'contextLength'
    | 'promptPrice'
    | 'completionPrice'
    | 'cacheReadInputPerMToken'
    | 'cacheCreationInputPerMToken'
    | 'cacheWrite5mPerMToken'
    | 'cacheWrite1hPerMToken'
  >;
  /** Connection context: unit prices follow its selected region pricing and currency. */
  provider?: Provider;
  /** Catalog provider kind used for the model-level price when there is no connection context. */
  providerKind?: string;
  containerClassName: string;
  itemClassName: string;
}

export function ModelCommercialMetaInline({
  model,
  provider,
  providerKind,
  containerClassName,
  itemClassName,
}: ModelCommercialMetaInlineProps) {
  const t = useTranslations('pages.providerDetail');
  const tm = useTranslations('pages.providerDetail.tokenPrices');
  const locale = useLocale();
  const connectionPricing = useConnectionModelPricing(model, provider, providerKind);
  const prices = connectionPricing ?? model;
  const currency = { code: connectionPricing?.currencyCode ?? 'USD', locale };
  const context = formatContextLength(model.contextLength);
  const cacheWrite = prices.cacheWrite5mPerMToken ?? prices.cacheCreationInputPerMToken;
  const items = [
    context ? `${t('contextLength')} ${context}` : null,
    formatPerTokenPrice(prices.promptPrice, currency, (value) => tm('input', { count: value })),
    formatPerTokenPrice(prices.completionPrice, currency, (value) => tm('output', { count: value })),
    formatPerMillionPriceLabel(prices.cacheReadInputPerMToken, currency, (value) => tm('cacheRead', { count: value })),
    formatPerMillionPriceLabel(cacheWrite, currency, (value) => tm('cacheWrite', { count: value })),
    formatPerMillionPriceLabel(
      prices.cacheWrite1hPerMToken,
      currency,
      (value) => `${tm('cacheWrite', { count: value })} 1h`,
    ),
  ].filter((item): item is string => Boolean(item));

  if (items.length === 0) return null;

  return (
    <span className={containerClassName}>
      {items.map((item) => (
        <span key={item} className={itemClassName}>{item}</span>
      ))}
    </span>
  );
}

interface PriceCurrency {
  code: string;
  locale: string;
}

function formatPerTokenPrice(
  value: number | undefined,
  currency: PriceCurrency,
  label: (formatted: string) => string,
): string | null {
  if (value == null || !Number.isFinite(value) || value <= 0) return null;
  return label(formatPerMillionPrice(value, currency.code, currency.locale));
}

function formatPerMillionPriceLabel(
  value: number | undefined,
  currency: PriceCurrency,
  label: (formatted: string) => string,
): string | null {
  if (value == null || !Number.isFinite(value) || value <= 0) return null;
  return label(formatPerMillionPrice(value / 1_000_000, currency.code, currency.locale));
}

export function ModelMetaInline({
  observeEvidenceExpiry = true,
  ...props
}: ModelMetaInlineProps) {
  return observeEvidenceExpiry
    ? <EvidenceAwareModelMetaInline {...props} />
    : <ModelMetaInlineContent {...props} />;
}

function EvidenceAwareModelMetaInline(props: Omit<ModelMetaInlineProps, 'observeEvidenceExpiry'>) {
  useCapabilityEvidenceExpiry(props.provider, props.model);
  return <ModelMetaInlineContent {...props} />;
}

function ModelMetaInlineContent({
  model,
  provider,
  providerKind,
  containerClassName,
  priceClassName,
  size = 'sm',
  capabilityPresentation,
}: Omit<ModelMetaInlineProps, 'observeEvidenceExpiry'>) {
  const connectionPricing = useConnectionModelPricing(model, provider, providerKind);
  const priceTierLabel = useModelPriceTierLabel(connectionPricing?.priceTier ?? model.priceTier);
  const hasPrice = Boolean(priceTierLabel);
  const capabilities = visibleModelCapabilityBadges(provider, model, capabilityPresentation);
  const hasCapabilities = capabilities.length > 0;

  if (!hasPrice && !hasCapabilities) return null;

  return (
    <span className={containerClassName}>
      {hasPrice ? (
        <span className={priceClassName}>{priceTierLabel}</span>
      ) : null}
      {hasCapabilities ? (
        <ModelCapabilityBadges
          capabilities={capabilities}
          size={size}
          badgeOrder={model.badgeOrder}
          maxVisible={MODEL_ROW_MAX_CAPABILITY_BADGES}
        />
      ) : null}
    </span>
  );
}
