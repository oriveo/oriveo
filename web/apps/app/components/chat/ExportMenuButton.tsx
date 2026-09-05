import { useState, useCallback } from 'react';
import { useTranslations } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import { DownloadIcon } from '../icons';
import { LazyExportMenu } from './LazyChatOverlays';
import styles from './ChatView.module.css';

/**
 * TopBar export menu trigger button: it owns its open state and expands LazyExportMenu on click.
 * ChatView renders it only when a conversation exists and has messages.
 */
export function ExportMenuButton({ conversation }: { conversation: Conversation }) {
  const t = useTranslations('pages.chat');
  const [showExportMenu, setShowExportMenu] = useState(false);
  const handleToggle = useCallback(() => setShowExportMenu((v) => !v), []);
  const handleClose = useCallback(() => setShowExportMenu(false), []);

  return (
    <div style={{ position: 'relative' }}>
      <button
        type="button"
        className={styles.exportBtn}
        onClick={handleToggle}
        aria-label={t('export')}
        title={t('export')}
      >
        <DownloadIcon />
      </button>
      {showExportMenu && (
        <LazyExportMenu
          conversation={conversation}
          onClose={handleClose}
        />
      )}
    </div>
  );
}
