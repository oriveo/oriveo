'use client';

import type { Note } from '@oriveo/shared';
import { ArrowUpLeft, Quote, Repeat2 } from 'lucide-react';
import { Button } from '@oriveo/ui';
import { useTranslations } from 'next-intl';
import type { NoteSourceLinkState } from '../../lib/core/notes/source-link';
import { noteSourceVars } from './NoteSourceBadge';
import styles from './Notes.module.css';

interface NoteSourceCardProps {
  note: Note;
  linkState: NoteSourceLinkState;
  onJump: () => void;
  onCrosscheck?: () => void;
}

function formatDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString();
}

export function NoteSourceCard({ note, linkState, onJump, onCrosscheck }: NoteSourceCardProps) {
  const t = useTranslations('notes');
  const hasSource = note.captureKind !== 'blank' && (note.sourceModelName || note.sourceProviderName || note.sourcePrompt);
  const sourceVars = noteSourceVars(note.sourceProviderKind);

  // Keep "back to conversation" even when the source display metadata is missing; hide the whole section only when there is no source information at all.
  if (!hasSource && !linkState.available) return null;

  return (
    <section className={styles.sourcePanel} style={sourceVars}>
      <div className={styles.sourceCardHeader}>
        <h2>{t('source.title')}</h2>
        <p className={styles.mutedText}>{formatDate(note.createdAt)}</p>
      </div>
      {note.sourcePrompt ? (
        <div className={styles.promptQuote}>
          <p>{note.sourcePrompt}</p>
          <Quote size={42} aria-hidden />
        </div>
      ) : null}
      <div className={styles.sourceActions}>
        {linkState.available ? (
          <Button
            className={styles.sourcePrimaryAction}
            size="sm"
            onClick={onJump}
          >
            <span className={styles.sourceActionBadgeIcon}>
              <ArrowUpLeft size={13} aria-hidden />
            </span>
            {t('source.backToConversation')}
          </Button>
        ) : null}
        {onCrosscheck ? (
          <Button className={styles.sourceSecondaryAction} tone="secondary" size="sm" onClick={onCrosscheck}>
            <span className={styles.sourceActionBadgeIcon}>
              <Repeat2 size={13} aria-hidden />
            </span>
            {t('source.crosscheck')}
          </Button>
        ) : null}
      </div>
    </section>
  );
}
