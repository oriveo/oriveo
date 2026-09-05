'use client';

import { useMemo } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import type { Provider } from '@oriveo/shared';
import { isAggregatedProvider } from '@oriveo/shared';
import { ProviderIcon } from '../ProviderIcon';
import { useIsDarkTheme } from '../../lib/hooks/useIsDarkTheme';
import { PROVIDER_BRAND_COLORS } from '../../lib/constants/provider-brand-colors';
import { formatCost } from '../../lib/utils/format-utils';
import {
  formatProviderBalanceAmount,
  isBalanceCapable,
  type ProviderBalance,
} from '../../lib/core/providers/balance';
import { selectResolvedCatalog } from '../../lib/core/store/selectors';
import { getProviderInstanceDisplayName } from '../../lib/core/providers/provider-display';
import { getEffectiveStatusKind } from '../../lib/core/providers/provider-status';
import styles from './ProviderListCard.module.css';

interface ProviderListCardProps {
  provider: Provider;
  monthlyCost: number;
  managedBalanceMicroUSD?: number | null;
  providerBalance?: ProviderBalance | null;
  onClick: () => void;
}

interface ProviderListTrailingAmount {
  label: 'balanceLabel' | 'usageLabel';
  text: string;
  isZero: boolean;
}

/**
 * Per-provider spend is computed from local message estimatedCost. The user paid the upstream
 * directly; this number is on-device accounting, not a hosted usage report.
 */
export function resolveProviderListTrailingAmount(
  providerKind: Provider['kind'],
  monthlyCost: number,
  managedBalanceMicroUSD: number | null | undefined,
  providerBalance: ProviderBalance | null | undefined,
  locale: string,
): ProviderListTrailingAmount | null {
  void managedBalanceMicroUSD;
  if (isBalanceCapable(providerKind)) {
    return {
      label: 'balanceLabel',
      text: providerBalance ? formatProviderBalanceAmount(providerBalance, locale) : '--',
      isZero: providerBalance?.total === 0,
    };
  }

  const text = formatCost(monthlyCost) || '$0';
  return { label: 'usageLabel', text, isZero: monthlyCost === 0 };
}

// useIsDark lives in lib/hooks/useIsDarkTheme.ts (one shared observer)
const useIsDark = useIsDarkTheme;

// Emits the time text only, with no "Checked" prefix
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

export function ProviderListCard({
  provider,
  monthlyCost,
  managedBalanceMicroUSD,
  providerBalance,
  onClick,
}: ProviderListCardProps) {
  const t = useTranslations('pages.providerList');
  const tc = useTranslations('common');
  const tDetail = useTranslations('pages.providerDetail');
  const locale = useLocale();
  const isDark = useIsDark();
  // Use the effective status: a missing local key shows as needsKey, matching the home hero and cluster counts
  const effectiveKind = getEffectiveStatusKind(provider);
  // Visual status for a list row: needsKey uses the issue channel (warning-colored dot plus text)
  const statusKind = effectiveKind === 'needsKey' ? 'issue' : effectiveKind;
  const brandColor = PROVIDER_BRAND_COLORS[provider.kind] ?? PROVIDER_BRAND_COLORS.relay;
  const tintColor = isDark ? brandColor.dark : brandColor.light;
  const displayName = getProviderInstanceDisplayName(provider);
  const trailingAmount = resolveProviderListTrailingAmount(
    provider.kind,
    monthlyCost,
    managedBalanceMicroUSD,
    providerBalance,
    locale,
  );
  const statusLabel = effectiveKind === 'connected' ? tc('connected')
    : effectiveKind === 'syncing' ? tc('syncing')
    : effectiveKind === 'needsKey' ? tDetail('needsApiKey')
    : tc('issue');
  const resolvedCatalog = useMemo(() => selectResolvedCatalog(provider), [provider]);
  const availableCount = resolvedCatalog.availableModelCount;
  const enabledCount = resolvedCatalog.enabledModels.length;
  const providerIconHints = useMemo(
    () => [...provider.models, ...provider.catalogModels]
      .flatMap((model) => [model.groupKey, model.groupName, model.id, model.name])
      .filter((value): value is string => Boolean(value)),
    [provider.models, provider.catalogModels],
  );

  // Aggregated providers with enabled != available show "X added models";
  // otherwise "X models".
  const modelsText = isAggregatedProvider(provider.kind) && enabledCount !== availableCount
    ? t('metricsAddedModels', { count: enabledCount })
    : t('metricsModels', { count: availableCount });

  // sub row format "X models - Y min ago", with no "Checked" prefix
  const syncCaption = provider.lastCheckedAt
    ? formatRelativeTimeShort(provider.lastCheckedAt, t)
    : t('neverSynced');

  const showStatusInline = statusKind !== 'connected';

  return (
    <button
      className={styles.card}
      data-status={statusKind}
      onClick={onClick}
      aria-label={`${displayName} - ${statusLabel}`}
      style={{
        '--brand-color': tintColor,
      } as React.CSSProperties}
    >
      <span className={styles.brandBar} aria-hidden="true" />

      <span className={styles.logo} aria-hidden="true">
        <ProviderIcon
          kind={provider.kind}
          size={38}
          bare
          relayKind={provider.relayKind}
          providerName={displayName}
          baseURLText={provider.baseURLText}
          modelHints={providerIconHints}
        />
      </span>

      <div className={styles.info}>
        <div className={styles.nameRow}>
          <span className={styles.name}>{displayName}</span>
          {showStatusInline && (
            <span className={styles.statusInline} data-status={statusKind}>
              <span className={styles.statusDot} aria-hidden="true" />
              <span>{statusLabel}</span>
            </span>
          )}
        </div>

        <div className={styles.subRow} suppressHydrationWarning>
          <span className={styles.subText}>{modelsText}</span>
          <span className={styles.subDot} aria-hidden="true" />
          <span className={styles.subText}>{syncCaption}</span>
        </div>
      </div>

      <div className={styles.trailing}>
        {trailingAmount && (
          <span className={styles.cost} data-zero={trailingAmount.isZero ? 'true' : undefined} suppressHydrationWarning>
            <span className={styles.amountLabel}>{t(trailingAmount.label)}</span>
            <span className={styles.amountValue}>{trailingAmount.text}</span>
          </span>
        )}
        <span className={styles.chevron} aria-hidden="true">
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="9 18 15 12 9 6" />
          </svg>
        </span>
      </div>
    </button>
  );
}

export function shouldShowProviderListErrorCopy(
  _provider: Pick<Provider, 'status' | 'lastError'>,
): boolean {
  return false;
}
