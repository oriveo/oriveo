'use client';

import { useEffect, useId, useRef, useState } from 'react';
import { MessageSquareQuote, X } from 'lucide-react';
import { useTranslations } from 'next-intl';
import type { QuoteContext } from '@oriveo/shared';
import { quoteSummaryText } from '@oriveo/shared';
import styles from './QuoteContextChip.module.css';

interface QuoteContextChipProps {
  quoteContext: QuoteContext;
  presentation: 'composer' | 'sent';
  onRemove?: () => void;
}

export function QuoteContextChip({ quoteContext, presentation, onRemove }: QuoteContextChipProps) {
  const t = useTranslations('pages.chat');
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const previewId = useId();
  const summary = quoteSummaryText(quoteContext);

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setOpen(false);
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    };
  }, [open]);

  return (
    <div ref={rootRef} className={styles.root} data-presentation={presentation}>
      <button
        type="button"
        className={styles.main}
        aria-expanded={open}
        aria-controls={open ? previewId : undefined}
        aria-label={`${t('quoteSelectedContent')}: ${summary}`}
        onClick={() => setOpen((current) => !current)}
      >
        <MessageSquareQuote className={styles.icon} size={16} aria-hidden />
        <span className={styles.summary}>{summary}</span>
      </button>
      {onRemove ? (
        <button type="button" className={styles.remove} onClick={onRemove} aria-label={t('quoteRemove')}>
          <X size={12} aria-hidden />
        </button>
      ) : null}
      {open ? (
        <div id={previewId} className={styles.preview} role="dialog" aria-label={t('quoteFullContext')}>
          <div className={styles.previewTitle}>{t('quoteFullContext')}</div>
          <div className={styles.previewBody} tabIndex={0}>
            {quoteContext.leadingText}
            <mark className={styles.highlight}>{quoteContext.selectedText}</mark>
            {quoteContext.trailingText}
          </div>
        </div>
      ) : null}
    </div>
  );
}
