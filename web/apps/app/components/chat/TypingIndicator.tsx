'use client';

import { useTranslations } from 'next-intl';
import styles from './TypingIndicator.module.css';

export function TypingIndicator() {
  const t = useTranslations('pages.chat');

  return (
    <span className={styles.wrap} aria-label={t('generating')}>
      <span className={styles.dots} aria-hidden="true">
        <span className={styles.dot} />
        <span className={styles.dot} />
        <span className={styles.dot} />
      </span>
      <span className={styles.label}>{t('generating')}</span>
    </span>
  );
}
