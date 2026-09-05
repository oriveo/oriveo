'use client';

import { Fragment, useMemo } from 'react';
import { useTranslations } from 'next-intl';
import type { Provider } from '@oriveo/shared';
import { getEffectiveStatusKind } from '../../lib/core/providers/provider-status';
import styles from './ProvidersClusterHeader.module.css';

interface ProvidersClusterHeaderProps {
  providers: Provider[];
  totalAvailableModels: number;
}

const ConnectedIcon = (
  <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <polyline points="20 6 9 17 4 12" />
  </svg>
);

const AvailableIcon = (
  <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
    {/* Main sparkle: a 4-pointed AI star */}
    <path d="M10 2L11.5 8.5L18 10L11.5 11.5L10 18L8.5 11.5L2 10L8.5 8.5L10 2Z" />
    {/* Secondary sparkle: one size down, top right */}
    <path d="M18.5 13L19.3 16.2L22.5 17L19.3 17.8L18.5 21L17.7 17.8L14.5 17L17.7 16.2L18.5 13Z" opacity="0.65" />
  </svg>
);

const ProviderIcon = (
  <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M12 2L2 7l10 5 10-5-10-5z" />
    <path d="M2 17l10 5 10-5" />
    <path d="M2 12l10 5 10-5" />
  </svg>
);

export function ProvidersClusterHeader({ providers, totalAvailableModels }: ProvidersClusterHeaderProps) {
  const t = useTranslations('pages.providerList');
  const total = providers.length;

  const stats = useMemo(() => {
    let connected = 0;
    let syncing = 0;
    let issue = 0;
    for (const p of providers) {
      // needsKey counts as an issue: without a key on this client the provider cannot be used, so it belongs in the warning count
      const kind = getEffectiveStatusKind(p);
      if (kind === 'connected') connected++;
      else if (kind === 'syncing') syncing++;
      else issue++;
    }
    return { connected, syncing, issue };
  }, [providers]);

  const allConnected = stats.issue === 0 && stats.syncing === 0;
  const primaryLabel = allConnected
    ? t('clusterConnected', { count: stats.connected })
    : t('clusterProviders', { count: total });

  let statusBadge: { tone: string; label: string; icon: 'warning' | 'sync' | 'check' | 'dot' } | null = null;
  if (stats.issue > 0) {
    statusBadge = { tone: 'warning', label: t('clusterIssue', { count: stats.issue }), icon: 'warning' };
  } else if (stats.syncing > 0) {
    statusBadge = { tone: 'primary', label: t('clusterSyncing', { count: stats.syncing }), icon: 'sync' };
  } else if (stats.connected < total && stats.connected > 0) {
    statusBadge = { tone: 'success', label: t('clusterPartialConnected', { connected: stats.connected, total }), icon: 'check' };
  }

  // Primary icon: a check (success) when everything is connected, the provider stack (neutral) for a mixed state
  const primaryIcon = allConnected ? ConnectedIcon : ProviderIcon;
  const primaryTone = allConnected ? 'success' : 'neutral';

  return (
    <div className={styles.header}>
      <div className={styles.metaLine}>
        <span className={styles.metaItem} data-tone={primaryTone}>
          <span className={styles.metaIcon} data-tone={primaryTone} aria-hidden="true">{primaryIcon}</span>
          <span className={styles.metaText}>{primaryLabel}</span>
        </span>
        <span className={styles.dotSep} aria-hidden="true" />
        <span className={styles.metaItem} data-tone="primary">
          <span className={styles.metaIcon} data-tone="primary" aria-hidden="true">{AvailableIcon}</span>
          <span className={styles.metaText}>{t('clusterAvailable', { count: totalAvailableModels })}</span>
        </span>
      </div>

      {statusBadge && (
        <span className={styles.statusBadge} data-tone={statusBadge.tone}>
          {statusBadge.icon === 'warning' && (
            <span className={styles.statusBadgeDot} aria-hidden="true" />
          )}
          {statusBadge.icon === 'sync' && (
            <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" className={styles.spinIcon} aria-hidden="true">
              <path d="M21 12a9 9 0 11-6.219-8.56" />
            </svg>
          )}
          {statusBadge.icon === 'check' && (
            <span className={styles.statusBadgeDot} aria-hidden="true" />
          )}
          <span className={styles.statusBadgeText}>{statusBadge.label}</span>
        </span>
      )}
    </div>
  );
}
