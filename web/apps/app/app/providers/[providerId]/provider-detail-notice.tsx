'use client';

import { useEffect, useState } from 'react';
import { useTranslations } from 'next-intl';
import { CheckCircle, WarningCircle } from '@phosphor-icons/react';
import styles from './ProviderDetail.module.css';

/**
 * One-time notice slot on the detail page (same semantics as iOS AppState `providerDetailNotice`): after saving from the providers entry on the add page
 * a notice is placed here (N models added / saved unverified); the detail page takes it and clears it, so it shows only once. Memory only: it does not reappear after a page refresh.
 */
export type ProviderDetailNotice =
  | { count: number }
  /** Manual setup "Save anyway (unverified)": the title says the connection is unverified, carrying the already-localized reason from the failure card. */
  | { unverifiedReason: string };

let pending: { providerID: string; notice: ProviderDetailNotice } | null = null;

export function setProviderDetailNotice(providerID: string, notice: ProviderDetailNotice): void {
  pending = { providerID, notice };
}

/** Taking clears it; one for a different connection is left alone. */
export function takeProviderDetailNotice(providerID: string): ProviderDetailNotice | null {
  if (!pending || pending.providerID !== providerID) return null;
  const { notice } = pending;
  pending = null;
  return notice;
}

/** On mount, take this connection's one-time notice (taking clears it); used by the detail page to decide whether the recovery card omits the reason line. */
export function useProviderDetailNotice(providerID: string): ProviderDetailNotice | null {
  const [notice, setNotice] = useState<ProviderDetailNotice | null>(null);
  useEffect(() => {
    const taken = takeProviderDetailNotice(providerID);
    if (taken) setNotice(taken);
  }, [providerID]);
  return notice;
}

/** Below the detail page topBar, before other status cards. */
export function ProviderDetailNoticeBanner({ providerID }: { providerID: string }) {
  const notice = useProviderDetailNotice(providerID);
  return <ProviderDetailNoticeView notice={notice} />;
}

export function ProviderDetailNoticeView({ notice }: { notice: ProviderDetailNotice | null }) {
  const t = useTranslations('pages.relaySetup');
  if (!notice) return null;
  if ('unverifiedReason' in notice) {
    return (
      <div className={styles.detailNotice} role="status" data-notice="unverified">
        <WarningCircle size={18} weight="duotone" aria-hidden="true" />
        <span className={styles.detailNoticeText}>
          <strong className={styles.detailNoticeTitle} data-notice-title>{t('connectionUnverified')}</strong>
          {notice.unverifiedReason ? (
            <span className={styles.detailNoticeReason} data-notice-reason>{notice.unverifiedReason}</span>
          ) : null}
        </span>
      </div>
    );
  }
  return (
    <div className={styles.detailNotice} role="status">
      <CheckCircle size={18} weight="duotone" aria-hidden="true" />
      <span>{t('twoStep.addedBanner', { count: notice.count })}</span>
    </div>
  );
}
