'use client';

import { Button, Dialog } from '@oriveo/ui';
import styles from './ConfirmDialog.module.css';

interface ConfirmDialogProps {
  open: boolean;
  title: string;
  /** Optional body text; omit it where only a title is needed, such as a bulk delete. */
  message?: string;
  confirmLabel: string;
  cancelLabel: string;
  /** When true the confirm button is red, for destructive actions such as delete. */
  destructive?: boolean;
  /** When true the buttons are disabled and the dialog cannot be closed, for an async operation in progress. */
  loading?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * Shared confirmation dialog built on the @oriveo/ui Dialog, which already provides a focus trap,
 * Esc to close and a portal overlay. For plain text confirmations such as deleting a conversation
 * or a folder; dialogs with an input or checkbox do not use this component.
 */
export function ConfirmDialog({
  open,
  title,
  message,
  confirmLabel,
  cancelLabel,
  destructive = false,
  loading = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  return (
    <Dialog open={open} onClose={loading ? undefined : onCancel} dismissible={!loading}>
      <h2 className={styles.title}>{title}</h2>
      {message ? <p className={styles.message}>{message}</p> : null}
      <div className={styles.actions}>
        <Button tone="secondary" onClick={onCancel} disabled={loading}>
          {cancelLabel}
        </Button>
        <Button
          tone={destructive ? 'danger' : 'primary'}
          onClick={onConfirm}
          disabled={loading}
          aria-busy={loading}
        >
          {confirmLabel}
        </Button>
      </div>
    </Dialog>
  );
}
