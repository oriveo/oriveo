'use client';

import { useLocale, useTranslations } from 'next-intl';
import {
  formatCompactCount,
  type CompactionSeparatorModel,
} from '../../lib/core/chat/context-compaction/context-compaction-presentation';
import styles from './CompactionSeparator.module.css';

interface CompactionSeparatorProps {
  model: CompactionSeparatorModel;
  onClick: () => void;
}

/** P3·U4 transcript separator: two centered lines between hairlines; the whole row opens the detail dialog. */
export function CompactionSeparator({ model, onClick }: CompactionSeparatorProps) {
  const t = useTranslations('pages.chat.contextCompaction');
  const locale = useLocale();
  const line1 =
    model.kind === 'summary'
      ? t('summaryLine1', {
          count: model.count,
          before: formatCompactCount(model.before ?? 0, locale),
          after: formatCompactCount(model.after ?? 0, locale),
        })
      : t('fallbackLine1', { count: model.count });
  const line2 = model.kind === 'summary' ? t('summaryLine2', { model: model.model }) : t('fallbackLine2', { count: model.kept });

  return (
    <button
      type="button"
      className={styles.separator}
      data-testid="compaction-separator"
      aria-label={`${line1} ${line2}`}
      onClick={onClick}
    >
      <span className={styles.rule} aria-hidden="true" />
      <span className={styles.text} aria-hidden="true">
        <span className={styles.line}>{line1}</span>
        <span className={styles.line}>
          {line2}
          <svg
            className={styles.chevron}
            width="12"
            height="12"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
          >
            <polyline points="9 6 15 12 9 18" />
          </svg>
        </span>
      </span>
      <span className={styles.rule} aria-hidden="true" />
    </button>
  );
}
