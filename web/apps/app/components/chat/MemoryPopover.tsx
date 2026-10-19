'use client';

import { useState, useRef, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import type { MemoryItem } from '@oriveo/core/context/memory-items';
import { CloseButton } from '@oriveo/ui';
import { EditIcon, EyeOffIcon } from '../icons';
import { memoryItemHeadline } from './MemoryUsedPopover';
import styles from './TopBar.module.css';

/** The indicator and the preview only look at active semantic items (the slice is already in list order). */
function activeSemanticItems(memoryItems?: readonly MemoryItem[]): MemoryItem[] {
  return (memoryItems ?? []).filter((m) => m.layer === 'semantic' && m.status === 'active');
}

interface MemoryPopoverProps {
  /** The store's memoryItems slice */
  memoryItems?: readonly MemoryItem[];
  useMemory?: boolean;
  onToggleMemory?: () => void;
}

/**
 * Memory indicator and popover: a discreet dot entry point that opens a list of entries (first line of
 * each) with view, edit and disable actions. Renders nothing when the conversation switch is off or
 * there are no active semantic entries.
 */
export function MemoryPopover({ memoryItems, useMemory, onToggleMemory }: MemoryPopoverProps) {
  const tMemory = useTranslations('pages.memory');
  const router = useRouter();
  const [showMemoryPopover, setShowMemoryPopover] = useState(false);
  const popoverRef = useRef<HTMLDivElement>(null);

  // Close on any click outside the popover.
  useEffect(() => {
    if (!showMemoryPopover) return;
    const handler = (e: MouseEvent) => {
      if (popoverRef.current && !popoverRef.current.contains(e.target as Node)) {
        setShowMemoryPopover(false);
      }
    };
    document.addEventListener('mousedown', handler);
    return () => document.removeEventListener('mousedown', handler);
  }, [showMemoryPopover]);

  const previewItems = activeSemanticItems(memoryItems);
  const showMemoryIndicator = previewItems.length > 0 && useMemory !== false;
  if (!showMemoryIndicator) return null;

  return (
    <div style={{ position: 'relative' }} ref={popoverRef}>
      <button
        type="button"
        className={styles.memoryIndicator}
        onClick={() => setShowMemoryPopover((v) => !v)}
        aria-label={tMemory('indicatorTitle')}
        title={tMemory('indicatorTitle')}
      >
        <span className={styles.memoryIndicatorDot} aria-hidden="true" />
        <span className={styles.memoryIndicatorLabel}>{tMemory('title')}</span>
      </button>
      {showMemoryPopover && (
        <div className={styles.memoryPopover}>
          <div className={styles.memoryPopoverHero}>
            <div className={styles.memoryPopoverHeroIcon} aria-hidden="true">🧠</div>
            <div className={styles.memoryPopoverHeroText}>
              <p className={styles.memoryPopoverTitle}>{tMemory('indicatorTitle')}</p>
              <span className={styles.memoryPopoverBadge}>{tMemory('title')}</span>
            </div>
            <CloseButton
              className={styles.memoryPopoverClose}
              label={tMemory('close')}
              title={tMemory('close')}
              onClick={() => setShowMemoryPopover(false)}
            />
          </div>

          <div className={styles.memoryPopoverPreviewCard}>
            <div className={styles.memoryPopoverPreviewHeader}>
              <span className={styles.memoryPopoverPreviewLabel}>{tMemory('title')}</span>
              <span className={styles.memoryPopoverPreviewIcon} aria-hidden="true">🧠</span>
            </div>
            <ul className={styles.memoryPopoverPreview}>
              {previewItems.map((item) => (
                <li key={item.id}>{memoryItemHeadline(item.content)}</li>
              ))}
            </ul>
          </div>

          <div className={styles.memoryPopoverActions}>
            <button
              type="button"
              className={styles.memoryPopoverPrimaryAction}
              onClick={() => { setShowMemoryPopover(false); router.push('/settings/memory'); }}
            >
              <span className={styles.memoryPopoverActionIconWrap} aria-hidden="true">
                <EditIcon />
              </span>
              <span className={styles.memoryPopoverActionText}>{tMemory('indicatorViewEdit')}</span>
              <span className={styles.memoryPopoverActionChevron} aria-hidden="true">›</span>
            </button>
            <button
              type="button"
              className={styles.memoryPopoverDangerAction}
              onClick={() => { onToggleMemory?.(); setShowMemoryPopover(false); }}
            >
              <span className={styles.memoryPopoverActionIconDangerWrap} aria-hidden="true">
                <EyeOffIcon />
              </span>
              <span className={styles.memoryPopoverDangerText}>{tMemory('indicatorDisable')}</span>
              <span className={styles.memoryPopoverActionChevronDanger} aria-hidden="true">›</span>
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
