'use client';

import type { Note } from '@oriveo/shared';
import { FileText } from 'lucide-react';
import { Button, EmptyState } from '@oriveo/ui';
import { useTranslations } from 'next-intl';
import { SkeletonLine } from '../SkeletonPrimitive';
import { NoteCard } from './NoteCard';
import styles from './Notes.module.css';

interface NoteListProps {
  notes: Note[];
  loading: boolean;
  onOpenNote: (noteId: string) => void;
  onCreateBlank: () => void;
  onDeleteNote?: (noteId: string) => void;
}

export function NoteList({ notes, loading, onOpenNote, onCreateBlank, onDeleteNote }: NoteListProps) {
  const t = useTranslations('notes');

  if (loading) {
    return (
      <div className={styles.listStack}>
        {Array.from({ length: 5 }, (_, index) => (
          <div key={index} className={styles.noteCardSkeleton}>
            <SkeletonLine width="52%" height="17px" />
            <SkeletonLine width="86%" height="13px" />
            <SkeletonLine width="35%" height="12px" />
          </div>
        ))}
      </div>
    );
  }

  if (notes.length === 0) {
    return (
      <EmptyState
        icon={<FileText size={28} aria-hidden />}
        title={t('empty.title')}
        description={t('empty.description')}
        action={<Button size="sm" onClick={onCreateBlank}>{t('actions.newBlank')}</Button>}
      />
    );
  }

  return (
    <div className={styles.listStack}>
      {notes.map((note) => (
        <NoteCard key={note.id} note={note} onOpen={onOpenNote} onDelete={onDeleteNote} />
      ))}
    </div>
  );
}
