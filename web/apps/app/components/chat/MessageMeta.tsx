'use client';

import { useEffect, useRef, useState, type CSSProperties } from 'react';
import type { KeyboardEvent as ReactKeyboardEvent } from 'react';
import { createPortal } from 'react-dom';
import { useLocale, useTranslations } from 'next-intl';
import { formatCost } from '../../lib/utils/format-utils';
import { CheckIcon, CopyIcon, RetryIcon } from '../icons';
import { FilePlus2, ListChecks, MoreHorizontal } from 'lucide-react';
import { BarChart3 } from 'lucide-react';
import {
  MessageTokenUsageDialog,
  messageTokenTotal,
  type MessageTokenUsageSnapshot,
} from './MessageTokenUsageDialog';
import styles from './MessageBubble.module.css';
import type { ChatMessage } from '@oriveo/shared';

interface MessageMetaProps {
  providerName?: string;
  modelName?: string;
  estimatedCost: number;
  copied: boolean;
  onCopy: () => void;
  /** Retry action for a delivered message; undefined while in flight, which hides the retry button. */
  onRetry?: () => void;
  onSaveNote?: () => void;
  onCrosscheck?: () => void;
  tokenUsage: MessageTokenUsageSnapshot;
  capabilityResults?: ChatMessage['capabilityResults'];
}

/**
 * Meta row under an assistant message: provider, model, cost pill, copy and retry.
 */
export function MessageMeta({ providerName, modelName, estimatedCost, copied, onCopy, onRetry, onSaveNote, onCrosscheck, tokenUsage, capabilityResults }: MessageMetaProps) {
  const locale = useLocale();
  const t = useTranslations('pages.chat');
  const tCtx = useTranslations('contextMenu');
  const tSidebar = useTranslations('sidebar');
  const [isMoreOpen, setIsMoreOpen] = useState(false);
  const [isTokenUsageOpen, setIsTokenUsageOpen] = useState(false);
  // The menu is portalled to body and positioned fixed, which takes it out of the stacking
  // context of the message list and the input bar. Otherwise the frosted input bar covers it, the
  // pointerdown passes through, and the menu items cannot be clicked.
  const [menuStyle, setMenuStyle] = useState<CSSProperties | null>(null);
  const moreWrapRef = useRef<HTMLDivElement | null>(null);
  const moreButtonRef = useRef<HTMLButtonElement | null>(null);
  const menuRef = useRef<HTMLDivElement | null>(null);

  const hasSecondaryActions = true;
  const tokenTotal = messageTokenTotal(tokenUsage);
  // The Intl formatter is built only when the user actually opens a message menu, so the hot
  // render path of the message list does not allocate one formatter per cell.
  const tokenTotalLabel = isMoreOpen
    ? tokenTotal == null
      ? t('tokenUsage.unavailable')
      : new Intl.NumberFormat(locale, { notation: 'compact', maximumFractionDigits: 1 }).format(tokenTotal)
    : '';

  useEffect(() => {
    if (!isMoreOpen) {
      return;
    }

    const focusFirstMenuItem = () => {
      const firstMenuItem = menuRef.current?.querySelector<HTMLButtonElement>('[role="menuitem"]');
      firstMenuItem?.focus();
    };

    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) {
        return;
      }
      // The menu is portalled to body and lives outside moreWrap, so it has to count as
      // 'inside the menu' too; otherwise clicking a menu item is treated as an outside click and
      // closes the menu before the click fires.
      if (moreWrapRef.current?.contains(target) || menuRef.current?.contains(target)) {
        return;
      }
      setIsMoreOpen(false);
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') {
        return;
      }
      event.preventDefault();
      setIsMoreOpen(false);
      moreButtonRef.current?.focus();
    };

    // A fixed-position menu does not follow list scrolling, so it closes on scroll or zoom, the same as ContextMenu.
    const handleDismiss = () => setIsMoreOpen(false);

    focusFirstMenuItem();
    document.addEventListener('pointerdown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);
    document.addEventListener('scroll', handleDismiss, true);
    window.addEventListener('resize', handleDismiss);

    return () => {
      document.removeEventListener('pointerdown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
      document.removeEventListener('scroll', handleDismiss, true);
      window.removeEventListener('resize', handleDismiss);
    };
  }, [isMoreOpen]);

  const handleSecondaryAction = (action: () => void) => {
    setIsMoreOpen(false);
    action();
  };

  // Opening the menu: the fixed coordinates are derived from the position of the more button, and
  // near the bottom input bar the menu expands upward from the top edge of the button.
  const openMore = () => {
    const btn = moreButtonRef.current;
    if (!btn) return;
    const rect = btn.getBoundingClientRect();
    const MENU_MIN_WIDTH = 210; // matches the min-width of .metaActionMenu
    const left = Math.max(8, Math.min(rect.left, window.innerWidth - MENU_MIN_WIDTH - 8));
    const dropUp = window.innerHeight - rect.bottom < 180;
    setMenuStyle(
      dropUp
        ? { position: 'fixed', left, top: 'auto', bottom: window.innerHeight - rect.top + 6, zIndex: 60 }
        : { position: 'fixed', left, top: rect.bottom + 6, zIndex: 60 },
    );
    setIsMoreOpen(true);
  };

  const handleMenuKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key)) {
      return;
    }

    const items = Array.from(menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]') ?? []);
    if (items.length === 0) {
      return;
    }

    event.preventDefault();
    const currentIndex = items.indexOf(document.activeElement as HTMLButtonElement);
    const lastIndex = items.length - 1;
    const nextIndex = (() => {
      switch (event.key) {
        case 'ArrowUp':
          return currentIndex <= 0 ? lastIndex : currentIndex - 1;
        case 'Home':
          return 0;
        case 'End':
          return lastIndex;
        default:
          return currentIndex >= lastIndex ? 0 : currentIndex + 1;
      }
    })();

    items[nextIndex]?.focus();
  };

  return (
    <div className={styles.meta}>
      <div className={styles.metaInfo}>
        {providerName && <span className={styles.metaPill}>{providerName}</span>}
        {modelName && <span className={styles.metaPill}>{modelName}</span>}
        {formatCost(estimatedCost) && (
          <span className={styles.metaPill}>
            {formatCost(estimatedCost)}
          </span>
        )}
        {capabilityResults?.map((result) => (
          <span className={styles.metaPill} key={`${result.owner}:${result.revision}`} data-capability-result={result.state}>
            {t(`capabilityResult.${result.state}` as any, { owner: t(`capabilityResult.${result.owner}` as any) })}
          </span>
        ))}
      </div>
      <div className={styles.metaActions}>
        <button
          type="button"
          className={styles.metaIconBtn}
          data-copied={copied || undefined}
          onClick={onCopy}
          aria-label={copied ? t('copied') : t('copy')}
          title={copied ? t('copied') : t('copy')}
        >
          {copied ? (
            <CheckIcon size={16} />
          ) : (
            <CopyIcon size={16} />
          )}
        </button>
        {onSaveNote && (
          <button
            type="button"
            className={styles.metaActionBtn}
            onClick={onSaveNote}
            aria-label={t('saveAsNote')}
            title={t('saveAsNote')}
          >
            <FilePlus2 size={15} aria-hidden />
            <span>{t('saveAsNote')}</span>
          </button>
        )}
        {hasSecondaryActions && (
          <div className={styles.metaMoreWrap} ref={moreWrapRef}>
            <button
              ref={moreButtonRef}
              type="button"
              className={styles.metaIconBtn}
              onClick={() => (isMoreOpen ? setIsMoreOpen(false) : openMore())}
              aria-label={tSidebar('more')}
              aria-haspopup="menu"
              aria-expanded={isMoreOpen}
              title={tSidebar('more')}
            >
              <MoreHorizontal size={18} aria-hidden />
            </button>
            {isMoreOpen && menuStyle && createPortal(
              <div
                className={styles.metaActionMenu}
                style={menuStyle}
                ref={menuRef}
                role="menu"
                onKeyDown={handleMenuKeyDown}
              >
                <button
                  type="button"
                  className={styles.metaActionMenuItem}
                  role="menuitem"
                  onClick={() => {
                    setIsMoreOpen(false);
                    setIsTokenUsageOpen(true);
                  }}
                >
                  <BarChart3 size={14} aria-hidden />
                  <span>{t('tokenUsage.title')}</span>
                  <span className={styles.metaActionMenuItemValue}>{tokenTotalLabel}</span>
                </button>
                {onRetry && (
                  <button
                    type="button"
                    className={styles.metaActionMenuItem}
                    role="menuitem"
                    onClick={() => handleSecondaryAction(onRetry)}
                  >
                    <RetryIcon size={14} />
                    <span>{tCtx('regenerate')}</span>
                  </button>
                )}
                {onCrosscheck && (
                  <button
                    type="button"
                    className={styles.metaActionMenuItem}
                    role="menuitem"
                    onClick={() => handleSecondaryAction(onCrosscheck)}
                  >
                    <ListChecks size={14} aria-hidden />
                    <span>{t('crosscheckAction')}</span>
                  </button>
                )}
              </div>,
              document.body,
            )}
          </div>
        )}
      </div>
      <MessageTokenUsageDialog
        open={isTokenUsageOpen}
        usage={tokenUsage}
        onClose={() => setIsTokenUsageOpen(false)}
      />
    </div>
  );
}
