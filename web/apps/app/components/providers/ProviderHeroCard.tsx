'use client';

import { useMemo } from 'react';
import { useTranslations } from 'next-intl';
import type { Provider } from '@oriveo/shared';
import { isAggregatedProvider } from '@oriveo/shared';
import { ProviderIcon } from '../ProviderIcon';
import { PROVIDER_BRAND_COLORS } from '../../lib/constants/provider-brand-colors';
import { formatCost, COST_EPSILON } from '../../lib/utils/format-utils';
import { getProviderInstanceDisplayName } from '../../lib/core/providers/provider-display';
import { getEffectiveStatusKind } from '../../lib/core/providers/provider-status';
import { selectResolvedCatalog } from '../../lib/core/store/selectors';
import { modelFamilyIcon, shortenedModelName } from './model-family-icon';
import { resolveProviderWatermark } from './provider-brand-watermark';
import styles from './ProviderHeroCard.module.css';

interface ProviderHeroCardProps {
  provider: Provider;
  monthlyCost: number;
  /** Daily cost for the last 7 days, bucketed by UTC day, with the last entry being today.
   *  When empty the hero card derives a placeholder trend from the monthly cost. */
  dailyCostsLast7Days?: number[];
  onClick: () => void;
}

// Turns a vivid brand color into a muted one for the hero card's background gradient, so it does
// not read as advertising color. Mirrors Color.hsbAdjusted(saturation:brightness:) on iOS.
function hsbAdjusted(hex: string, sat: number, val: number): string {
  const cleaned = hex.replace('#', '');
  const r = parseInt(cleaned.substring(0, 2), 16) / 255;
  const g = parseInt(cleaned.substring(2, 4), 16) / 255;
  const b = parseInt(cleaned.substring(4, 6), 16) / 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  const s = max === 0 ? 0 : d / max;
  const v = max;
  const ns = Math.max(0, Math.min(1, s * sat));
  const nv = Math.max(0, Math.min(1, v * val));
  const c = nv * ns;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = nv - c;
  let nr = 0, ng = 0, nb = 0;
  if (h < 60) { nr = c; ng = x; nb = 0; }
  else if (h < 120) { nr = x; ng = c; nb = 0; }
  else if (h < 180) { nr = 0; ng = c; nb = x; }
  else if (h < 240) { nr = 0; ng = x; nb = c; }
  else if (h < 300) { nr = x; ng = 0; nb = c; }
  else { nr = c; ng = 0; nb = x; }
  const toHex = (n: number) => Math.round((n + m) * 255).toString(16).padStart(2, '0');
  return `#${toHex(nr)}${toHex(ng)}${toHex(nb)}`;
}

function formatRelativeTimeShort(iso: string, t: ReturnType<typeof useTranslations>): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const diff = Date.now() - d.getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return t('justNow');
  if (mins < 60) return t('minutesAgo', { count: mins });
  const hours = Math.floor(mins / 60);
  if (hours < 24) return t('hoursAgo', { count: hours });
  return d.toLocaleDateString();
}

export function ProviderHeroCard({
  provider,
  monthlyCost,
  dailyCostsLast7Days = [],
  onClick,
}: ProviderHeroCardProps) {
  const t = useTranslations('pages.providerList');
  const tc = useTranslations('common');
  const tDetail = useTranslations('pages.providerDetail');
  const displayName = getProviderInstanceDisplayName(provider);

  // Brand color: take the light end of PROVIDER_BRAND_COLORS, mute it with hsbAdjust (HSB 0.62 x
  // 0.88, matching the subdued brand color on iOS), then drive the CSS gradient with it.
  // Relay with no hint falls back to the primary purple, since PROVIDER_BRAND_COLORS.relay is grey
  // and the card should still have a color identity.
  const brandPair = PROVIDER_BRAND_COLORS[provider.kind] ?? PROVIDER_BRAND_COLORS.relay;
  const rawBrand = provider.kind === 'relay' ? '#8C5FF8' : brandPair.light;
  const subduedBrand = hsbAdjusted(rawBrand, 0.62, 0.88);

  const isZeroCost = monthlyCost <= COST_EPSILON;

  const effectiveKind = getEffectiveStatusKind(provider);
  // Visual channel: needsKey uses the yellow issue dot, while the label shows "Needs API Key" separately
  const statusKind = effectiveKind === 'needsKey' ? 'issue' : effectiveKind;
  const statusLabel =
    effectiveKind === 'connected' ? tc('connected')
    : effectiveKind === 'syncing' ? tc('syncing')
    : effectiveKind === 'needsKey' ? tDetail('needsApiKey')
    : tc('issue');

  // The resolved catalog reuses the ProviderListCard logic so the count matches the list row
  const resolvedCatalog = useMemo(() => selectResolvedCatalog(provider), [provider]);
  const availableCount = resolvedCatalog.availableModelCount;
  const enabledCount = resolvedCatalog.enabledModels.length;

  // Representative model: prefer default and available, then the first available, then simply the first
  const primaryModel = useMemo(() => {
    const candidate =
      provider.models.find((m) => m.isDefault && m.isAvailable) ??
      provider.models.find((m) => m.isAvailable) ??
      provider.models[0];
    if (!candidate) return null;
    const raw = (candidate.name?.trim() || candidate.id || '').trim();
    return raw ? shortenedModelName(raw) : null;
  }, [provider.models]);
  const ChipIcon = primaryModel ? modelFamilyIcon(primaryModel) : null;

  const modelsText =
    isAggregatedProvider(provider.kind) && enabledCount !== availableCount
      ? t('metricsAddedModels', { count: enabledCount })
      : t('metricsModels', { count: availableCount });

  // Sub line: "X models - Y min ago" once synced, or "X models" when never synced
  const subInfoText = provider.lastCheckedAt
    ? `${modelsText}  -  ${formatRelativeTimeShort(provider.lastCheckedAt, t)}`
    : modelsText;

  // Last 7 days bar chart: real data when available, otherwise a trend weighted from the monthly cost
  const resolvedWeekly = useMemo(() => {
    if (dailyCostsLast7Days.length > 0) {
      const tail = dailyCostsLast7Days.slice(-7);
      // Pad with zeros on the left when there are fewer than 7 entries
      while (tail.length < 7) tail.unshift(0);
      return tail;
    }
    if (monthlyCost <= COST_EPSILON) return [0, 0, 0, 0, 0, 0, 0];
    const weights = [0.45, 0.62, 0.38, 0.78, 0.5, 0.85, 1.0];
    const sum = weights.reduce((a, b) => a + b, 0);
    const dailyBudget = monthlyCost * 0.32;
    return weights.map((w) => (w / sum) * dailyBudget);
  }, [dailyCostsLast7Days, monthlyCost]);

  const hasWeeklySignal = resolvedWeekly.some((v) => v > COST_EPSILON);
  const todayCost = resolvedWeekly[resolvedWeekly.length - 1] ?? 0;
  const maxValue = Math.max(...resolvedWeekly, 0.0001);

  // logo mask; Relay uses a symbol mark
  const watermark = resolveProviderWatermark(provider.kind);

  return (
    <button
      type="button"
      className={styles.card}
      onClick={onClick}
      aria-label={`${displayName} - ${statusLabel}`}
      style={{ ['--brand-color' as never]: subduedBrand } as React.CSSProperties}
    >
      {/* logo → mask; Relay → symbol */}
      {watermark?.type === 'mask' && (
        <span
          className={styles.watermark}
          style={{
            maskImage: `url(${watermark.asset})`,
            WebkitMaskImage: `url(${watermark.asset})`,
          }}
          aria-hidden="true"
        />
      )}
      {watermark?.type === 'symbol' && (
        <span className={styles.watermarkSymbol} aria-hidden="true">
          <watermark.Icon size={124} />
        </span>
      )}

      <div className={styles.body}>
        {/* Left identity column: logo and name pinned to the top, so the logo lines up with the
            status on the right and the name with the $0; model and meta pinned to the bottom, so
            meta lines up with the daily cost regardless of font line-height differences. */}
        <div className={styles.identityColumn}>
          <div className={styles.identityTop}>
            <span className={styles.logoBadge} aria-hidden="true">
              <ProviderIcon
                kind={provider.kind}
                size={38}
                bare
                relayKind={provider.relayKind}
                providerName={displayName}
                baseURLText={provider.baseURLText}
                forceDark
              />
            </span>
            <span className={styles.name}>{displayName}</span>
          </div>
          <div className={styles.leftBottom}>
            {primaryModel && ChipIcon && (
              <span className={styles.modelRow}>
                <ChipIcon className={styles.modelRowIcon} size={13} strokeWidth={2.4} aria-hidden="true" />
                <span className={styles.modelRowName}>{primaryModel}</span>
              </span>
            )}
            {/* Bare text on the same left rail as the name and the model row icon, with no leading dot */}
            <span className={styles.subText} suppressHydrationWarning>{subInfoText}</span>
          </div>
        </div>

        {/* Right stats column: status at the top, cost at the bottom */}
        <div className={styles.statsColumn}>
          <span className={styles.statusCapsule} data-status={statusKind}>
            <span className={styles.statusDot} aria-hidden="true" />
            <span>{statusLabel}</span>
          </span>

          <div className={styles.right}>
            <div className={styles.costStack}>
              <span className={styles.costLabel}>{t('metricsThisMonth')}</span>
              <span className={styles.costValue} data-zero={isZeroCost ? 'true' : undefined} suppressHydrationWarning>
                {formatCost(monthlyCost) || '$0'}
              </span>
            </div>

            {hasWeeklySignal && (
              <div className={styles.weeklyChart} suppressHydrationWarning>
                <div className={styles.bars}>
                  {resolvedWeekly.map((v, i) => {
                    const ratio = v / maxValue;
                    const isLast = i === resolvedWeekly.length - 1;
                    return (
                      <span
                        key={i}
                        className={styles.bar}
                        data-last={isLast ? 'true' : undefined}
                        style={{ height: `${Math.max(3, 24 * ratio)}px` }}
                      />
                    );
                  })}
                </div>
                <div className={styles.todayRow}>
                  <span className={styles.todayLabel}>{t('today')}</span>
                  <span className={styles.todayValue}>{formatCost(todayCost) || '$0'}</span>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </button>
  );
}
