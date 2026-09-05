'use client';

import { useLocale, useTranslations } from 'next-intl';
import { Dialog } from '@oriveo/ui';
import { X } from 'lucide-react';
import styles from './MessageTokenUsageDialog.module.css';

export interface MessageTokenUsageSnapshot {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
}

interface MessageTokenUsageDialogProps {
  open: boolean;
  usage: MessageTokenUsageSnapshot;
  onClose: () => void;
}

export function messageTokenTotal(
  usage: MessageTokenUsageSnapshot,
): number | undefined {
  if (usage.inputTokens == null || usage.outputTokens == null) return undefined;
  return usage.inputTokens + usage.outputTokens;
}

export function MessageTokenUsageDialog({
  open,
  usage,
  onClose,
}: MessageTokenUsageDialogProps) {
  const locale = useLocale();
  const t = useTranslations('pages.chat.tokenUsage');
  const tCommon = useTranslations('common');
  const formatter = new Intl.NumberFormat(locale, { maximumFractionDigits: 0 });
  const format = (value: number | undefined) =>
    value == null ? t('unavailable') : formatter.format(value);
  const total = messageTokenTotal(usage);
  // Cache reads and writes are a subset of the input: inputTokens already includes them, and the
  // total is input plus output. Shown as equal-weight cards beside input, users add all four up
  // against the total, the numbers disagree and it looks like a miscalculation. So they are nested
  // inside the input card, where the physical nesting expresses the containment.
  // A missing field hides the whole row; a value of 0 still renders as 0, because "no cache hit this
  // time" is real information.
  const cacheRows = [
    ...(usage.cachedInputTokens == null
      ? []
      : ([['cacheRead', usage.cachedInputTokens]] as const)),
    ...(usage.cacheCreationInputTokens == null
      ? []
      : ([['cacheWrite', usage.cacheCreationInputTokens]] as const)),
  ];
  // With sub-rows the input card is much taller than the output card, so a side-by-side layout looks ragged; switch to a single column.
  const singleColumn = cacheRows.length > 0;

  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="md"
      padded={false}
      ariaLabelledBy="message-token-usage-title"
      lockBodyScroll
    >
      <section className={styles.panel}>
        <button
          type="button"
          className={styles.close}
          onClick={onClose}
          aria-label={tCommon('close')}
        >
          <X size={18} aria-hidden />
        </button>
        <header className={styles.header}>
          <h2 id="message-token-usage-title" className={styles.title}>
            {t('title')}
          </h2>
          <p className={styles.subtitle}>{t('subtitle')}</p>
        </header>
        <dl className={singleColumn ? styles.gridSingle : styles.grid}>
          <div className={styles.metric}>
            <dt>{t('input')}</dt>
            <dd>
              <span className={styles.metricValue}>{format(usage.inputTokens)}</span>
              {cacheRows.length > 0 && (
                <span className={styles.cacheBreakdown}>
                  {cacheRows.map(([key, value]) => (
                    <span className={styles.cacheRow} key={key}>
                      <span className={styles.cacheLabel}>{t(key)}</span>
                      <span className={styles.cacheValue}>{format(value)}</span>
                    </span>
                  ))}
                </span>
              )}
            </dd>
          </div>
          <div className={styles.metric}>
            <dt>{t('output')}</dt>
            <dd>
              <span className={styles.metricValue}>{format(usage.outputTokens)}</span>
            </dd>
          </div>
        </dl>
        <div className={styles.total}>
          <span>{t('total')}</span>
          <strong>{format(total)}</strong>
        </div>
      </section>
    </Dialog>
  );
}
