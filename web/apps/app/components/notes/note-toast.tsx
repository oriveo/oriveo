'use client';

import type { Note } from '@oriveo/shared';
import { showRichToast } from '../Toast';
import styles from './Notes.module.css';

interface SavedNoteToastOptions {
  note: Note;
  fallbackTitle: string;
  viewLabel: string;
  onView: () => void;
}

export function showSavedNoteToast({ note, fallbackTitle, viewLabel, onView }: SavedNoteToastOptions) {
  const title = note.title.trim() || fallbackTitle;
  showRichToast(
    <span className={styles.savedToast}>
      <span className={styles.savedToastTitle}>{title}</span>
      <button type="button" onClick={onView}>{viewLabel}</button>
    </span>,
    4000,
    'success',
  );
}
