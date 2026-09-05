'use client';

import { useState, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import { FilePlus2 } from 'lucide-react';
import type { ChatRole } from '@oriveo/shared';
import { copyToClipboard } from '../../lib/utils/clipboard';
import styles from './MessageActions.module.css';

interface MessageActionsProps {
  role: ChatRole;
  text: string;
  onEdit?: () => void;
  onSaveNote?: () => void;
}

export function MessageActions({ role, text, onEdit, onSaveNote }: MessageActionsProps) {
  const t = useTranslations('pages.chat');
  const tCtx = useTranslations('contextMenu');
  const [copied, setCopied] = useState(false);

  const handleCopy = useCallback(async () => {
    const ok = await copyToClipboard(text, { failureToast: tCtx('copyFailed') });
    if (ok) {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    }
  }, [text, tCtx]);

  return (
    <div className={styles.actions} data-role={role}>
      {/* Copy */}
      <button
        type="button"
        className={styles.btn}
        onClick={handleCopy}
        aria-label={copied ? t('copied') : t('copy')}
        title={copied ? t('copied') : t('copy')}
      >
        {copied ? (
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="20 6 9 17 4 12" />
          </svg>
        ) : (
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
            <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
          </svg>
        )}
      </button>

      {/* Edit (user only) */}
      {role === 'user' && onEdit && (
        <button
          type="button"
          className={styles.btn}
          onClick={onEdit}
          aria-label={t('edit')}
          title={t('edit')}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
            <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
          </svg>
        </button>
      )}
      {onSaveNote && (
        <button
          type="button"
          className={styles.btn}
          onClick={onSaveNote}
          aria-label={t('saveAsNote')}
          title={t('saveAsNote')}
        >
          <FilePlus2 size={14} aria-hidden />
        </button>
      )}
    </div>
  );
}
