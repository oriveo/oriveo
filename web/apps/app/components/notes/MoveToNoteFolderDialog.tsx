'use client';

import type { NoteFolder } from '@oriveo/shared';
import { getFolderColorPair } from '@oriveo/shared';
import { Button, Dialog } from '@oriveo/ui';
import { useTranslations } from 'next-intl';
import styles from './Notes.module.css';

interface MoveToNoteFolderDialogProps {
  open: boolean;
  folders: NoteFolder[];
  currentFolderId?: string;
  onSelect: (folderId: string | null) => void;
  onClose: () => void;
}

export function MoveToNoteFolderDialog({
  open,
  folders,
  currentFolderId,
  onSelect,
  onClose,
}: MoveToNoteFolderDialogProps) {
  const t = useTranslations('notes');

  return (
    <Dialog open={open} onClose={onClose}>
      <h2 className={styles.dialogTitle}>{t('folders.moveTo')}</h2>
      <div className={styles.folderChoices}>
        <button
          type="button"
          className={styles.folderChoice}
          data-active={!currentFolderId ? 'true' : undefined}
          disabled={!currentFolderId}
          onClick={() => onSelect(null)}
        >
          <span className={styles.folderDot} style={{ background: 'var(--o-text-tertiary)' }} aria-hidden />
          {t('folders.uncategorized')}
        </button>
        {folders.map((folder) => {
          const [main, dark] = getFolderColorPair(folder.colorTag ?? 'blue');
          return (
            <button
              key={folder.id}
              type="button"
              className={styles.folderChoice}
              data-active={currentFolderId === folder.id ? 'true' : undefined}
              disabled={currentFolderId === folder.id}
              onClick={() => onSelect(folder.id)}
            >
              <span
                className={styles.folderDot}
                style={{ background: `linear-gradient(135deg, ${main}, ${dark})` }}
                aria-hidden
              />
              {folder.name}
            </button>
          );
        })}
      </div>
      <div className={styles.dialogActions}>
        <Button tone="secondary" onClick={onClose}>{t('actions.cancel')}</Button>
      </div>
    </Dialog>
  );
}
