'use client';

import { useEffect, useMemo, useState } from 'react';
import { useTranslations } from 'next-intl';
import { Dialog } from '@oriveo/ui';
import { X } from 'lucide-react';
import { userMessageReadingChunks } from '../../lib/core/chat/user-message-fold';
import { copyToClipboard } from '../../lib/utils/clipboard';
import styles from './UserMessageFullTextDialog.module.css';

interface UserMessageFullTextDialogProps {
  open: boolean;
  text: string;
  onClose: () => void;
}

/**
 * Reading dialog opened by "Show full message" on a folded long user message (see
 * user-message-fold.ts).
 *
 * The text renders in chunks, each with `content-visibility: auto`, so the browser lays out only
 * the visible ones and opening 200,000 characters of Arabic does not lay out the whole text. The
 * chunks are siblings in one container, so a native selection can span them; copying the whole
 * message goes through the toolbar button.
 */
export function UserMessageFullTextDialog({ open, text, onClose }: UserMessageFullTextDialogProps) {
  const t = useTranslations('pages.chat');
  const tCommon = useTranslations('common');
  const [copied, setCopied] = useState(false);
  const chunks = useMemo(() => (open ? userMessageReadingChunks(text) : []), [open, text]);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1500);
    return () => clearTimeout(timer);
  }, [copied]);

  return (
    <Dialog open={open} onClose={onClose} size="lg" padded={false} lockBodyScroll>
      {/* React synthetic events bubble through the portal to the message row. Without stopping them,
          a right-click in the dialog would open the whole message's menu instead of the browser's
          native copy menu. */}
      <section
        className={styles.panel}
        data-testid="user-message-full-text-dialog"
        onContextMenu={(event) => event.stopPropagation()}
      >
        <header className={styles.toolbar}>
          <button
            type="button"
            className={styles.copy}
            onClick={async () => {
              if (await copyToClipboard(text, { failureToast: t('copyFailed') })) setCopied(true);
            }}
          >
            {copied ? t('copied') : t('copy')}
          </button>
          <button type="button" className={styles.close} onClick={onClose} aria-label={tCommon('close')}>
            <X size={18} aria-hidden />
          </button>
        </header>
        <div className={styles.body} dir="auto">
          {chunks.map((chunk, index) => (
            // Chunks are positional and never reorder, so the index is a stable key.
            <p key={index} className={styles.chunk} dir="auto">
              {chunk}
            </p>
          ))}
        </div>
      </section>
    </Dialog>
  );
}
