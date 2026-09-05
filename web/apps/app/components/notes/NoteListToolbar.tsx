'use client';

import { Search, SlidersHorizontal, Tag, X } from 'lucide-react';
import { useTranslations } from 'next-intl';
import type { NoteSortKey } from '../../lib/utils/note-list';
import styles from './Notes.module.css';

interface NoteListToolbarProps {
  query: string;
  onQueryChange: (value: string) => void;
  sortKey: NoteSortKey;
  onSortKeyChange: (value: NoteSortKey) => void;
  allTags: string[];
  selectedTags: string[];
  onSelectedTagsChange: (tags: string[]) => void;
}

export function NoteListToolbar({
  query,
  onQueryChange,
  sortKey,
  onSortKeyChange,
  allTags,
  selectedTags,
  onSelectedTagsChange,
}: NoteListToolbarProps) {
  const t = useTranslations('notes');

  const toggleTag = (tag: string) => {
    onSelectedTagsChange(
      selectedTags.includes(tag)
        ? selectedTags.filter((item) => item !== tag)
        : [...selectedTags, tag],
    );
  };

  return (
    <div className={styles.toolbar}>
      <label className={styles.searchBox}>
        <Search size={16} aria-hidden />
        <input
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          placeholder={t('search.placeholder')}
        />
        {query ? (
          <button type="button" onClick={() => onQueryChange('')} aria-label={t('search.clear')}>
            <X size={14} aria-hidden />
          </button>
        ) : null}
      </label>
      <label className={styles.selectBox}>
        <SlidersHorizontal size={16} aria-hidden />
        <select value={sortKey} onChange={(event) => onSortKeyChange(event.target.value as NoteSortKey)}>
          <option value="updatedAt">{t('sort.updatedAt')}</option>
          <option value="createdAt">{t('sort.createdAt')}</option>
          <option value="sourceProviderKind">{t('sort.sourceProviderKind')}</option>
        </select>
      </label>
      {allTags.length > 0 ? (
        <div className={styles.tagFilterPanel} aria-label={t('tags.filter')}>
          {allTags.slice(0, 12).map((tag) => (
            <button
              key={tag}
              type="button"
              className={styles.tagChip}
              data-active={selectedTags.includes(tag) ? 'true' : undefined}
              onClick={() => toggleTag(tag)}
            >
              <Tag size={11} aria-hidden className={styles.tagChipIcon} />
              {tag}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}
