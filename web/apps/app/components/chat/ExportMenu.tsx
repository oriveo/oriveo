'use client';

import { useCallback, useEffect, useRef } from 'react';
import { useTranslations } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import {
  exportAsMarkdown,
  exportAsJSON,
  downloadAsFile,
  copyAllToClipboard,
  sanitizeFilename,
} from '../../lib/utils/export-utils';
import { showToast } from '../Toast';
import styles from './ExportMenu.module.css';

interface ExportMenuProps {
  conversation: Conversation;
  onClose: () => void;
}

export function ExportMenu({ conversation, onClose }: ExportMenuProps) {
  const t = useTranslations('export');
  const tCtx = useTranslations('contextMenu');
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        onClose();
      }
    };
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('keydown', handleEsc);
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('keydown', handleEsc);
    };
  }, [onClose]);

  const filename = sanitizeFilename(conversation.title || 'conversation');

  const handleMarkdown = useCallback(() => {
    const md = exportAsMarkdown(conversation);
    downloadAsFile(md, `${filename}.md`, 'text/markdown');
    onClose();
  }, [conversation, filename, onClose]);

  const handleJSON = useCallback(() => {
    const json = exportAsJSON(conversation);
    downloadAsFile(json, `${filename}.json`, 'application/json');
    onClose();
  }, [conversation, filename, onClose]);

  const handleClipboard = useCallback(async () => {
    const ok = await copyAllToClipboard(conversation);
    showToast(ok ? tCtx('copied') : tCtx('copyFailed'));
    onClose();
  }, [conversation, onClose, tCtx]);

  return (
    <div ref={menuRef} className={styles.menu}>
      <button type="button" className={styles.menuItem} onClick={handleMarkdown}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
          <polyline points="14 2 14 8 20 8" />
        </svg>
        {t('markdown')}
      </button>
      <button type="button" className={styles.menuItem} onClick={handleJSON}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <polyline points="16 18 22 12 16 6" />
          <polyline points="8 6 2 12 8 18" />
        </svg>
        {t('json')}
      </button>
      <button type="button" className={styles.menuItem} onClick={handleClipboard}>
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
          <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
        </svg>
        {t('clipboard')}
      </button>
    </div>
  );
}
