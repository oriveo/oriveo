'use client';

import { useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import type { MemoryItem } from '@oriveo/core/context/memory-items';
import { useAppStore } from '../../providers/StoreProvider';
import { graphemeCount, takeGraphemes } from '../../lib/utils/grapheme-utils';
import styles from './MemoryUsedPopover.module.css';

const HEADLINE_MAX_GRAPHEMES = 60;

/** First line of an item: the first non-empty line, truncated with an ellipsis beyond 60 characters. */
export function memoryItemHeadline(content: string): string {
  const firstLine = content.split(/\r?\n/).map((line) => line.trim()).find((line) => line.length > 0) ?? '';
  if (graphemeCount(firstLine) <= HEADLINE_MAX_GRAPHEMES) return firstLine;
  return `${takeGraphemes(firstLine, HEADLINE_MAX_GRAPHEMES)}…`;
}

interface MemoryUsedPopoverProps {
  memoryItemIds: readonly string[];
  /** Class on the anchor's outer element (MessageMeta passes metaPill to keep the same font size, color and separator dot). */
  className?: string;
}

/**
 * Small "memory" marker at the end of the assistant message's meta row: opening it lists the first lines of the memory items used for this answer;
 * [This is wrong] jumps to the memory settings page to edit that item directly; if the item was deleted or does not exist locally it shows "Deleted memory" with no button.
 */
export function MemoryUsedPopover({ memoryItemIds, className }: MemoryUsedPopoverProps) {
  const t = useTranslations('pages.memory');
  const [open, setOpen] = useState(false);
  const anchorRef = useRef<HTMLSpanElement>(null);
  const chipRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (!open) return;
    const handlePointerDown = (event: MouseEvent) => {
      if (anchorRef.current && !anchorRef.current.contains(event.target as Node)) setOpen(false);
    };
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return;
      setOpen(false);
      chipRef.current?.focus();
    };
    document.addEventListener('mousedown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);
    return () => {
      document.removeEventListener('mousedown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
    };
  }, [open]);

  if (memoryItemIds.length === 0) return null;

  return (
    <span ref={anchorRef} className={[className, styles.anchor].filter(Boolean).join(' ')}>
      <button
        ref={chipRef}
        type="button"
        className={styles.chip}
        aria-label={t('used.a11y')}
        aria-haspopup="dialog"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        {t('used.chip')}
      </button>
      {open && <MemoryUsedPanel memoryItemIds={memoryItemIds} onClose={() => setOpen(false)} />}
    </span>
  );
}

/** Mounted only after opening: the store / router stay out of the message list's hot render path. */
function MemoryUsedPanel({ memoryItemIds, onClose }: { memoryItemIds: readonly string[]; onClose: () => void }) {
  const t = useTranslations('pages.memory');
  const router = useRouter();
  const memoryItems = useAppStore((s) => s.memoryItems);
  const byId = new Map<string, MemoryItem>(memoryItems.map((item) => [item.id, item]));
  const title = t('used.title');

  return (
    <div className={styles.popover} role="dialog" aria-label={title}>
      <p className={styles.title}>{title}</p>
      <ul className={styles.list}>
        {memoryItemIds.map((id, index) => {
          const item = byId.get(id);
          const live = item && item.status !== 'deleted' ? item : null;
          return (
            <li key={`${id}:${index}`} className={styles.row}>
              {live ? (
                <>
                  <span className={styles.headline}>{memoryItemHeadline(live.content)}</span>
                  <button
                    type="button"
                    className={styles.fix}
                    onClick={() => {
                      onClose();
                      router.push(`/settings/memory?edit=${encodeURIComponent(live.id)}`);
                    }}
                  >
                    {t('used.wrong')}
                  </button>
                </>
              ) : (
                <span className={styles.deleted}>{t('used.deleted')}</span>
              )}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
