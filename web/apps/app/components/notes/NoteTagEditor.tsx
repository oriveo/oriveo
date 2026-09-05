'use client';

import { useState } from 'react';
import { Plus, SendHorizonal, Tag, X } from 'lucide-react';
import { useTranslations } from 'next-intl';
import styles from './Notes.module.css';

interface NoteTagEditorProps {
  tags: string[];
  availableTags?: string[];
  compact?: boolean;
  editable?: boolean;
  onChange: (tags: string[]) => void;
}

export function NoteTagEditor({ tags, availableTags = [], compact = false, editable = true, onChange }: NoteTagEditorProps) {
  const t = useTranslations('notes');
  const [draft, setDraft] = useState('');
  const [showCompactInput, setShowCompactInput] = useState(false);

  const addTag = (value = draft) => {
    const tag = value.trim();
    if (!tag || tags.some((item) => item.trim().toLocaleLowerCase() === tag.toLocaleLowerCase())) {
      setDraft('');
      return;
    }
    onChange([...tags, tag]);
    setDraft('');
    setShowCompactInput(false);
  };

  const needle = draft.trim().toLocaleLowerCase();
  const existing = new Set(tags.map((tag) => tag.trim().toLocaleLowerCase()));
  const suggestions = availableTags
    .map((tag) => tag.trim())
    .filter((tag) => tag && !existing.has(tag.toLocaleLowerCase()))
    .filter((tag, index, arr) => arr.findIndex((item) => item.toLocaleLowerCase() === tag.toLocaleLowerCase()) === index)
    .filter((tag) => !needle || tag.toLocaleLowerCase().includes(needle))
    .slice(0, 12);

  return (
    <div className={compact ? styles.compactTagEditor : styles.tagEditor}>
      {!compact && tags.length > 0 ? (
        <div className={styles.tagList}>
          {tags.map((tag) => (
            <span key={tag} className={styles.tagChip} data-active="true">
              <Tag size={11} aria-hidden className={styles.tagChipIcon} />
              {tag}
              {editable ? (
                <button type="button" onClick={() => onChange(tags.filter((item) => item !== tag))} aria-label={t('tags.remove', { tag })}>
                  <X size={12} aria-hidden />
                </button>
              ) : null}
            </span>
          ))}
        </div>
      ) : null}
      {editable ? (
        <>
          {compact && !showCompactInput ? (
            <button type="button" className={styles.inlineAddTagButton} onClick={() => setShowCompactInput(true)}>
              <Plus size={12} aria-hidden />
              {t('tags.add')}
            </button>
          ) : (
          <div className={styles.tagInputRow}>
            <input
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') {
                  event.preventDefault();
                  addTag();
                }
              }}
              placeholder={t('tags.add')}
              className={styles.textInput}
            />
            <button type="button" className={styles.iconButton} onClick={() => addTag()} disabled={!draft.trim()}>
              <SendHorizonal size={15} aria-hidden />
            </button>
          </div>
          )}
          {!compact && suggestions.length > 0 ? (
            <div className={styles.tagSuggestionList}>
              {suggestions.map((tag) => (
                <button key={tag} type="button" className={styles.tagChip} onClick={() => addTag(tag)} aria-label={`# ${tag}`}>
                  <Tag size={11} aria-hidden className={styles.tagChipIcon} />
                  {tag}
                </button>
              ))}
            </div>
          ) : null}
        </>
      ) : null}
    </div>
  );
}
