'use client';

import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type KeyboardEvent as ReactKeyboardEvent,
} from 'react';
import { useTranslations } from 'next-intl';
import type { ChatMessage } from '@oriveo/shared';
import {
  OUTLINE_MIN_USER_TURNS,
  clampPreview,
  deriveOutlineTicks,
  outlineVisibleRange,
  previewCharLimit,
  resolveOutlineActiveIndex,
  tooltipMaxWidth,
  type OutlineRange,
} from './chat-outline-utils';
import styles from './ChatOutlineRail.module.css';

export { OUTLINE_MIN_USER_TURNS };

/** Gap left between the pinned message and the viewport top after a jump, matching search jumps. */
const PIN_TOP_GAP_PX = 16;
/** Delay before the rail collapses again. */
const RAIL_COLLAPSE_DELAY_MS = 600;
/** Tap threshold: pointer movement below this counts as a tap rather than a drag. */
const TAP_MOVE_THRESHOLD_PX = 8;
/** Sub-pixel layout tolerance, used only when deciding whether a real scroll edge was reached. */
const SCROLL_EDGE_EPSILON_PX = 1;

type Shape = 'bar' | 'dot';

/** Tick geometry per shape, in px. */
const GEOM: Record<Shape, {
  dimW: number; dimH: number;
  curW: number; curH: number;
  hovW: number; hovH: number;
  rowH: number;
}> = {
  bar: { dimW: 16, dimH: 2, curW: 22, curH: 2.5, hovW: 18, hovH: 2, rowH: 14 },
  dot: { dimW: 5, dimH: 5, curW: 7, curH: 7, hovW: 6, hovH: 6, rowH: 12 },
};

interface ChatOutlineRailProps {
  messages: ChatMessage[];
  areaRef: React.RefObject<HTMLDivElement | null>;
  conversationId?: string | null;
}

export function ChatOutlineRail({ messages, areaRef, conversationId }: ChatOutlineRailProps) {
  const t = useTranslations('pages.chat');
  const attachmentLabel = t('outlineAttachmentOnly');

  const ticks = useMemo(
    () => deriveOutlineTicks(messages, attachmentLabel),
    [messages, attachmentLabel],
  );
  const tickIndexById = useMemo(
    () => new Map(ticks.map((tick, index) => [tick.id, index])),
    [ticks],
  );

  const [shapeWide, setShapeWide] = useState(true);
  const [vw, setVw] = useState(1024);
  const [areaHeight, setAreaHeight] = useState(0);
  const [currentId, setCurrentId] = useState<string | null>(ticks[0]?.id ?? null);
  const [active, setActive] = useState(false);
  const [pointedIndex, setPointedIndex] = useState<number | null>(null);
  // Sliding window frozen during interaction: a scrubbing jump changes currentId, which slides the
  // window, which morphs the tick under the pointer and makes the feedback loop jump around. Freeze
  // on press or hover, unfreeze after collapse so it follows again.
  const [frozenRange, setFrozenRange] = useState<OutlineRange | null>(null);

  const railRef = useRef<HTMLElement | null>(null);
  // DOM anchors are rebuilt only when the set of user turns changes; scroll frames binary-search instead of scanning every message.
  const userNodesRef = useRef<HTMLElement[]>([]);
  const collapseTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pointerStart = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  // Scrubbing flag: set once the pointer moves past the threshold, driving the "pointed tick changes -> list follows live" effect.
  const draggingRef = useRef(false);

  const shape: Shape = shapeWide ? 'bar' : 'dot';
  const geom = GEOM[shape];

  // Row height is constant and never compressed: scaling rows down to a minimum gap still overflowed
  // at a few hundred turns and read far too dense. Overflow is handled by the sliding window instead.
  const rowH = geom.rowH;
  // Capacity = 62% of the viewport height divided by row height. The 62% cap keeps the vertically
  // centred rail clear of the back-to-bottom button in the corner, avoiding mis-taps. areaHeight is
  // unmeasured (0) on the first frame, so everything is shown until it is known, otherwise the rail
  // flashes with a single dot.
  const capacity = areaHeight > 48
    ? Math.max(1, Math.floor((areaHeight * 0.62) / rowH))
    : Number.MAX_SAFE_INTEGER;
  const currentIndex = currentId ? (tickIndexById.get(currentId) ?? -1) : -1;
  // Sliding window: past capacity the window centres on the current turn and slides with scrolling,
  // and during interaction the frozen window is used instead. The clamp keeps a frozen window in
  // range when ticks shrink, for example on a conversation switch.
  const liveRange = outlineVisibleRange(ticks.length, currentIndex, capacity);
  const rawRange = frozenRange ?? liveRange;
  const range: OutlineRange = {
    start: Math.min(rawRange.start, Math.max(0, ticks.length - 1)),
    end: Math.min(rawRange.end, ticks.length),
  };
  const windowTicks = useMemo(
    () => ticks.slice(range.start, range.end),
    [ticks, range.start, range.end],
  );
  const topFaded = range.start > 0;
  const bottomFaded = range.end < ticks.length;

  // Drop the frozen window whenever ticks are replaced wholesale, such as on a conversation switch:
  // an index-based window would otherwise point at shifted content.
  useEffect(() => {
    setFrozenRange(null);
  }, [ticks.length]);

  // -- Viewport size and shape breakpoint: dot below 768, bar at 768 and above --
  useEffect(() => {
    const update = () => {
      const w = window.innerWidth;
      setVw(w);
      setShapeWide(w >= 768);
    };
    update();
    window.addEventListener('resize', update);
    return () => window.removeEventListener('resize', update);
  }, []);

  // -- Current visible turn: scroll plus rAF throttling, with the activation line at the top third of the viewport --
  const recompute = useCallback(() => {
    const area = areaRef.current;
    if (!area || ticks.length === 0) return;
    const areaRect = area.getBoundingClientRect();
    setAreaHeight(areaRect.height);
    const activationY = areaRect.top + areaRect.height * 0.33;
    const nodes = userNodesRef.current;
    let low = 0;
    let high = nodes.length - 1;
    let focusIndex = 0;
    while (low <= high) {
      const mid = (low + high) >> 1;
      if (nodes[mid].getBoundingClientRect().top <= activationY) {
        focusIndex = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    const maxScrollTop = Math.max(0, area.scrollHeight - area.clientHeight);
    const atStart = area.scrollTop <= SCROLL_EDGE_EPSILON_PX;
    const atEnd = maxScrollTop - area.scrollTop <= SCROLL_EDGE_EPSILON_PX;
    const activeIndex = resolveOutlineActiveIndex(ticks.length, focusIndex, atStart, atEnd);
    const next = ticks[activeIndex]?.id;
    if (!next) return;
    setCurrentId((prev) => (prev === next ? prev : next));
  }, [areaRef, ticks]);

  useLayoutEffect(() => {
    const area = areaRef.current;
    if (!area) return;
    const nodesById = new Map<string, HTMLElement>();
    for (const node of area.querySelectorAll<HTMLElement>('[data-message-id]')) {
      const id = node.dataset.messageId;
      if (id) nodesById.set(id, node);
    }
    userNodesRef.current = ticks.flatMap((tick) => {
      const node = nodesById.get(tick.id);
      return node ? [node] : [];
    });
    recompute();
  }, [areaRef, conversationId, ticks, recompute]);

  useEffect(() => {
    const area = areaRef.current;
    if (!area) return;
    let raf = 0;
    const onScroll = () => {
      if (raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        recompute();
      });
    };
    recompute();
    area.addEventListener('scroll', onScroll, { passive: true });
    const ro = new ResizeObserver(onScroll);
    ro.observe(area);
    return () => {
      area.removeEventListener('scroll', onScroll);
      ro.disconnect();
      if (raf) cancelAnimationFrame(raf);
    };
  }, [areaRef, recompute, conversationId]);

  // If the current tick becomes invalid after a conversation or message change, fall back to the first item.
  useEffect(() => {
    if (currentId && tickIndexById.has(currentId)) return;
    setCurrentId(ticks[0]?.id ?? null);
  }, [ticks, tickIndexById, currentId]);

  const cancelCollapse = useCallback(() => {
    if (collapseTimer.current) {
      clearTimeout(collapseTimer.current);
      collapseTimer.current = null;
    }
  }, []);

  const scheduleCollapse = useCallback(() => {
    cancelCollapse();
    collapseTimer.current = setTimeout(() => {
      setActive(false);
      setPointedIndex(null);
      // Interaction ended: unfreeze the sliding window and follow the current turn again.
      setFrozenRange(null);
    }, RAIL_COLLAPSE_DELAY_MS);
  }, [cancelCollapse]);

  useEffect(() => () => cancelCollapse(), [cancelCollapse]);

  // -- Jump: place the target user message at the viewport top with a 12px gap, smoothly unless reduced motion is on --
  const jumpTo = useCallback(
    (id: string, instant = false) => {
      const area = areaRef.current;
      if (!area) return;
      const selectorId = typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(id) : id;
      const el = area.querySelector<HTMLElement>(`[data-message-id="${selectorId}"]`);
      if (!el) return;
      const top = el.getBoundingClientRect().top - area.getBoundingClientRect().top + area.scrollTop;
      const target = Math.max(0, top - PIN_TOP_GAP_PX);
      const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      // Live scrubbing jumps instantly so it stays under the finger instead of queueing smooth animations; a single tap scrolls smoothly, as web anchors do.
      area.scrollTo({ top: target, behavior: instant || reduce ? 'auto' : 'smooth' });
      setCurrentId(id);
      // The light tick pulse for crossing a tick while scrubbing is handled by the effect below; this is only the confirm buzz on tap.
      if (!instant && typeof navigator !== 'undefined' && 'vibrate' in navigator) {
        try {
          navigator.vibrate(15);
        } catch {
          /* noop */
        }
      }
    },
    [areaRef],
  );

  // Scrubbing: while dragging, the main list scrolls instantly to the pointed tick and a light tick buzz fires on phones.
  useEffect(() => {
    if (!draggingRef.current || pointedIndex == null) return;
    const tick = windowTicks[pointedIndex];
    if (!tick) return;
    jumpTo(tick.id, true);
    if (typeof navigator !== 'undefined' && 'vibrate' in navigator) {
      try {
        navigator.vibrate(5);
      } catch {
        /* noop */
      }
    }
  }, [pointedIndex, windowTicks, jumpTo]);

  const indexFromClientY = useCallback(
    (clientY: number): number | null => {
      const rail = railRef.current;
      if (!rail || windowTicks.length === 0) return null;
      const rect = rail.getBoundingClientRect();
      const rel = clientY - rect.top - 8; // 8 = rail padding-top
      const idx = Math.floor(rel / rowH);
      return Math.max(0, Math.min(windowTicks.length - 1, idx));
    },
    [windowTicks.length, rowH],
  );

  const handlePointerEnter = useCallback((e: ReactPointerEvent) => {
    if (e.pointerType === 'mouse') {
      cancelCollapse();
      // Freeze the window on hover so wheel scrolling that changes currentId does not morph the tick under the cursor.
      setFrozenRange((prev) => prev ?? range);
      setActive(true);
    }
  }, [cancelCollapse, range]);

  const handlePointerLeave = useCallback((e: ReactPointerEvent) => {
    if (e.pointerType === 'mouse') {
      draggingRef.current = false;
      scheduleCollapse();
    }
  }, [scheduleCollapse]);

  const handlePointerDown = useCallback(
    (e: ReactPointerEvent) => {
      cancelCollapse();
      // Freeze the window on press so a scrubbing jump that changes currentId does not morph the tick under the pointer.
      setFrozenRange((prev) => prev ?? range);
      setActive(true);
      pointerStart.current = { x: e.clientX, y: e.clientY, moved: false };
      draggingRef.current = false;
      const idx = indexFromClientY(e.clientY);
      setPointedIndex(idx);
      if (e.pointerType !== 'mouse') {
        (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId);
      }
    },
    [cancelCollapse, indexFromClientY, range],
  );

  const handlePointerMove = useCallback(
    (e: ReactPointerEvent) => {
      if (e.pointerType === 'mouse' && !active) return;
      const start = pointerStart.current;
      if (start) {
        if (Math.abs(e.clientX - start.x) > TAP_MOVE_THRESHOLD_PX || Math.abs(e.clientY - start.y) > TAP_MOVE_THRESHOLD_PX) {
          start.moved = true;
          draggingRef.current = true;
        }
      }
      const idx = indexFromClientY(e.clientY);
      setPointedIndex(idx);
    },
    [active, indexFromClientY],
  );

  const handlePointerUp = useCallback(
    (e: ReactPointerEvent) => {
      const start = pointerStart.current;
      pointerStart.current = null;
      draggingRef.current = false;
      const idx = indexFromClientY(e.clientY);
      // Tap (little movement) -> smooth jump; a scrubbing drag has already followed live, so only collapse.
      if (idx != null && (!start || !start.moved) && windowTicks[idx]) {
        jumpTo(windowTicks[idx].id);
      }
      if (e.pointerType !== 'mouse') {
        scheduleCollapse();
      }
    },
    [indexFromClientY, jumpTo, windowTicks, scheduleCollapse],
  );

  const handleKeyDown = useCallback(
    (e: ReactKeyboardEvent, index: number) => {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        const nextIdx = e.key === 'ArrowDown'
          ? Math.min(windowTicks.length - 1, index + 1)
          : Math.max(0, index - 1);
        const rail = railRef.current;
        const btn = rail?.querySelectorAll<HTMLButtonElement>('[data-outline-tick]')[nextIdx];
        cancelCollapse();
        setActive(true);
        setPointedIndex(nextIdx);
        btn?.focus();
      } else if (e.key === 'Escape') {
        setActive(false);
        setPointedIndex(null);
        (e.currentTarget as HTMLElement).blur();
      }
    },
    [windowTicks.length, cancelCollapse],
  );

  if (ticks.length <= OUTLINE_MIN_USER_TURNS) return null;

  // When the window is not at the very start or end, edge ticks fade in steps to hint that there is
  // more above or below. A CSS mask is not used: masking the nav would fade the embedded tooltip
  // along with it, and since ticks are discrete, two opacity steps look like a continuous gradient.
  // The active and pointed ticks are exempt, otherwise an active tick landing in the faded edge
  // after paging looks dimmed and reads as not active.
  const fadeOpacity = (index: number, exempt: boolean): number | undefined => {
    if (exempt) return undefined;
    if (topFaded && index < 2) return index === 0 ? 0.15 : 0.55;
    if (bottomFaded && index >= windowTicks.length - 2) {
      return index === windowTicks.length - 1 ? 0.15 : 0.55;
    }
    return undefined;
  };

  const tickStyle = (tick: { id: string }, index: number): CSSProperties => {
    const isCurrent = tick.id === currentId;
    const isPointed = index === pointedIndex;
    let w = geom.dimW;
    let h = geom.dimH;
    let background = 'color-mix(in srgb, var(--o-text-tertiary) 55%, transparent)';
    if (active && !isCurrent && !isPointed) {
      w = geom.hovW;
      h = geom.hovH;
      background = 'var(--o-text-secondary)';
    }
    if (isCurrent || isPointed) {
      w = geom.curW;
      h = geom.curH;
      background = 'var(--o-primary)';
    }
    return { width: w, height: h, background, opacity: fadeOpacity(index, isCurrent || isPointed) };
  };

  const maxChars = previewCharLimit(vw);

  return (
    <div className={styles.wrap}>
      <nav
        ref={railRef}
        className={styles.rail}
        data-shape={shape}
        data-active={active ? 'true' : 'false'}
        aria-label={t('outlineNavLabel')}
        onPointerEnter={handlePointerEnter}
        onPointerLeave={handlePointerLeave}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
      >
        {windowTicks.map((tick, index) => (
          <button
            key={tick.id}
            type="button"
            data-outline-tick
            className={styles.tickRow}
            style={{ height: rowH }}
            aria-label={t('outlineJumpTo', { preview: tick.preview })}
            aria-current={tick.id === currentId ? 'true' : undefined}
            onClick={() => jumpTo(tick.id)}
            onKeyDown={(e) => handleKeyDown(e, index)}
            onFocus={() => {
              cancelCollapse();
              setActive(true);
              setPointedIndex(index);
            }}
          >
            <span className={styles.tick} style={tickStyle(tick, index)} />
            {/* The tooltip is nested inside the button and absolutely positioned so it aligns with the tick without computing top by hand, and expands leftwards so it is not clipped */}
            {active && index === pointedIndex && (
              <span className={styles.tooltip} style={{ maxWidth: tooltipMaxWidth(vw) }} role="presentation">
                {clampPreview(tick.preview, maxChars)}
              </span>
            )}
          </button>
        ))}
      </nav>
    </div>
  );
}
