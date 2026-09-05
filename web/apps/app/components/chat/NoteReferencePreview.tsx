'use client';

import { useEffect, useRef, useState, type RefObject } from 'react';
import { createPortal } from 'react-dom';
import { useDismissOnOutsideClick } from '../../lib/hooks/useDismissOnOutsideClick';
import styles from './NoteReferencePreview.module.css';

interface NoteReferencePreviewProps {
  id?: string;
  title: string;
  bodyPreview?: string;
  sourceLabel?: string;
  dateLabel?: string;
  anchorRect: DOMRect;
  /** Ref to the anchor chip: clicking it does not count as an outside click, so tapping the anchor or a touch toggle does not close the card. */
  anchorRef?: RefObject<HTMLElement | null>;
  onClose: () => void;
  onPointerEnter?: () => void;
  onPointerLeave?: () => void;
}

const GAP = 12;
const MARGIN = 8;

/**
 * Hover preview card for a reference chip. It is portaled to body, because the composer is a
 * narrow bottom-anchored column whose .wrap has pointer-events:none, so an absolutely positioned
 * card in place would be clipped or punched through. It opens above the chip and flips below when
 * there is not enough room.
 *
 * Position is measured once, on open: the chip lives in the fixed bottom composer, so scrolling
 * the message area (including the streaming auto-pin) does not move it. closeOnScroll is
 * deliberately off -- a capture listener fires on inner scrolls and would snap the card shut
 * during streaming. Only a resize, which changes the composer width, closes it as a fallback.
 */
export function NoteReferencePreview({
  id,
  title,
  bodyPreview,
  sourceLabel,
  dateLabel,
  anchorRect,
  anchorRef,
  onClose,
  onPointerEnter,
  onPointerLeave,
}: NoteReferencePreviewProps) {
  const cardRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  useDismissOnOutsideClick(cardRef, {
    onDismiss: onClose,
    closeOnResize: true,
    closeOnEscape: true,
    ignoreRef: anchorRef,
  });

  // Measure the rendered card before positioning: prefer above the chip, flip below when space is short, center horizontally and clamp into the viewport.
  useEffect(() => {
    const card = cardRef.current;
    if (!card) return;
    const rect = card.getBoundingClientRect();
    let top = anchorRect.top - rect.height - GAP;
    if (top < MARGIN) top = anchorRect.bottom + GAP;
    let left = anchorRect.left + anchorRect.width / 2 - rect.width / 2;
    left = Math.max(MARGIN, Math.min(left, window.innerWidth - rect.width - MARGIN));
    // Very small viewports: when neither above nor below fits, clamp into the viewport rather than overflowing the edge.
    top = Math.max(MARGIN, Math.min(top, window.innerHeight - rect.height - MARGIN));
    setPos({ left, top });
  }, [anchorRect]);

  return createPortal(
    <div
      ref={cardRef}
      id={id}
      className={styles.card}
      role="tooltip"
      style={{
        left: pos?.left ?? anchorRect.left,
        top: pos?.top ?? anchorRect.top,
    // Avoid a flash at the wrong position before the measurement lands, then fade in over 4px.
        opacity: pos ? 1 : 0,
        transform: pos ? 'translateY(0)' : 'translateY(4px)',
      }}
      onMouseEnter={onPointerEnter}
      onMouseLeave={onPointerLeave}
    >
      <p className={styles.title}>{title}</p>
      {(sourceLabel || dateLabel) && (
        <div className={styles.meta}>
          {sourceLabel && <span className={styles.sourceChip}>{sourceLabel}</span>}
          {dateLabel && <span className={styles.date}>{dateLabel}</span>}
        </div>
      )}
      {bodyPreview && <p className={styles.body}>{bodyPreview}</p>}
    </div>,
    document.body,
  );
}
