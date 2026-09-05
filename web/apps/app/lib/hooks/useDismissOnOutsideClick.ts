import { useEffect, type RefObject } from 'react';

interface UseDismissOptions {
  onDismiss: () => void;
  /** Close on scroll, listening in the capture phase. Used by ContextMenu. */
  closeOnScroll?: boolean;
  /** Close on window resize. Used by ContextMenu. */
  closeOnResize?: boolean;
  /** Close on Escape. Used by MoveToFolderMenu. */
  closeOnEscape?: boolean;
  /**
   * A click inside this element does not count as "outside" (the anchor button of a popover, for
   * instance), so clicking the anchor does not close it.
   */
  ignoreRef?: RefObject<HTMLElement | null>;
}

/**
 * Closes on a mousedown outside the container, optionally also on scroll, resize or Escape.
 * Shared by ContextMenu, MoveToFolderMenu and NoteReferencePreview, which pick the event
 * combination through options.
 */
export function useDismissOnOutsideClick<T extends HTMLElement>(
  ref: RefObject<T | null>,
  { onDismiss, closeOnScroll, closeOnResize, closeOnEscape, ignoreRef }: UseDismissOptions,
) {
  useEffect(() => {
    const handleClick = (e: MouseEvent) => {
      const target = e.target as Node;
      if (ref.current && !ref.current.contains(target) && !ignoreRef?.current?.contains(target)) {
        onDismiss();
      }
    };
    const handleClose = () => onDismiss();
    const handleKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onDismiss();
    };

    document.addEventListener('mousedown', handleClick);
    if (closeOnScroll) document.addEventListener('scroll', handleClose, true);
    if (closeOnResize) window.addEventListener('resize', handleClose);
    if (closeOnEscape) document.addEventListener('keydown', handleKey);

    return () => {
      document.removeEventListener('mousedown', handleClick);
      if (closeOnScroll) document.removeEventListener('scroll', handleClose, true);
      if (closeOnResize) window.removeEventListener('resize', handleClose);
      if (closeOnEscape) document.removeEventListener('keydown', handleKey);
    };
  }, [ref, onDismiss, closeOnScroll, closeOnResize, closeOnEscape, ignoreRef]);
}
