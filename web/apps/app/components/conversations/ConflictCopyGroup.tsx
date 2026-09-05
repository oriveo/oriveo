'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslations } from 'next-intl';
import type { Conversation } from '@oriveo/shared';
import { useFocusTrap } from '../../lib/hooks/useFocusTrap';
import styles from './ConflictCopyGroup.module.css';

export const CONFLICT_COPY_COACHMARK_KEY = 'syncMerge.conflictCopyCoachmarkShown';

export interface ConflictCopyGroupProps {
  conversations: Conversation[];
  onCopyAsNew?: (conversation: Conversation) => void;
  /** Runs the actual deletion once the user has confirmed and the export, when enabled, has been triggered */
  onCleanup?: (options: { exportBeforeCleanup: boolean }) => Promise<void> | void;
  onOpen?: (conversation: Conversation) => void;
  /** Test injection: overrides the storage the coachmark reads and writes */
  coachmarkStorage?: {
    read: () => boolean;
    write: () => void;
  };
}

/**
 * Group of merge conflict copies.
 * - shown at the bottom of the conversation sidebar's main list as its own collapsible section
 * - the main list filters out `isConflictCopy === true`, so copies are rendered only here
 * - search results are not filtered, so a matching copy can be opened directly
 * - a one-off coachmark on first expand, remembered in localStorage
 */
export function ConflictCopyGroup({
  conversations,
  onCopyAsNew,
  onCleanup,
  onOpen,
  coachmarkStorage,
}: ConflictCopyGroupProps) {
  const t = useTranslations();
  const tSidebar = useTranslations('sidebar');
  const [expanded, setExpanded] = useState(false);
  const [showCoachmark, setShowCoachmark] = useState(false);
  const [showCleanupConfirm, setShowCleanupConfirm] = useState(false);
  const [exportBeforeCleanup, setExportBeforeCleanup] = useState(true);
  const coachmarkRef = useRef<HTMLDivElement>(null);
  const cleanupRef = useRef<HTMLDivElement>(null);
  useFocusTrap(coachmarkRef, showCoachmark);
  useFocusTrap(cleanupRef, showCleanupConfirm);

  const readCoachmark = useCallback((): boolean => {
    if (coachmarkStorage) return coachmarkStorage.read();
    // In private browsing, or when localStorage is unavailable, treat this as not shown yet
    // so the coachmark still appears. A fallback of true meant it never appeared in private
    // browsing.
    if (typeof window === 'undefined') return false;
    try {
      return window.localStorage.getItem(CONFLICT_COPY_COACHMARK_KEY) === '1';
    } catch {
      return false;
    }
  }, [coachmarkStorage]);

  const writeCoachmark = useCallback((): void => {
    if (coachmarkStorage) {
      coachmarkStorage.write();
      return;
    }
    if (typeof window === 'undefined') return;
    try {
      window.localStorage.setItem(CONFLICT_COPY_COACHMARK_KEY, '1');
    } catch {
      // A storage failure (private mode and the like) is ignored.
    }
  }, [coachmarkStorage]);

  // On expand, show the coachmark if it has not been shown before
  useEffect(() => {
    if (!expanded) return;
    if (!readCoachmark()) {
      setShowCoachmark(true);
    }
  }, [expanded, readCoachmark]);

  const dismissCoachmark = useCallback(() => {
    writeCoachmark();
    setShowCoachmark(false);
  }, [writeCoachmark]);

  const handleCleanupClick = useCallback(() => {
    setExportBeforeCleanup(true);
    setShowCleanupConfirm(true);
  }, []);

  const handleCleanupConfirm = useCallback(async () => {
    setShowCleanupConfirm(false);
    await onCleanup?.({ exportBeforeCleanup });
  }, [exportBeforeCleanup, onCleanup]);

  if (conversations.length === 0) return null;

  return (
    <section className={styles.section} aria-label={t('syncMerge.conflictCopy.section')}>
      <button
        type="button"
        onClick={() => setExpanded((v) => !v)}
        className={styles.header}
        aria-expanded={expanded}
      >
        <span>{t('syncMerge.conflictCopy.section')}</span>
        <span className={styles.count}>{conversations.length}</span>
      </button>

      {expanded ? (
        <div className={styles.list}>
          {conversations.map((conversation) => (
            <div key={conversation.id} className={styles.item}>
              <button
                type="button"
                onClick={() => onOpen?.(conversation)}
                className={styles.titleButton}
              >
                {conversation.title || tSidebar('untitled')}
              </button>
              <p className={styles.banner}>{t('syncMerge.conflictCopy.banner')}</p>
              {onCopyAsNew ? (
                <button
                  type="button"
                  onClick={() => onCopyAsNew(conversation)}
                  className={styles.actionButton}
                >
                  {t('syncMerge.conflictCopy.copyAsNew')}
                </button>
              ) : null}
            </div>
          ))}
          {onCleanup ? (
            <button type="button" onClick={handleCleanupClick} className={styles.cleanupButton}>
              {t('syncMerge.conflictCopy.cleanup')}
            </button>
          ) : null}
        </div>
      ) : null}

      {showCoachmark ? (
        <div role="dialog" aria-modal="true" className={styles.dialogOverlay}>
          <div ref={coachmarkRef} className={styles.dialogCard}>
            <h3 className={styles.dialogTitle}>{t('syncMerge.conflictCopy.coachmark.title')}</h3>
            <p className={styles.dialogBody}>{t('syncMerge.conflictCopy.coachmark.body')}</p>
            <button type="button" onClick={dismissCoachmark} className={styles.dialogButton}>
              {t('syncMerge.confirm.proceed')}
            </button>
          </div>
        </div>
      ) : null}

      {showCleanupConfirm ? (
        <div role="dialog" aria-modal="true" className={styles.dialogOverlay}>
          <div ref={cleanupRef} className={styles.dialogCard}>
            <h3 className={styles.dialogTitle}>{t('syncMerge.conflictCopy.cleanup')}</h3>
            <p className={styles.dialogBody}>{t('syncMerge.conflictCopy.banner')}</p>
            <label className={styles.checkboxRow}>
              <input
                type="checkbox"
                checked={exportBeforeCleanup}
                onChange={(e) => setExportBeforeCleanup(e.target.checked)}
              />
              <span>{t('syncMerge.conflictCopy.copyAsNew')}</span>
            </label>
            <div className={styles.confirmRow}>
              <button type="button" onClick={() => setShowCleanupConfirm(false)} className={styles.cancelButton}>
                {t('syncMerge.confirm.cancel')}
              </button>
              <button type="button" onClick={handleCleanupConfirm} className={styles.dangerButton}>
                {t('syncMerge.conflictCopy.cleanup')}
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </section>
  );
}
