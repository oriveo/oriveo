'use client';

import type { Note } from '@oriveo/shared';
import { Trash2 } from 'lucide-react';
import { Button, EmptyState } from '@oriveo/ui';
import { useTranslations } from 'next-intl';
import { useState } from 'react';
import { getVanillaStore } from '../../providers/StoreProvider';
import { emptyTrash, restoreNote } from '../../lib/core/note-ops';
import { showToast } from '../Toast';
import { ConfirmDialog } from '../dialogs/ConfirmDialog';
import { NoteCard } from './NoteCard';
import styles from './Notes.module.css';

interface NoteTrashViewProps {
  notes: Note[];
  onOpenNote: (noteId: string) => void;
}

export function NoteTrashView({ notes, onOpenNote }: NoteTrashViewProps) {
  const t = useTranslations('notes');
  const [showEmptyConfirm, setShowEmptyConfirm] = useState(false);

  if (notes.length === 0) {
    return (
      <EmptyState
        icon={<Trash2 size={28} aria-hidden />}
        title={t('trash.emptyTitle')}
        description={t('trash.emptyDescription')}
      />
    );
  }

  return (
    <section className={styles.trashSection}>
      <div className={styles.trashHeader}>
        <div>
          <h2>{t('trash.title')}</h2>
          <p>{t('trash.description', { count: notes.length })}</p>
        </div>
        <Button
          tone="danger"
          size="sm"
          onClick={() => setShowEmptyConfirm(true)}
        >
          {t('trash.empty')}
        </Button>
      </div>
      <div className={styles.listStack}>
        {notes.map((note) => (
          <div key={note.id} className={styles.trashItem}>
            <NoteCard note={note} onOpen={onOpenNote} />
            <Button
              tone="secondary"
              size="sm"
              onClick={() => {
                restoreNote(getVanillaStore(), note.id);
                showToast(t('toast.restored'), 3000, undefined, 'success');
              }}
            >
              {t('trash.restore')}
            </Button>
          </div>
        ))}
      </div>
      <ConfirmDialog
        open={showEmptyConfirm}
        title={t('trash.emptyConfirmTitle')}
        message={t('trash.emptyConfirmMessage')}
        confirmLabel={t('trash.empty')}
        cancelLabel={t('actions.cancel')}
        destructive
        onConfirm={() => {
          emptyTrash(getVanillaStore());
          setShowEmptyConfirm(false);
          showToast(t('toast.trashEmptied'), 3000, undefined, 'success');
        }}
        onCancel={() => setShowEmptyConfirm(false)}
      />
    </section>
  );
}
