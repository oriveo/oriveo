'use client';

import { useLocale, useTranslations } from 'next-intl';
import { CloseButton, Dialog } from '@oriveo/ui';
import type { ChatMessage } from '@oriveo/shared';
import { formatCostParts, notAvailableCostParts } from '../../lib/core/cost/cost-currency';
import { COST_EPSILON } from '../../lib/utils/format-utils';
import styles from './MessageTokenUsageDialog.module.css';

export interface MessageTokenUsageSnapshot {
  inputTokens?: number;
  outputTokens?: number;
  cachedInputTokens?: number;
  cacheCreationInputTokens?: number;
  /** Persisted USD part of the message cost; the sheet never re-prices. */
  estimatedCost?: number;
  costSource?: ChatMessage['costSource'] | null;
  nonUsdCost?: ChatMessage['nonUsdCost'] | null;
  providerKind?: ChatMessage['providerKind'];
}

/**
 * Cost row of the token usage sheet.
 * amountText: formatted cost parts (may be empty); noDataParts: count of parts whose amount is unknown
 * (an unknown USD price on a non-hosted message, plus unknown non-USD parts), each rendered as the
 * sheet's own missing-state label after the amount.
 */
export interface MessageCostRow {
  estimated: boolean;
  amountText: string;
  noDataParts: number;
}

/**
 * Returns null when there is nothing displayable. A zero amount is never shown.
 */
export function messageCostRow(
  usage: MessageTokenUsageSnapshot,
  locale: string,
): MessageCostRow | null {
  const usd = usage.estimatedCost ?? 0;
  const nonUsd = usage.nonUsdCost ?? undefined;
  const showsUsd = Number.isFinite(usd) && usd > COST_EPSILON;
  const usdUnknown = !showsUsd && !nonUsd && usage.costSource === 'unknown';
  const showsNonUsd = !!nonUsd
    && (nonUsd.costSource === 'unknown' || (Number.isFinite(nonUsd.amount) && nonUsd.amount > COST_EPSILON));
  if (!showsUsd && !showsNonUsd && !usdUnknown) return null;
  return {
    estimated: usage.costSource !== 'upstream' && usage.costSource !== 'managed',
    amountText: formatCostParts(usd, nonUsd, locale),
    noDataParts: notAvailableCostParts(nonUsd).length + (usdUnknown ? 1 : 0),
  };
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
  const costRow = messageCostRow(usage, locale);
  const costText = costRow
    ? [costRow.amountText, ...Array.from({ length: costRow.noDataParts }, () => t('unavailable'))]
      .filter(Boolean)
      .join(' + ')
    : '';
  // Cache read / write is a **subset of input** (inputTokens already includes both, and total = input + output). Shown side by side with input as
  // equal-weight cards, users would add the four cards to check against the total; the numbers would not match and look like we miscalculated. So they are folded into the "input" card
  // and nested physically to express containment (contract §4.9.1).
  // The whole row is not rendered when the field is missing; when the value is 0 it still renders and shows 0, because that is real information: "no cache hit this time".
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
      initialFocusSelector="#message-token-usage-title"
      lockBodyScroll
    >
      <section className={styles.panel}>
        <CloseButton className={styles.close} label={tCommon('close')} onClick={onClose} />
        <header className={styles.header}>
          <h2 id="message-token-usage-title" className={styles.title} tabIndex={-1}>
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
        {costRow && (
          <div className={styles.cost}>
            <span className={styles.costLabel}>
              <span>{t('cost')}</span>
              {costRow.estimated && <span className={styles.estimatedTag}>{t('estimated')}</span>}
            </span>
            <span className={styles.costValue}>{costText}</span>
          </div>
        )}
      </section>
    </Dialog>
  );
}
