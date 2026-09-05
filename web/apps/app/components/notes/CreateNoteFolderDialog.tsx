'use client';

import { useState } from 'react';
import { Button, Dialog } from '@oriveo/ui';
import { useTranslations } from 'next-intl';
import { getVanillaStore } from '../../providers/StoreProvider';
import { createNoteFolder } from '../../lib/core/note-ops';
import { showToast } from '../Toast';
import { FolderColorGrid } from './FolderColorGrid';
import styles from './Notes.module.css';

interface CreateNoteFolderDialogProps {
  open: boolean;
  onClose: () => void;
  /** Called with the new folder id after a successful create, so the caller can switch to it. */
  onCreated?: (folderId: string) => void;
}

export function CreateNoteFolderDialog({ open, onClose, onCreated }: CreateNoteFolderDialogProps) {
  const t = useTranslations('notes');
  const tSidebar = useTranslations('sidebar');
  const [name, setName] = useState('');
  const [colorTag, setColorTag] = useState('blue');

  const handleCreate = () => {
    const folder = createNoteFolder(getVanillaStore(), name, colorTag);
    if (!folder) return;
    showToast(t('toast.folderCreated', { name: folder.name }), 3000, undefined, 'success');
    setName('');
    setColorTag('blue');
    onCreated?.(folder.id);
    onClose();
  };

  return (
    <Dialog open={open} onClose={onClose}>
      <h2 className={styles.dialogTitle}>{t('folders.new')}</h2>
      <label className={styles.fieldLabel}>
        <span>{t('folders.name')}</span>
        <input
          value={name}
          onChange={(event) => setName(event.target.value)}
          maxLength={30}
          autoFocus
          className={styles.textInput}
        />
      </label>
      <div className={styles.fieldLabel}>
        <span>{tSidebar('changeColor')}</span>
        <FolderColorGrid value={colorTag} onChange={setColorTag} />
      </div>
      <div className={styles.dialogActions}>
        <Button tone="secondary" onClick={onClose}>{t('actions.cancel')}</Button>
        <Button onClick={handleCreate} disabled={!name.trim()}>{t('actions.create')}</Button>
      </div>
    </Dialog>
  );
}
