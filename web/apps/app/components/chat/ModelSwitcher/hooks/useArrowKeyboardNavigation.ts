import { useCallback, type RefObject } from "react";
import type { SwitcherView } from "../presentation-mode";

interface UseArrowKeyboardNavigationParams {
  view: SwitcherView;
  listRef: RefObject<HTMLDivElement | null>;
  onClose: () => void;
  setView: (next: SwitcherView) => void;
}

/**
 * Top-level keyboard navigation for ModelSwitcher.
 * - Esc: closes the browse view, and returns a sub view to browse
 * - ArrowUp / ArrowDown / Home / End: moves focus between modelRow entries in the browse view
 */
export function useArrowKeyboardNavigation({
  view,
  listRef,
  onClose,
  setView,
}: UseArrowKeyboardNavigationParams) {
  // useCallback keeps the handler reference stable; returning a new function every render is a use* anti-pattern.
  return useCallback(function handleKeyDown(event: React.KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      if (view.kind === "browse") {
        onClose();
        return;
      }
      setView({ kind: "browse" });
      return;
    }

    if (view.kind !== "browse") return;
    if (
      event.key !== "ArrowDown" &&
      event.key !== "ArrowUp" &&
      event.key !== "Home" &&
      event.key !== "End"
    ) {
      return;
    }

    const list = listRef.current;
    if (!list) return;
    const rows = Array.from(
      list.querySelectorAll<HTMLButtonElement>(
        'button[data-model-row="true"]:not([disabled])',
      ),
    );
    if (rows.length === 0) return;

    const active = document.activeElement as HTMLElement | null;
    const currentIndex = active ? rows.indexOf(active as HTMLButtonElement) : -1;
    let nextIndex = currentIndex;
    if (event.key === "ArrowDown") {
      nextIndex = currentIndex < 0 ? 0 : Math.min(rows.length - 1, currentIndex + 1);
    } else if (event.key === "ArrowUp") {
      nextIndex = currentIndex < 0 ? rows.length - 1 : Math.max(0, currentIndex - 1);
    } else if (event.key === "Home") {
      nextIndex = 0;
    } else if (event.key === "End") {
      nextIndex = rows.length - 1;
    }

    if (nextIndex !== currentIndex && rows[nextIndex]) {
      event.preventDefault();
      rows[nextIndex].focus();
      rows[nextIndex].scrollIntoView({ block: "nearest" });
    }
  }, [view, listRef, onClose, setView]);
}
