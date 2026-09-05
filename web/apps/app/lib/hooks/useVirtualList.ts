import { useState, useEffect, useRef, useCallback } from 'react';

interface VirtualListOptions {
  totalItems: number;
  itemHeight: number;
  overscan?: number;
}

interface VirtualListResult {
  containerRef: React.RefObject<HTMLDivElement | null>;
  virtualItems: { index: number; offsetTop: number }[];
  totalHeight: number;
}

export function useVirtualList({
  totalItems,
  itemHeight,
  overscan = 5,
}: VirtualListOptions): VirtualListResult {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [scrollTop, setScrollTop] = useState(0);
  const [containerHeight, setContainerHeight] = useState(0);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setContainerHeight(entry.contentRect.height);
      }
    });
    observer.observe(el);

    const handleScroll = () => {
      setScrollTop(el.scrollTop);
    };
    el.addEventListener('scroll', handleScroll, { passive: true });

    return () => {
      observer.disconnect();
      el.removeEventListener('scroll', handleScroll);
    };
  }, []);

  const getVirtualItems = useCallback(() => {
    if (containerHeight === 0 || totalItems === 0) {
      return [];
    }

    const startIndex = Math.max(0, Math.floor(scrollTop / itemHeight) - overscan);
    const endIndex = Math.min(
      totalItems - 1,
      Math.ceil((scrollTop + containerHeight) / itemHeight) + overscan,
    );

    const items: { index: number; offsetTop: number }[] = [];
    for (let i = startIndex; i <= endIndex; i++) {
      items.push({ index: i, offsetTop: i * itemHeight });
    }
    return items;
  }, [scrollTop, containerHeight, totalItems, itemHeight, overscan]);

  return {
    containerRef,
    virtualItems: getVirtualItems(),
    totalHeight: totalItems * itemHeight,
  };
}
