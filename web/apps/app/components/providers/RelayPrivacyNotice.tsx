'use client';

import { ShieldCheck } from 'lucide-react';
import { useTranslations } from 'next-intl';
import styles from './RelayPrivacyNotice.module.css';

interface RelayPrivacyNoticeProps {
  className?: string;
}

export function RelayPrivacyNotice({ className }: RelayPrivacyNoticeProps) {
  const t = useTranslations('pages.relayDetail');
  const resolvedClassName = [styles.notice, className].filter(Boolean).join(' ');

  return (
    <div className={resolvedClassName} role="note">
      <ShieldCheck size={16} strokeWidth={2.2} className={styles.icon} aria-hidden="true" />
      <div className={styles.body}>{t('privacyNote')}</div>
    </div>
  );
}
