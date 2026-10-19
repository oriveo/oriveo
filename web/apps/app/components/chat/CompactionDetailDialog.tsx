'use client';

import { useState } from 'react';
import { useLocale, useTranslations } from 'next-intl';
import { Button, CloseButton, Dialog } from '@oriveo/ui';
import type { ContextCheckpointRow } from '../../lib/infra/storage/context-checkpoint-store';
import { compactionDetailOf } from '../../lib/core/chat/context-compaction/context-compaction-presentation';
import {
  clearCompaction,
  recompact,
  type CompactionToast,
} from '../../lib/core/chat/context-compaction/context-compaction-actions';
import { showToast } from '../Toast';
import { MarkdownRenderer } from './MarkdownRenderer';
import styles from './CompactionDetailDialog.module.css';

interface CompactionDetailDialogProps {
  open: boolean;
  conversationId: string;
  row: ContextCheckpointRow;
  onClose: () => void;
  /** Wired by the new-chat-with-summary card; the dialog only forwards the row and closes. */
  onNewChatWithSummary?: (row: ContextCheckpointRow) => void;
}

const TOAST_KEY: Record<CompactionToast, 'toastFallback' | 'toastNoop'> = {
  fallback: 'toastFallback',
  noop: 'toastNoop',
};

export function CompactionDetailDialog({
  open,
  conversationId,
  row,
  onClose,
  onNewChatWithSummary,
}: CompactionDetailDialogProps) {
  const locale = useLocale();
  const t = useTranslations('pages.chat.contextCompaction');
  const tCommon = useTranslations('common');
  const [running, setRunning] = useState(false);
  const detail = compactionDetailOf(row);

  const costText =
    detail.cost.kind === 'noExtraCost'
      ? t('detailNoExtraCost')
      : detail.cost.kind === 'unavailable'
        ? t('detailCostUnavailable')
        : new Intl.NumberFormat(locale, {
            style: 'currency',
            currency: 'USD',
            maximumFractionDigits: 4,
          }).format(detail.cost.amount);
  // Same as iOS / Android: omit the year within the same year, keep it across years (same as formatLedgerDate).
  const createdAt = new Date(detail.createdAt);
  const timeText = new Intl.DateTimeFormat(locale, {
    year: createdAt.getFullYear() === new Date().getFullYear() ? undefined : 'numeric',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(createdAt);

  const handleRecompact = async () => {
    if (running) return;
    setRunning(true);
    try {
      const toast = await recompact(conversationId, row.checkpointId);
      if (toast) showToast(t(TOAST_KEY[toast]));
    } catch (error) {
      console.error('[ContextCompaction] recompact failed:', error);
      showToast(tCommon('error'), 3000, undefined, 'error');
    } finally {
      setRunning(false);
      onClose();
    }
  };

  const handleClear = async () => {
    if (running) return;
    setRunning(true);
    try {
      await clearCompaction(conversationId);
      showToast(t('toastCleared'));
    } catch (error) {
      console.error('[ContextCompaction] clearing compaction failed:', error);
      showToast(tCommon('error'), 3000, undefined, 'error');
    } finally {
      setRunning(false);
      onClose();
    }
  };

  const handleNewChat = () => {
    onNewChatWithSummary?.(row);
    onClose();
  };

  return (
    <Dialog
      open={open}
      onClose={onClose}
      size="md"
      padded={false}
      ariaLabelledBy="compaction-detail-title"
      lockBodyScroll
    >
      <section className={styles.panel}>
        <CloseButton className={styles.close} label={tCommon('close')} onClick={onClose} />
        <header className={styles.header}>
          <h2 id="compaction-detail-title" className={styles.title}>
            {t('detailTitle')}
          </h2>
        </header>
        {detail.summary ? (
          <div className={styles.summaryBlock}>
            <h3 className={styles.sectionLabel}>{t('detailSummary')}</h3>
            <div className={styles.summary}>
              <MarkdownRenderer content={detail.summary} enableCharFade={false} />
            </div>
          </div>
        ) : (
          <p className={styles.note}>{t('detailFallbackNote')}</p>
        )}
        <p className={styles.kept}>{t('detailKept', { count: detail.kept })}</p>
        <dl className={styles.meta}>
          <div className={styles.metaRow}>
            <dt>{t('detailModel')}</dt>
            <dd>{detail.model}</dd>
          </div>
          <div className={styles.metaRow}>
            <dt>{t('detailCost')}</dt>
            <dd>{costText}</dd>
          </div>
          <div className={styles.metaRow}>
            <dt>{t('detailTime')}</dt>
            <dd>{timeText}</dd>
          </div>
        </dl>
        <div className={styles.actions}>
          <Button tone="secondary" size="sm" disabled={running} onClick={() => void handleRecompact()}>
            {t('actionRecompact')}
          </Button>
          <Button tone="secondary" size="sm" disabled={running} onClick={() => void handleClear()}>
            {t('actionClear')}
          </Button>
          <Button tone="primary" size="sm" disabled={running} onClick={handleNewChat}>
            {t('actionNewChatWithSummary')}
          </Button>
        </div>
      </section>
    </Dialog>
  );
}
