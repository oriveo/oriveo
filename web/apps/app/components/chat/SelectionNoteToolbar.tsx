'use client';

import { Copy, FilePenLine, FilePlus2, MessageSquareQuote } from 'lucide-react';
import { useTranslations } from 'next-intl';
import type { TextSelectionAnchor } from '../../lib/hooks/useTextSelectionAnchor';
import styles from './MessageList.module.css';

interface SelectionNoteToolbarProps {
  anchor: TextSelectionAnchor;
  onCopy: () => void;
  onAsk?: () => void;
  onSave: () => void;
  onReplace?: () => void;
}

export function SelectionNoteToolbar({ anchor, onCopy, onAsk, onSave, onReplace }: SelectionNoteToolbarProps) {
  const t = useTranslations('pages.chat');
  return (
    <div className={styles.selectionNoteToolbar} style={{ left: anchor.x, top: anchor.y }}>
      {onAsk ? (
        <button type="button" onPointerDown={(event) => event.preventDefault()} onClick={onAsk}>
          <MessageSquareQuote size={14} aria-hidden />
          {t('selectionAsk')}
        </button>
      ) : null}
      <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={onCopy}>
        <Copy size={14} aria-hidden />
        {t('copy')}
      </button>
      <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={onSave}>
        <FilePlus2 size={14} aria-hidden />
        {t('saveAsNote')}
      </button>
      {onReplace ? (
        <button type="button" onMouseDown={(event) => event.preventDefault()} onClick={onReplace}>
          <FilePenLine size={14} aria-hidden />
          {t('replaceCurrentNote')}
        </button>
      ) : null}
    </div>
  );
}
