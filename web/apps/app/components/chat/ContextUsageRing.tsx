'use client';

import { useLocale, useTranslations } from 'next-intl';
import { formatCompactCount } from '../../lib/core/chat/context-compaction/context-compaction-presentation';
import { usageRingOf, type ContextUsageSummary } from '../../lib/core/chat/context-visibility/usage-summary';
import styles from './ContextUsageRing.module.css';

interface ContextUsageRingProps {
  summary: ContextUsageSummary | null;
  onOpen: () => void;
}

const SIZE = 34; // Same size as the send button (InputComposer .sendBtn is 34px).
const STROKE = 2.5;
const RADIUS = (SIZE - STROKE) / 2;
const CIRCUMFERENCE = 2 * Math.PI * RADIUS;

/**
 * composer context ring (contract item 2): fixed at the right end of the tools row, 28px.
 * Only the ring label is drawn inside (HTML overlay, not SVG text); hidden unless display is percent.
 */
export function ContextUsageRing({ summary, onOpen }: ContextUsageRingProps) {
  const t = useTranslations('pages.chat.contextUsage');
  const locale = useLocale();
  const ring = summary ? usageRingOf(summary) : null;
  if (!ring || summary?.percent == null) return null;

  const progress = Math.min(1, Math.max(0, summary.percent / 100));
  const label =
    ring.a11y.key === 'ringOverA11y'
      ? t('ringOverA11y')
      : t('ringA11y', { percent: ring.a11y.percent, limit: formatCompactCount(ring.a11y.limit, locale) });

  return (
    <button
      type="button"
      className={styles.ring}
      data-tone={ring.tone}
      aria-label={label}
      title={label}
      onClick={onOpen}
    >
      <svg className={styles.track} width="100%" height="100%" viewBox={`0 0 ${SIZE} ${SIZE}`} aria-hidden="true">
        <circle className={styles.trackBase} cx={SIZE / 2} cy={SIZE / 2} r={RADIUS} strokeWidth={STROKE} fill="none" />
        <circle
          className={styles.trackFill}
          cx={SIZE / 2}
          cy={SIZE / 2}
          r={RADIUS}
          strokeWidth={STROKE}
          fill="none"
          strokeLinecap="round"
          strokeDasharray={CIRCUMFERENCE}
          strokeDashoffset={CIRCUMFERENCE * (1 - progress)}
          transform={`rotate(-90 ${SIZE / 2} ${SIZE / 2})`}
        />
      </svg>
      <span className={styles.label} aria-hidden="true">
        {ring.label}
      </span>
    </button>
  );
}
