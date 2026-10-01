'use client';

import { useTranslations } from 'next-intl';
import type { StreamActivity } from '@oriveo/core/providers/types';
import styles from './StreamActivityLine.module.css';

/**
 * Activity to label. The typing indicator uses the same mapping when it swaps its label. The keys
 * are written as literals so that the unused-message check can see them.
 */
export function useStreamActivityLabel(label: StreamActivity | 'neutral'): string {
  const t = useTranslations('pages.chat');
  return label === 'web_search' ? t('activityWebSearch') : t('generating');
}

/**
 * The waiting line under the message body. `resolveStreamActivityPresentation` decides when it
 * shows; this component only decides how it looks.
 */
export function StreamActivityLine({ label }: { label: StreamActivity | 'neutral' }) {
  const text = useStreamActivityLabel(label);
  return (
    <div className={styles.line} role="status">
      <span className={styles.shimmer}>{text}</span>
    </div>
  );
}
