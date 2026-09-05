'use client';

import { useEffect, useCallback, useRef, useState, type AnimationEvent, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import styles from './Dialog.module.css';

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'textarea:not([disabled])',
  'select:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
].join(', ');

let bodyScrollLockCount = 0;
let bodyOverflowBeforeLock = '';

function acquireBodyScrollLock() {
  if (bodyScrollLockCount === 0) {
    bodyOverflowBeforeLock = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
  }
  bodyScrollLockCount += 1;
}

function releaseBodyScrollLock() {
  bodyScrollLockCount = Math.max(0, bodyScrollLockCount - 1);
  if (bodyScrollLockCount === 0) {
    document.body.style.overflow = bodyOverflowBeforeLock;
    bodyOverflowBeforeLock = '';
  }
}

interface DialogProps {
  open: boolean;
  onClose?: () => void;
  dismissible?: boolean;
  /** Width - md (default 440px) / lg (560px) / xl (920px). */
  size?: 'md' | 'lg' | 'xl';
  /** false removes the shell padding and hands it entirely to the caller. Defaults to true. Affects padding only. */
  padded?: boolean;
  /**
   * false removes the shell's own surface (background / border / shadow) so the caller draws the
   * whole shell itself. Orthogonal to padded: padded governs inner spacing, surface governs the
   * "this is a floating layer" visuals. Only turn it off when the caller already draws a complete
   * opaque panel, otherwise the content sits directly on the overlay.
   */
  surface?: boolean;
  overlayClassName?: string;
  className?: string;
  ariaLabelledBy?: string;
  /** Exit animation duration; when greater than 0 the closed state stays mounted until the animation finishes. */
  exitDurationMs?: number;
  /** Called after the exit animation completes and the DOM is unmounted. */
  onExited?: () => void;
  /** On open, focus the matching element inside the Dialog first; falls back to the first focusable element. */
  initialFocusSelector?: string;
  /** Locks body scroll while open; nested Dialogs are counted, and scrolling is restored once the exit animation completes. */
  lockBodyScroll?: boolean;
  children: ReactNode;
}

export function Dialog({
  open,
  onClose,
  dismissible = true,
  size = 'md',
  padded = true,
  surface = true,
  overlayClassName,
  className,
  ariaLabelledBy,
  exitDurationMs = 0,
  onExited,
  initialFocusSelector,
  lockBodyScroll = false,
  children,
}: DialogProps) {
  const dialogRef = useRef<HTMLDivElement>(null);
  const previousFocusRef = useRef<HTMLElement | null>(null);
  const onCloseRef = useRef(onClose);
  const onExitedRef = useRef(onExited);
  const openRef = useRef(open);
  const dismissibleRef = useRef(dismissible);
  const initialFocusSelectorRef = useRef(initialFocusSelector);
  const exitTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const exitPendingRef = useRef(false);
  const [rendered, setRendered] = useState(open);
  const [portalTarget, setPortalTarget] = useState<HTMLElement | null>(null);

  useEffect(() => {
    openRef.current = open;
    onCloseRef.current = onClose;
    onExitedRef.current = onExited;
    dismissibleRef.current = dismissible;
    initialFocusSelectorRef.current = initialFocusSelector;
  }, [dismissible, initialFocusSelector, onClose, onExited, open]);

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (e.key === 'Escape' && dismissibleRef.current && onCloseRef.current) {
        e.preventDefault();
        e.stopPropagation();
        onCloseRef.current();
        return;
      }

      // Focus trap: Tab/Shift+Tab cycle within dialog
      if (e.key === 'Tab' && dialogRef.current) {
        const focusables = dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR);
        if (focusables.length === 0) {
          e.preventDefault();
          dialogRef.current.focus();
          return;
        }

        const first = focusables[0];
        const last = focusables[focusables.length - 1];
        if (!dialogRef.current.contains(document.activeElement)) {
          e.preventDefault();
          (e.shiftKey ? last : first).focus();
          return;
        }

        if (e.shiftKey) {
          if (document.activeElement === first) {
            e.preventDefault();
            last.focus();
          }
        } else {
          if (document.activeElement === last) {
            e.preventDefault();
            first.focus();
          }
        }
      }
    },
    [],
  );

  const finishExit = useCallback(() => {
    if (!exitPendingRef.current) return;
    exitPendingRef.current = false;
    if (exitTimerRef.current) {
      clearTimeout(exitTimerRef.current);
      exitTimerRef.current = null;
    }
    setRendered(false);
    onExitedRef.current?.();
  }, []);

  useEffect(() => {
    if (open) {
      exitPendingRef.current = false;
      if (exitTimerRef.current) {
        clearTimeout(exitTimerRef.current);
        exitTimerRef.current = null;
      }
      setRendered(true);
      return;
    }

    if (!rendered) return;

    const reducedMotion = typeof window !== 'undefined'
      && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
    if (exitDurationMs <= 0 || reducedMotion) {
      exitPendingRef.current = true;
      finishExit();
      return;
    }

    exitPendingRef.current = true;
    exitTimerRef.current = setTimeout(finishExit, exitDurationMs + 80);
    return () => {
      if (exitTimerRef.current) {
        clearTimeout(exitTimerRef.current);
        exitTimerRef.current = null;
      }
    };
  }, [exitDurationMs, finishExit, open, rendered]);

  useEffect(() => () => {
    if (exitTimerRef.current) clearTimeout(exitTimerRef.current);
  }, []);

  useEffect(() => {
    const shell = dialogRef.current;
    if (!shell) return;
    const handleAnimationEnd = (event: globalThis.AnimationEvent) => {
      if (openRef.current || event.target !== shell) return;
      // React 19.2 may deliver the native event before the passive exit
      // effect marks the transition pending. The shell has visibly finished,
      // so the event itself owns completion.
      exitPendingRef.current = true;
      finishExit();
    };
    shell.addEventListener('animationend', handleAnimationEnd);
    return () => shell.removeEventListener('animationend', handleAnimationEnd);
  }, [finishExit, portalTarget, rendered]);

  useEffect(() => {
    if (!rendered || !lockBodyScroll || typeof document === 'undefined') return;
    acquireBodyScrollLock();
    return releaseBodyScrollLock;
  }, [lockBodyScroll, rendered]);

  useEffect(() => {
    if (open && portalTarget && rendered) {
      previousFocusRef.current = document.activeElement as HTMLElement;
      document.addEventListener('keydown', handleKeyDown);

      // Auto-focus first focusable element
      requestAnimationFrame(() => {
        if (dialogRef.current) {
          const preferred = initialFocusSelectorRef.current
            ? dialogRef.current.querySelector<HTMLElement>(initialFocusSelectorRef.current)
            : null;
          if (preferred) {
            preferred.focus();
            return;
          }
          const focusables = dialogRef.current.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR);
          if (focusables.length > 0) {
            focusables[0].focus();
          } else {
            dialogRef.current.focus();
          }
        }
      });

      return () => {
        document.removeEventListener('keydown', handleKeyDown);
        if (previousFocusRef.current?.isConnected) previousFocusRef.current.focus();
      };
    }
  }, [open, handleKeyDown, portalTarget, rendered]);

  // Portal target = document.body: some ancestors inside AppShell create a containing block
  // (transform / filter / backdrop-filter and friends), so `position: fixed` on .overlay is no longer
  // relative to the viewport and the dialog ends up misplaced or clipped horizontally. Mounting under
  // body keeps the full-screen overlay centred.
  useEffect(() => {
    setPortalTarget(typeof document !== 'undefined' ? document.body : null);
  }, []);

  if (!rendered || !portalTarget) return null;

  const state = open ? 'open' : 'closed';
  return createPortal(
    <div
      className={[styles.overlay, overlayClassName].filter(Boolean).join(' ')}
      data-state={state}
      onClick={open && dismissible && onClose ? onClose : undefined}
      role="dialog"
      aria-modal="true"
      aria-labelledby={ariaLabelledBy}
      aria-hidden={open ? undefined : true}
    >
      <div
        ref={dialogRef}
        data-state={state}
        tabIndex={-1}
        className={[
          styles.dialog,
          size === 'lg' ? styles.dialogLg : undefined,
          size === 'xl' ? styles.dialogXl : undefined,
          padded ? undefined : styles.dialogFlush,
          surface ? undefined : styles.dialogSurfaceless,
          className,
        ]
          .filter(Boolean)
          .join(' ')}
        onClick={(e) => e.stopPropagation()}
      >
        {children}
      </div>
    </div>,
    portalTarget,
  );
}
