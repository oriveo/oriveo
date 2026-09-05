'use client';

import { useState, useRef, useEffect } from 'react';
import { useTranslations } from 'next-intl';
import { useRouter } from 'next/navigation';
import { graphemeCount, takeGraphemes } from '../../lib/utils/grapheme-utils';
import { CloseIcon, EditIcon, EyeOffIcon } from '../icons';
import styles from './TopBar.module.css';

function getMemoryPreview(memoryText?: string): string {
  const normalizedText = memoryText?.trim() ?? '';
  if (!normalizedText) return '';

  const preview = takeGraphemes(normalizedText, 300);
  return `${preview}${graphemeCount(normalizedText) > 300 ? '...' : ''}`;
}

interface MemoryPopoverProps {
  memoryText?: string;
  useMemory?: boolean;
  onToggleMemory?: () => void;
}

/**
 * Memory indicator and popover: a discreet dot entry point that opens a memory preview with view, edit
 * and disable actions. Renders nothing when memory is empty or disabled.
 */
export function MemoryPopover({ memoryText, useMemory, onToggleMemory }: MemoryPopoverProps) {
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

  const showMemoryIndicator = !!memoryText?.trim() && useMemory !== false;
  if (!showMemoryIndicator) return null;

  const memoryPreview = getMemoryPreview(memoryText);

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
            <button
              type="button"
              className={styles.memoryPopoverClose}
              aria-label={tMemory('close')}
              title={tMemory('close')}
              onClick={() => setShowMemoryPopover(false)}
            >
              <CloseIcon />
            </button>
          </div>

          <div className={styles.memoryPopoverPreviewCard}>
            <div className={styles.memoryPopoverPreviewHeader}>
              <span className={styles.memoryPopoverPreviewLabel}>{tMemory('title')}</span>
              <span className={styles.memoryPopoverPreviewIcon} aria-hidden="true">🧠</span>
            </div>
            <p className={styles.memoryPopoverPreview}>{memoryPreview}</p>
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
