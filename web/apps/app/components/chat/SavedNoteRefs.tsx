'use client';

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { FileText } from 'lucide-react';
import styles from './MessageBubble.module.css';

interface SavedNoteRefItem {
  id: string;
  title: string;
}

interface SavedNoteRefsProps {
  refs: SavedNoteRefItem[];
  onOpen: (id: string) => void;
}

/**
 * Reference labels for assistant messages that were saved as notes.
 * A single note opens directly; several collapse into one chip with "+N" that expands into a
 * dropdown listing them all.
 */
export function SavedNoteRefs({ refs, onOpen }: SavedNoteRefsProps) {
  const t = useTranslations('pages.chat');
  const [open, setOpen] = useState(false);
  const [dropUp, setDropUp] = useState(false);
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) {
      return;
    }

    menuRef.current?.querySelector<HTMLButtonElement>('[role="menuitem"]')?.focus();

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (target instanceof Node && wrapRef.current?.contains(target)) {
        return;
      }
      setOpen(false);
    };
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') {
        return;
      }
      event.preventDefault();
      setOpen(false);
      buttonRef.current?.focus();
    };

    document.addEventListener('pointerdown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('pointerdown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [open]);

  if (refs.length === 0) {
    return null;
  }

  const label = t('savedAsNote');
  const primary = refs[0];

  // Single note: open directly, no dropdown
  if (refs.length === 1) {
    return (
      <div className={styles.savedNoteRefs}>
        <button type="button" className={styles.savedNoteRef} onClick={() => onOpen(primary.id)}>
          <FileText size={14} aria-hidden />
          <span>{label}</span>
          <strong>{primary.title}</strong>
        </button>
      </div>
    );
  }

  // Several notes: collapse into one chip with "+N" that expands into a dropdown listing them all
  const overflow = refs.length - 1;
  return (
    <div className={styles.savedNoteRefs}>
      <div className={styles.savedNoteRefWrap} ref={wrapRef}>
        <button
          ref={buttonRef}
          type="button"
          className={styles.savedNoteRef}
          aria-haspopup="menu"
          aria-expanded={open}
          onClick={() => {
            if (!open && buttonRef.current) {
              const rect = buttonRef.current.getBoundingClientRect();
              setDropUp(window.innerHeight - rect.bottom < 220);
            }
            setOpen((value) => !value);
          }}
        >
          <FileText size={14} aria-hidden />
          <span>{label}</span>
          <strong>{primary.title}</strong>
          <span>{`+${overflow}`}</span>
        </button>
        {open && (
          <div
            className={`${styles.metaActionMenu}${dropUp ? ` ${styles.metaActionMenuUp}` : ''}`}
            ref={menuRef}
            role="menu"
          >
            {refs.map((ref) => (
              <button
                key={ref.id}
                type="button"
                className={styles.metaActionMenuItem}
                role="menuitem"
                onClick={() => {
                  setOpen(false);
                  onOpen(ref.id);
                }}
              >
                <FileText size={14} aria-hidden />
                <span>{ref.title}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
