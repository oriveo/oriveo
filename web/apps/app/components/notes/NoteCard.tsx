'use client';

import type { Note } from '@oriveo/shared';
import { ChevronRight, Pin, StickyNote, Tag, Trash2 } from 'lucide-react';
import { useMemo, type CSSProperties } from 'react';
import { useTranslations } from 'next-intl';
import { PROVIDER_BRAND_COLORS } from '../../lib/constants/provider-brand-colors';
import { stripMarkdownForClipboard, stripMarkdownForPreview } from '../../lib/utils/markdown-preview';
import { NoteSourceBadge } from './NoteSourceBadge';
import { noteDisplayBody } from './note-display-text';
import styles from './Notes.module.css';

interface NoteCardProps {
  note: Note;
  onOpen: (noteId: string) => void;
  onDelete?: (noteId: string) => void;
}

function formatDate(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleDateString();
}

export function NoteCard({ note, onOpen, onDelete }: NoteCardProps) {
  const t = useTranslations('notes');
  // The preview is truncated to 280 characters before stripping, so a long answer does not run
  // the full regex on every render; memo keeps it from recomputing while the search box is typed in.
  const preview = useMemo(() => {
    const displayBody = noteDisplayBody(note.body, note.bodySnapshot);
    const raw = (displayBody || note.userNote || '').slice(0, 280);
    // An answer that is only code: stripMarkdownForPreview deletes the whole fenced block, the
    // preview comes out empty, and the card wrongly reads as having no content. Fall back to the
    // clipboard variant, which keeps the code, collapsed to a single line.
    return stripMarkdownForPreview(raw) || stripMarkdownForClipboard(raw).replace(/\s+/g, ' ').trim();
  }, [note.body, note.bodySnapshot, note.userNote]);
  const title = note.title.trim() || t('untitled');
  const sourceColor = note.sourceProviderKind
    ? PROVIDER_BRAND_COLORS[note.sourceProviderKind]?.light ?? PROVIDER_BRAND_COLORS.relay.light
    : 'var(--o-primary)';
  const visibleTags = note.tags.slice(0, 2);
  const hiddenTagCount = Math.max(0, note.tags.length - visibleTags.length);
  const hasSource = Boolean(note.sourceProviderKind);

  return (
    <div
      role="button"
      tabIndex={0}
      className={styles.noteCard}
      style={{ '--note-source-color': sourceColor } as CSSProperties}
      onClick={() => onOpen(note.id)}
      data-pinned={note.isPinned ? 'true' : undefined}
      onKeyDown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          onOpen(note.id);
        }
      }}
    >
      <div className={styles.noteContent}>
        <div className={styles.noteMetaBar}>
          <span className={styles.sourceSlot}>
            {hasSource ? (
              <NoteSourceBadge
                providerKind={note.sourceProviderKind}
                providerName={note.sourceProviderName}
                modelName={note.sourceModelName}
                compact={false}
              />
            ) : (
              <span className={styles.manualSourceToken}>
                <StickyNote size={13} aria-hidden />
                <span>{t('title')}</span>
              </span>
            )}
          </span>
          <span className={styles.metaActions}>
            {note.isPinned ? (
              <span className={styles.pinTag} aria-label={t('labels.pinned')}>
                <Pin size={12} aria-hidden />
              </span>
            ) : null}
            <span className={styles.metaDate}>{formatDate(note.updatedAt)}</span>
            <ChevronRight size={16} className={styles.detailGlyph} aria-hidden />
          </span>
        </div>
        <span className={styles.noteTitle}>{title}</span>
        <span className={styles.noteExcerptPanel}>
          <span className={styles.notePreview}>{preview || t('empty.body')}</span>
        </span>
        {visibleTags.length > 0 ? (
          <span className={styles.noteTagPreview}>
            {visibleTags.map((tag) => (
              <span key={tag} className={styles.noteTagChip}>
                <Tag size={11} aria-hidden />
                {tag}
              </span>
            ))}
            {hiddenTagCount > 0 ? <span className={styles.noteTagMore}>+{hiddenTagCount}</span> : null}
          </span>
        ) : null}
      </div>
      {onDelete ? (
        <button
          type="button"
          className={styles.noteCardDelete}
          aria-label={t('actions.delete')}
          title={t('actions.delete')}
          onClick={(event) => {
            event.stopPropagation();
            onDelete(note.id);
          }}
          onKeyDown={(event) => {
            event.stopPropagation();
          }}
        >
          <Trash2 size={15} aria-hidden />
        </button>
      ) : null}
    </div>
  );
}
