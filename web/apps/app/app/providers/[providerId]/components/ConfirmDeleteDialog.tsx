'use client';

import { useTranslations } from 'next-intl';
import { Button } from '@oriveo/ui';
import styles from '../ProviderDetail.module.css';

interface ConfirmDeleteDialogProps {
  title: string;
  description: string;
  onConfirm: () => void | Promise<void>;
  onCancel: () => void;
}

export function ConfirmDeleteDialog({ title, description, onConfirm, onCancel }: ConfirmDeleteDialogProps) {
  const tc = useTranslations('common');

  return (
    <div className={styles.confirmOverlay} onClick={onCancel}>
      <div className={styles.confirmDialog} onClick={(e) => e.stopPropagation()}>
        <div className={styles.confirmTitle}>{title}</div>
        <div className={styles.confirmDesc}>{description}</div>
        <div className={styles.confirmActions}>
          <Button tone="secondary" size="sm" onClick={onCancel}>
            {tc('cancel')}
          </Button>
          <Button tone="danger" size="sm" onClick={onConfirm}>
            {tc('delete')}
          </Button>
        </div>
      </div>
    </div>
  );
}
