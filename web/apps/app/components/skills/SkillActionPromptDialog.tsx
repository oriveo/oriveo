'use client';

import { Button, Dialog } from '@oriveo/ui';
import styles from './SkillActionPromptDialog.module.css';

type SkillActionPromptKind = 'provider';

interface SkillActionPromptDialogProps {
  open: boolean;
  kind: SkillActionPromptKind;
  title: string;
  message: string;
  actionLabel: string;
  cancelLabel: string;
  onAction: () => void;
  onClose: () => void;
}

export function SkillActionPromptDialog({
  open,
  kind,
  title,
  message,
  actionLabel,
  cancelLabel,
  onAction,
  onClose,
}: SkillActionPromptDialogProps) {
  return (
    <Dialog open={open} onClose={onClose}>
      <div className={styles.container}>
        <div className={styles.header}>
          <div className={styles.iconWrap} aria-hidden="true">
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M12 2v20" />
              <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7H14a3.5 3.5 0 0 1 0 7H6" />
            </svg>
          </div>
          <div className={styles.copy}>
            <h2 className={styles.title}>{title}</h2>
            <p className={styles.message}>{message}</p>
          </div>
        </div>
        <div className={styles.actions}>
          <Button tone="secondary" onClick={onClose}>
            {cancelLabel}
          </Button>
          <Button onClick={onAction}>
            {actionLabel}
          </Button>
        </div>
      </div>
    </Dialog>
  );
}
