'use client';

import { useState, useCallback, useEffect, useRef } from 'react';
import { useTranslations } from 'next-intl';
import { SearchIcon, CloseIcon } from '@oriveo/ui';
import styles from './MessageSearch.module.css';

interface MessageSearchProps {
  matchCount: number;
  currentIndex: number;
  onQueryChange: (query: string) => void;
  onNext: () => void;
  onPrev: () => void;
  onClose: () => void;
}

export function MessageSearch({
  matchCount,
  currentIndex,
  onQueryChange,
  onNext,
  onPrev,
  onClose,
}: MessageSearchProps) {
  const t = useTranslations('search');
  const [query, setQuery] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout>>(undefined);

  useEffect(() => {
    inputRef.current?.focus();
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, []);

  useEffect(() => {
    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [onClose]);

  const handleChange = useCallback(
    (value: string) => {
      setQuery(value);
      if (debounceRef.current) clearTimeout(debounceRef.current);
      debounceRef.current = setTimeout(() => {
        onQueryChange(value);
      }, 200);
    },
    [onQueryChange],
  );

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (e.shiftKey) onPrev();
        else onNext();
      }
    },
    [onNext, onPrev],
  );

  return (
    <div className={styles.bar}>
      <div className={styles.inputWrap}>
        <SearchIcon className={styles.searchIcon} />
        <input
          ref={inputRef}
          className={styles.input}
          type="text"
          placeholder={t('placeholder')}
          value={query}
          onChange={(e) => handleChange(e.target.value)}
          onKeyDown={handleKeyDown}
          aria-label={t('placeholder')}
        />
        {query && matchCount > 0 && (
          <span className={styles.count}>
            {currentIndex + 1}/{matchCount}
          </span>
        )}
      </div>

      <div className={styles.actions}>
        <button
          type="button"
          className={styles.navBtn}
          onClick={onPrev}
          disabled={matchCount === 0}
          aria-label={t('prevMatch')}
          title={t('prevMatch')}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="18 15 12 9 6 15" />
          </svg>
        </button>
        <button
          type="button"
          className={styles.navBtn}
          onClick={onNext}
          disabled={matchCount === 0}
          aria-label={t('nextMatch')}
          title={t('nextMatch')}
        >
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <polyline points="6 9 12 15 18 9" />
          </svg>
        </button>
        <button
          type="button"
          className={styles.closeBtn}
          onClick={onClose}
          aria-label={t('close')}
          title={t('close')}
        >
          <CloseIcon />
        </button>
      </div>
    </div>
  );
}
