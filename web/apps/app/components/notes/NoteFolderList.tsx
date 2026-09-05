'use client';

import type React from 'react';
import type { Note, NoteFolder } from '@oriveo/shared';
import { getFolderColorPair } from '@oriveo/shared';
import { Folder, Inbox, Pencil, Trash2 } from 'lucide-react';
import { useTranslations } from 'next-intl';
import { useState } from 'react';
import { Button, Dialog } from '@oriveo/ui';
import { getVanillaStore } from '../../providers/StoreProvider';
import { deleteNoteFolder, renameNoteFolder, updateNoteFolderColor } from '../../lib/core/note-ops';
import { ConfirmDialog } from '../dialogs/ConfirmDialog';
import { FolderColorGrid } from './FolderColorGrid';
import styles from './Notes.module.css';

export const UNCATEGORIZED_NOTE_FOLDER_FILTER = '__uncategorized__';

interface NoteFolderListProps {
  folders: NoteFolder[];
  notes: Note[];
  activeFolderId: string | null;
  onSelectFolder: (folderId: string | null) => void;
}

export function NoteFolderList({ folders, notes, activeFolderId, onSelectFolder }: NoteFolderListProps) {
  const t = useTranslations('notes');
  const tSidebar = useTranslations('sidebar');
  const [editingFolder, setEditingFolder] = useState<NoteFolder | null>(null);
  const [editingName, setEditingName] = useState('');
  const [editingColor, setEditingColor] = useState('blue');
  const [deletingFolder, setDeletingFolder] = useState<NoteFolder | null>(null);
  const countFor = (folderId: string | null) =>
    notes.filter((note) => (folderId ? note.noteFolderID === folderId : !note.noteFolderID)).length;
  const sortedFolders = [...folders].sort((a, b) => a.sortOrder - b.sortOrder);

  const startEdit = (folder: NoteFolder) => {
    setEditingFolder(folder);
    setEditingName(folder.name);
    setEditingColor(folder.colorTag ?? 'blue');
  };

  const submitEdit = () => {
    if (!editingFolder || !editingName.trim()) return;
    const store = getVanillaStore();
    renameNoteFolder(store, editingFolder.id, editingName);
    updateNoteFolderColor(store, editingFolder.id, editingColor);
    setEditingFolder(null);
    setEditingName('');
  };

  return (
    <div className={styles.folderList}>
      <button
        type="button"
        className={styles.folderItem}
        data-active={activeFolderId === null ? 'true' : undefined}
        onClick={() => onSelectFolder(null)}
        style={{ '--folder-color': 'var(--o-primary-active)' } as React.CSSProperties}
      >
        <Inbox size={16} aria-hidden />
        <span>{t('folders.all')}</span>
        <span className={styles.folderCount}>{notes.length}</span>
      </button>
      {sortedFolders.map((folder) => (
        <div key={folder.id} className={styles.folderRow} data-active={activeFolderId === folder.id ? 'true' : undefined} style={{ '--folder-color': getFolderColorPair(folder.colorTag ?? 'blue')[0] } as React.CSSProperties}>
          <button
            type="button"
            className={styles.folderItem}
            onClick={() => onSelectFolder(folder.id)}
          >
            <Folder size={16} aria-hidden style={{ color: getFolderColorPair(folder.colorTag ?? 'blue')[0] }} />
            <span>{folder.name}</span>
            <span className={styles.folderCount}>{countFor(folder.id)}</span>
          </button>
          <button
            type="button"
            className={styles.folderIconButton}
            aria-label={t('folders.edit')}
            onClick={() => startEdit(folder)}
          >
            <Pencil size={14} aria-hidden />
          </button>
          <button
            type="button"
            className={styles.folderIconButton}
            aria-label={t('folders.delete')}
            onClick={() => setDeletingFolder(folder)}
          >
            <Trash2 size={14} aria-hidden />
          </button>
        </div>
      ))}
      <button
        type="button"
        className={`${styles.folderItem} ${styles.uncategorizedCount}`}
        data-active={activeFolderId === UNCATEGORIZED_NOTE_FOLDER_FILTER ? 'true' : undefined}
        onClick={() => onSelectFolder(UNCATEGORIZED_NOTE_FOLDER_FILTER)}
        style={{ '--folder-color': 'var(--o-primary-active)' } as React.CSSProperties}
      >
        <Inbox size={16} aria-hidden />
        <span>{t('folders.uncategorized')}</span>
        <span className={styles.folderCount}>{countFor(null)}</span>
      </button>
      <Dialog open={Boolean(editingFolder)} onClose={() => setEditingFolder(null)}>
        <h2 className={styles.dialogTitle}>{t('folders.edit')}</h2>
        <label className={styles.fieldLabel}>
          <span>{t('folders.name')}</span>
          <input
            value={editingName}
            onChange={(event) => setEditingName(event.target.value)}
            maxLength={30}
            autoFocus
            className={styles.textInput}
          />
        </label>
        <div className={styles.fieldLabel}>
          <span>{tSidebar('changeColor')}</span>
          <FolderColorGrid value={editingColor} onChange={setEditingColor} />
        </div>
        <div className={styles.dialogActions}>
          <Button tone="secondary" onClick={() => setEditingFolder(null)}>{t('actions.cancel')}</Button>
          <Button onClick={submitEdit} disabled={!editingName.trim()}>{t('actions.save')}</Button>
        </div>
      </Dialog>
      <ConfirmDialog
        open={Boolean(deletingFolder)}
        title={t('folders.delete')}
        message={deletingFolder ? t('folders.deleteMessage', { name: deletingFolder.name }) : undefined}
        confirmLabel={t('folders.delete')}
        cancelLabel={t('actions.cancel')}
        destructive
        onConfirm={() => {
          if (deletingFolder) {
            // Move the selection out of the folder before deleting it: deleting the active folder would
            // otherwise flash one frame of "this folder has no notes".
            if (activeFolderId === deletingFolder.id) onSelectFolder(null);
            deleteNoteFolder(getVanillaStore(), deletingFolder.id);
          }
          setDeletingFolder(null);
        }}
        onCancel={() => setDeletingFolder(null)}
      />
    </div>
  );
}
