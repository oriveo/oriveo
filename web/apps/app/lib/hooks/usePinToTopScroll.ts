import { useRef, useEffect, useLayoutEffect, useState, useCallback } from 'react';

// Distance-from-bottom threshold for the jump-to-latest marker: more than 80px from the
// bottom counts as "there is more content below" and shows the marker.
// After a pin the answer grows below, and the marker appears once this distance is exceeded.
export const AT_BOTTOM_THRESHOLD_PX = 80;
// Small gap left between the pinned question bubble and the top of the viewport, so it does not sit flush against the edge.
export const PIN_TOP_GAP_PX = 12;

/**
 * Reserved height for pin-to-top, kept as a pure function so the formula can be locked by
 * unit tests.
 *
 * Web form of `inset = max(minPad, anchorTopY + viewportH - contentH)`: scrolling the
 * question bubble (anchorTop) to the top of the viewport requires
 * `scrollHeight >= anchorTop + viewportH`. A short answer does not reach that, so a
 * positive value is returned to create scroll room; a long answer already exceeds the
 * screen, so the result is 0.
 * The spacer always sits below the viewport, and shrinking it can only leave maxScroll
 * equal or larger (the safe direction), so scrollTop is untouched and the top does not jump.
 */
export function computePinReserve(args: {
  anchorTop: number;
  viewportHeight: number;
  naturalContentHeight: number;
}): number {
  const { anchorTop, viewportHeight, naturalContentHeight } = args;
  return Math.max(0, anchorTop + viewportHeight - naturalContentHeight);
}

interface PinToTopArgs {
  /** Current conversation id: on change, reset the spacer and scroll to the bottom once to show the latest */
  conversationId?: string | null;
  /** Pin anchor: the id of the most recent user message */
  anchorMessageId?: string | null;
  /** Id of the assistant message streaming at the tail, null when nothing is streaming; a new id triggers a pin */
  streamingAssistantId?: string | null;
  /** Streaming text: recompute the spacer on change, shrinking only, without touching scrollTop */
  streamingText: string;
  /** Search mode: suppresses the initial scroll to the bottom when switching conversations, so the search positioning logic takes over */
  searchActive?: boolean;
}

/**
 * Pin-to-top scroll controller for the chat list: sending a message adds a new generating
 * assistant at the tail, the question bubble is smoothly moved up and pinned to the top of
 * the viewport, and the answer grows downwards from there. The view does not follow the
 * bottom while streaming; the user scrolls.
 *
 * Returns areaRef (the scroll container), spacerRef (the tail spacer whose height this hook
 * writes), showJumpToLatest (shown once the distance from the bottom passes a threshold)
 * and handleJumpToLatest (scroll to the latest).
 */
export function usePinToTopScroll({
  conversationId,
  anchorMessageId,
  streamingAssistantId,
  streamingText,
  searchActive = false,
}: PinToTopArgs) {
  const areaRef = useRef<HTMLDivElement>(null);
  const spacerRef = useRef<HTMLDivElement>(null);
  // Current spacer height, used to recover the real content height from scrollHeight
  const spacerHeightRef = useRef(0);
  // Assistant id that has already been pinned: only a new id triggers a pin, never the same
  // one twice. Starts as null so the first message of a new conversation, already streaming
  // at mount, still pins.
  const pinnedAssistantIdRef = useRef<string | null>(null);
  // Pinning is active, i.e. the current turn is streaming: decides whether the spacer is recomputed as streamingText grows
  const pinActiveRef = useRef(false);
  const rafRef = useRef<number | null>(null);

  const [showJumpToLatest, setShowJumpToLatest] = useState(false);

  const prefersReducedMotion = () =>
    typeof window !== 'undefined' &&
    window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;

  // Real content height: scrollHeight minus the spacer this hook manages
  const naturalContentHeight = (area: HTMLDivElement) => area.scrollHeight - spacerHeightRef.current;

  const setSpacer = (h: number) => {
    spacerHeightRef.current = h;
    const el = spacerRef.current;
    if (el) el.style.height = `${h}px`;
  };

  // Anchor top in the scroll content coordinate system (getBoundingClientRect is safe across offsetParent)
  const anchorTopIn = (area: HTMLDivElement): number | null => {
    if (!anchorMessageId) return null;
    const anchor = Array.from(area.querySelectorAll<HTMLElement>('[data-message-id]')).find(
      (el) => el.dataset.messageId === anchorMessageId,
    );
    if (!anchor) return null;
    const areaRect = area.getBoundingClientRect();
    const anchorRect = anchor.getBoundingClientRect();
    return anchorRect.top - areaRect.top + area.scrollTop;
  };

  const evaluateJump = (area: HTMLDivElement) => {
    const distance = area.scrollHeight - area.scrollTop - area.clientHeight;
    setShowJumpToLatest(distance > AT_BOTTOM_THRESHOLD_PX);
  };

  // Pin: reserve room, then smoothly move the anchor to the top of the viewport
  const pinToAnchor = useCallback(() => {
    const area = areaRef.current;
    if (!area) return;
    const anchorTop = anchorTopIn(area);
    if (anchorTop == null) return;
    setSpacer(
      computePinReserve({
        anchorTop,
        viewportHeight: area.clientHeight,
        naturalContentHeight: naturalContentHeight(area),
      }),
    );
    // Force a reflow so the new scrollHeight takes effect, otherwise smooth cannot reach the target
    void area.scrollHeight;
    area.scrollTo({
      top: Math.max(0, anchorTop - PIN_TOP_GAP_PX),
      behavior: prefersReducedMotion() ? 'auto' : 'smooth',
    });
    evaluateJump(area);
    // Rebuilt when anchorMessageId changes, since anchorTopIn reads it
  }, [anchorMessageId]);

  // Trigger: a new generating assistant at the tail pins; the end of streaming freezes the spacer and stops recomputation
  useLayoutEffect(() => {
    const current = streamingAssistantId ?? null;
    if (current && current !== pinnedAssistantIdRef.current) {
      pinnedAssistantIdRef.current = current;
      pinActiveRef.current = true;
      pinToAnchor();
    } else if (!current) {
      // A short answer keeps the pin and the space below it; the spacer is not reset, so the answer does not visibly sink
      pinActiveRef.current = false;
    }
  }, [streamingAssistantId, pinToAnchor]);

  // While streaming: recompute the spacer as tokens arrive (rAF throttled, shrink only, scrollTop untouched) and update the jump marker
  useEffect(() => {
    if (!pinActiveRef.current) return;
    if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
    rafRef.current = requestAnimationFrame(() => {
      rafRef.current = null;
      const area = areaRef.current;
      if (!area) return;
      const anchorTop = anchorTopIn(area);
      if (anchorTop != null) {
        setSpacer(
          computePinReserve({
            anchorTop,
            viewportHeight: area.clientHeight,
            naturalContentHeight: naturalContentHeight(area),
          }),
        );
      }
      evaluateJump(area);
    });
    // streamingText drives the recomputation; anchorMessageId is stable and stays out of the deps
  }, [streamingText]);

  // Switching into or between conversations: when not streaming, reset the spacer and
  // scroll to the bottom once to show the latest (search mode takes over positioning and
  // the scroll is not stolen); while streaming, including a new conversation whose first
  // message is already generating, leave it to the pin trigger and touch neither.
  useLayoutEffect(() => {
    const area = areaRef.current;
    if (!area) return;
    if (streamingAssistantId) return;
    setSpacer(0);
    pinActiveRef.current = false;
    pinnedAssistantIdRef.current = null;
    if (!searchActive) {
      area.scrollTop = area.scrollHeight;
    }
    evaluateJump(area);
  }, [conversationId]);

  // Update the jump marker as the user scrolls
  useEffect(() => {
    const area = areaRef.current;
    if (!area) return;
    const onScroll = () => evaluateJump(area);
    area.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
    return () => {
      area.removeEventListener('scroll', onScroll);
      if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
    };
  }, []);

  const handleJumpToLatest = useCallback(() => {
    const area = areaRef.current;
    if (!area) return;
    area.scrollTo({ top: area.scrollHeight, behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
  }, []);

  return { areaRef, spacerRef, showJumpToLatest, handleJumpToLatest };
}
