'use client';

import { useEffect, useId, useRef, useState, type FormEvent } from 'react';
import { useTranslations } from 'next-intl';
import { Button } from '@oriveo/ui';
import { useFocusTrap } from '../../../../lib/hooks/useFocusTrap';
import styles from '../ProviderDetail.module.css';

interface RenameProviderDialogProps {
  /** Current name, used as the placeholder and the initial input value */
  currentName: string;
  onSave: (newName: string) => void;
  onCancel: () => void;
}

export function RenameProviderDialog({ currentName, onSave, onCancel }: RenameProviderDialogProps) {
  const t = useTranslations('pages.providerDetail');
  const tc = useTranslations('common');

  const [name, setName] = useState(currentName);
  const trimmed = name.trim();
  const canSave = trimmed.length > 0 && trimmed !== currentName.trim();

  const dialogRef = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useFocusTrap(dialogRef, true);

  // Esc closes the dialog, which keyboard users need
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault();
        onCancel();
      }
    };
    document.addEventListener('keydown', handler);
    return () => document.removeEventListener('keydown', handler);
  }, [onCancel]);

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!canSave) return;
    onSave(trimmed);
  };

  return (
    <div className={styles.confirmOverlay} onClick={onCancel}>
      <div
        ref={dialogRef}
        className={styles.confirmDialog}
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <div id={titleId} className={styles.confirmTitle}>{t('renameProviderTitle')}</div>
        <form onSubmit={handleSubmit}>
          <input
            type="text"
            className={styles.providerNameInput}
            value={name}
            placeholder={currentName}
            onChange={(e) => setName(e.target.value)}
            autoFocus
            aria-label={t('renameProviderTitle')}
            style={{ width: '100%' }}
          />
        </form>
        <div className={styles.confirmActions}>
          <Button tone="secondary" size="sm" onClick={onCancel}>
            {tc('cancel')}
          </Button>
          <Button
            tone="primary"
            size="sm"
            onClick={() => canSave && onSave(trimmed)}
            disabled={!canSave}
          >
            {tc('save')}
          </Button>
        </div>
      </div>
    </div>
  );
}
