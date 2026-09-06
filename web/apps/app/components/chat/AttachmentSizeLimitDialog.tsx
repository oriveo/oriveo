'use client';

import { useEffect, useRef, type KeyboardEvent } from 'react';
import { useTranslations } from 'next-intl';
import styles from './AttachmentSizeLimitDialog.module.css';

interface AttachmentSizeLimitDialogProps {
  open: boolean;
  onClose: () => void;
}

export function AttachmentSizeLimitDialog({
  open,
  onClose,
}: AttachmentSizeLimitDialogProps) {
  const t = useTranslations('pages.chat');
  const dialogRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return undefined;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    return () => {
      previous?.focus();
    };
  }, [open]);

  if (!open) {
    return null;
  }

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      onClose();
      return;
    }
    if (event.key !== 'Tab') return;

    const focusable = dialogRef.current?.querySelectorAll<HTMLElement>(
      'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])',
    );
    if (!focusable || focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  return (
    <div className={styles.backdrop}>
      <div
        ref={dialogRef}
        className={styles.dialog}
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="attachment-size-limit-title"
        aria-describedby="attachment-size-limit-message"
        onKeyDown={handleKeyDown}
      >
        <div className={styles.icon} aria-hidden="true">
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M12 9v4" />
            <path d="M12 17h.01" />
            <path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z" />
          </svg>
        </div>
        <h2 id="attachment-size-limit-title" className={styles.title}>
          {t('attachmentTooLargeTitle')}
        </h2>
        <p id="attachment-size-limit-message" className={styles.message}>
          {t('attachmentTooLargeMessage')}
        </p>
        <button type="button" className={styles.action} onClick={onClose} autoFocus>
          {t('attachmentTooLargeAction')}
        </button>
      </div>
    </div>
  );
}
