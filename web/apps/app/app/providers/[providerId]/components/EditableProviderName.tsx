'use client';

import { useEffect, useState } from 'react';
import { Check, Pencil, X } from 'lucide-react';
import styles from '../ProviderDetail.module.css';

interface EditableProviderNameProps {
  name: string;
  onSave: (name: string) => void;
  editLabel: string;
  saveLabel: string;
  cancelLabel: string;
  disabled?: boolean;
}

export function EditableProviderName({
  name,
  onSave,
  editLabel,
  saveLabel,
  cancelLabel,
  disabled = false,
}: EditableProviderNameProps) {
  const [isEditing, setIsEditing] = useState(false);
  const [draft, setDraft] = useState(name);

  useEffect(() => {
    if (!isEditing) {
      setDraft(name);
    }
  }, [isEditing, name]);

  const commit = () => {
    const trimmed = draft.trim();
    if (!trimmed) return;
    onSave(trimmed);
    setIsEditing(false);
  };

  if (isEditing) {
    return (
      <div className={styles.providerNameEditor}>
        <input
          className={styles.providerNameInput}
          value={draft}
          aria-label={editLabel}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter') commit();
            if (event.key === 'Escape') setIsEditing(false);
          }}
          autoFocus
          disabled={disabled}
        />
        <button
          type="button"
          className={styles.providerNameIconButton}
          onClick={commit}
          disabled={disabled || !draft.trim()}
          aria-label={saveLabel}
        >
          <Check size={14} strokeWidth={2.4} />
        </button>
        <button
          type="button"
          className={styles.providerNameIconButton}
          onClick={() => setIsEditing(false)}
          aria-label={cancelLabel}
          disabled={disabled}
        >
          <X size={14} strokeWidth={2.4} />
        </button>
      </div>
    );
  }

  return (
    <span className={styles.providerNameEditable}>
      <span className={styles.statusTitle}>{name}</span>
      <button
        type="button"
        className={styles.providerNameEditButton}
        onClick={() => setIsEditing(true)}
        aria-label={editLabel}
        disabled={disabled}
      >
        <Pencil size={14} strokeWidth={2.2} />
      </button>
    </span>
  );
}
