'use client';

import type { CSSProperties } from 'react';
import { useMemo } from 'react';
import { useTranslations } from 'next-intl';
import { CreditCard } from 'lucide-react';
import { formatCost } from '../../lib/utils/format-utils';
import type { MonthlyCostSummary } from '../../lib/core/cost/cost-summary';
import styles from './ProviderCostSummaryCard.module.css';

interface ProviderCostSummaryCardProps {
  summary: MonthlyCostSummary;
  onOpenDetails?: () => void;
}

/**
 * 12 well-spaced chart hues. The order keeps adjacent indices far apart on the wheel
 * (red -> teal -> purple -> gold -> blue and so on), so the top 3 providers are never all warm
 * or all cool. Low saturation and medium lightness in HSL.
 */
const CHART_PALETTE_HUES = [15, 160, 275, 55, 215, 330, 130, 245, 35, 190, 300, 355];

/**
 * Brand hue, matching --o-primary #8C5FF8 at roughly 257 degrees. The provider with the largest
 * share (index 0) is anchored to it, tying the card's visual weight to the brand color.
 */
const BRAND_HUE = 257;

function hueForIndex(index: number): number {
  if (index === 0) return BRAND_HUE;
  const bucket = (((index - 1) % CHART_PALETTE_HUES.length) + CHART_PALETTE_HUES.length) % CHART_PALETTE_HUES.length;
  return CHART_PALETTE_HUES[bucket];
}

function chartColorForIndex(index: number): string {
  // Light mode HSL.
  return `hsl(${hueForIndex(index)}deg 67% 64%)`;
}

function chartColorForIndexDark(index: number): string {
  // Dark mode HSL.
  return `hsl(${hueForIndex(index)}deg 53% 62%)`;
}

function formatShare(cost: number, totalCost: number): string {
  if (!Number.isFinite(cost) || cost <= 0 || !Number.isFinite(totalCost) || totalCost <= 0) {
    return '0%';
  }
  const sharePercent = (cost / totalCost) * 100;
  if (sharePercent >= 10) {
    return `${Math.max(Math.round(sharePercent), 1)}%`;
  }
  const roundedShare = Math.round(sharePercent * 10) / 10;
  return `${Math.max(roundedShare, 0.1).toFixed(1)}%`;
}

function splitCostText(value: string): { dollar: string | null; body: string } {
  if (value.startsWith('$')) {
    return { dollar: '$', body: value.slice(1) };
  }
  return { dollar: null, body: value };
}

function useMonthLabel(): string {
  return useMemo(() => {
    const formatter = new Intl.DateTimeFormat(undefined, { month: 'short', year: 'numeric' });
    return formatter.format(new Date()).toUpperCase();
  }, []);
}

export function ProviderCostSummaryCard({ summary, onOpenDetails }: ProviderCostSummaryCardProps) {
  const t = useTranslations('pages.chat.costSummary');
  const subtitle = t('localSubtitle');
  const monthLabel = useMonthLabel();
  const totalText = formatCost(summary.totalCost) || '$0';
  const { dollar, body: amountBody } = splitCostText(totalText);

  // With one provider and nothing hidden the bar is a single 100% segment, which is pure decoration, so hide it.
  const showSegmentedBar = summary.providers.length + summary.hiddenProviderCount >= 2 && summary.providers.length > 0;

  // Segment widths follow each provider's cost share; the remainder uses .segmentRest as a hint for hidden entries.
  let visibleShareTotal = 0;
  for (const p of summary.providers) {
    if (summary.totalCost > 0 && Number.isFinite(p.cost) && p.cost > 0) {
      visibleShareTotal += Math.min(Math.max(p.cost / summary.totalCost, 0), 1);
    }
  }
  const showRest = visibleShareTotal < 0.999;

  const content = (
    <>
      <div className={styles.accent} aria-hidden="true" />

      {/* Watermark: a credit card decoration overflowing the top right, half clipped by the 22px corner radius */}
      <span className={styles.watermark} aria-hidden="true">
        <CreditCard strokeWidth={1.6} />
      </span>

      <div className={styles.body}>
        <div className={styles.titleRow}>
          <div className={styles.titleLead}>
            <span className={styles.titleIconPlate} aria-hidden="true">
              <svg className={styles.titleIcon} width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M3 3v18h18" />
                <path d="M7 14l3-3 3 2 4-5" />
              </svg>
            </span>
            {/* The eyebrow reads "by provider" so it does not repeat the wording of the outer SectionHeader */}
            <p className={styles.eyebrow}>{t('byProvider')}</p>
          </div>

          {onOpenDetails ? (
            <span className={styles.chevronWrap} aria-hidden="true">
              <svg className={styles.chevron} width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="9 18 15 12 9 6" />
              </svg>
            </span>
          ) : null}
        </div>

        <div className={styles.hero}>
          <span className={styles.monthChip}>
            <span className={styles.monthDot} aria-hidden="true" />
            <span className={styles.monthLabel}>{monthLabel}</span>
          </span>

          <div className={styles.amountRow}>
            {dollar ? <span className={styles.dollar}>{dollar}</span> : null}
            <span className={styles.amount}>{amountBody}</span>
          </div>

          <span className={styles.baseline} aria-hidden="true" />

          <p className={styles.subtitle}>{subtitle}</p>
        </div>

        {showSegmentedBar ? (
          <div className={styles.segmentedBar} aria-hidden="true">
            {summary.providers.map((provider, index) => {
              const share = summary.totalCost > 0
                ? Math.min(Math.max(provider.cost / summary.totalCost, 0), 1)
                : 0;
              if (share <= 0) return null;
              const rowKey = `${provider.providerKind}|${provider.providerID || provider.displayName}`;
              const cssVars: CSSProperties = {
                '--seg-c': chartColorForIndex(index),
                '--seg-c-dark': chartColorForIndexDark(index),
                flexGrow: share,
                flexBasis: 0,
              } as CSSProperties;
              return (
                <span
                  key={rowKey}
                  className={styles.segment}
                  data-testid={`segment-${rowKey}`}
                  style={cssVars}
                />
              );
            })}
            {showRest ? (
              <span
                className={styles.segmentRest}
                data-testid="segment-rest"
                style={{ flexGrow: Math.max(1 - visibleShareTotal, 0.05), flexBasis: 0 } as CSSProperties}
              />
            ) : null}
          </div>
        ) : null}

        {summary.providers.length > 0 ? (
          <div className={styles.breakdown}>
            <div className={styles.legend}>
              {summary.providers.map((provider, index) => {
                // Each relay is billed separately, so the entry key is the (providerKind, providerID) pair.
                const rowKey = `${provider.providerKind}|${provider.providerID || provider.displayName}`;
                const chipVars: CSSProperties = {
                  '--chip-c': chartColorForIndex(index),
                  '--chip-c-dark': chartColorForIndexDark(index),
                } as CSSProperties;
                return (
                  <div
                    key={rowKey}
                    className={styles.legendItem}
                    data-kind={provider.providerKind}
                    data-provider-id={provider.providerID || undefined}
                    data-testid={`provider-breakdown-row-${rowKey}`}
                  >
                    <span className={styles.legendChip} style={chipVars} aria-hidden="true" />
                    <span className={styles.legendName}>{provider.displayName}</span>
                    <span className={styles.legendCost}>{formatCost(provider.cost)}</span>
                    <span className={styles.legendShare}>{formatShare(provider.cost, summary.totalCost)}</span>
                  </div>
                );
              })}

              {summary.hiddenProviderCount > 0 ? (
                <span className={styles.legendMore}>
                  <span className={styles.legendMoreChip} aria-hidden="true" />
                  <span>{t('moreProviders', { count: summary.hiddenProviderCount })}</span>
                </span>
              ) : null}
            </div>
          </div>
        ) : null}
      </div>
    </>
  );

  if (onOpenDetails) {
    return (
      <button type="button" className={`${styles.card} ${styles.clickable}`} onClick={onOpenDetails}>
        {content}
      </button>
    );
  }

  return <section className={styles.card}>{content}</section>;
}
