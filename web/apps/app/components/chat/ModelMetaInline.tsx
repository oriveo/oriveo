'use client';

import type { AIModel, Provider } from '@oriveo/shared';
import { useTranslations } from 'next-intl';
import { formatPerMillionPrice } from '../../lib/utils/format-utils';
import { formatContextLength } from './ModelSwitcher/model-switcher-data';
import { ModelCapabilityBadges } from './ModelCapabilityBadge';
import { useModelPriceTierLabel } from './model-price-tier-label';
import {
  visibleModelCapabilityBadges,
  type ModelCapabilityPresentation,
} from '../../lib/core/chat/model-capability-presentation';
import { useCapabilityEvidenceExpiry } from '../../lib/core/chat/use-capability-evidence-expiry';

interface ModelMetaInlineProps {
  model: AIModel;
  provider?: Provider;
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
    | 'contextLength'
    | 'promptPrice'
    | 'completionPrice'
    | 'cacheReadInputPerMToken'
    | 'cacheCreationInputPerMToken'
    | 'cacheWrite5mPerMToken'
    | 'cacheWrite1hPerMToken'
  >;
  containerClassName: string;
  itemClassName: string;
}

export function ModelCommercialMetaInline({
  model,
  containerClassName,
  itemClassName,
}: ModelCommercialMetaInlineProps) {
  const t = useTranslations('pages.providerDetail');
  const tm = useTranslations('pages.providerDetail.tokenPrices');
  const context = formatContextLength(model.contextLength);
  const cacheWrite = model.cacheWrite5mPerMToken ?? model.cacheCreationInputPerMToken;
  const items = [
    context ? `${t('contextLength')} ${context}` : null,
    formatPerTokenPrice(model.promptPrice, (value) => tm('input', { count: value })),
    formatPerTokenPrice(model.completionPrice, (value) => tm('output', { count: value })),
    formatPerMillionPriceLabel(model.cacheReadInputPerMToken, (value) => tm('cacheRead', { count: value })),
    formatPerMillionPriceLabel(cacheWrite, (value) => tm('cacheWrite', { count: value })),
    formatPerMillionPriceLabel(
      model.cacheWrite1hPerMToken,
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

function formatPerTokenPrice(
  value: number | undefined,
  label: (formatted: string) => string,
): string | null {
  if (value == null || !Number.isFinite(value) || value <= 0) return null;
  return label(formatPerMillionPrice(value));
}

function formatPerMillionPriceLabel(
  value: number | undefined,
  label: (formatted: string) => string,
): string | null {
  if (value == null || !Number.isFinite(value) || value <= 0) return null;
  return label(formatPerMillionPrice(value / 1_000_000));
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
  containerClassName,
  priceClassName,
  size = 'sm',
  capabilityPresentation,
}: Omit<ModelMetaInlineProps, 'observeEvidenceExpiry'>) {
  const priceTierLabel = useModelPriceTierLabel(model.priceTier);
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
        />
      ) : null}
    </span>
  );
}
