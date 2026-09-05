'use client';

import { useEffect, useRef, useCallback, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { useDismissOnOutsideClick } from '../lib/hooks/useDismissOnOutsideClick';
import styles from './ContextMenu.module.css';

export interface ContextMenuItem {
  label: string;
  icon?: ReactNode;
  danger?: boolean;
  onAction: () => void;
}

interface ContextMenuProps {
  items: ContextMenuItem[];
  position: { x: number; y: number };
  onClose: () => void;
}

export function ContextMenu({ items, position, onClose }: ContextMenuProps) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [activeIndex, setActiveIndex] = useState(-1);
  const [pos, setPos] = useState(position);

  // Boundary detection: flip if near edge
  useEffect(() => {
    const menu = menuRef.current;
    if (!menu) return;

    const rect = menu.getBoundingClientRect();
    let x = position.x;
    let y = position.y;

    if (x + rect.width > window.innerWidth - 8) {
      x = position.x - rect.width;
    }
    if (y + rect.height > window.innerHeight - 8) {
      y = position.y - rect.height;
    }

    setPos({ x: Math.max(8, x), y: Math.max(8, y) });
  }, [position]);

  // Close on click outside, scroll, or resize
  useDismissOnOutsideClick(menuRef, { onDismiss: onClose, closeOnScroll: true, closeOnResize: true });

  const handleKeyDown = useCallback(
    (e: React.KeyboardEvent) => {
      switch (e.key) {
        case 'ArrowDown':
          e.preventDefault();
          setActiveIndex((i) => (i + 1) % items.length);
          break;
        case 'ArrowUp':
          e.preventDefault();
          setActiveIndex((i) => (i - 1 + items.length) % items.length);
          break;
        case 'Enter':
          e.preventDefault();
          if (activeIndex >= 0) {
            items[activeIndex].onAction();
            onClose();
          }
          break;
        case 'Escape':
          e.preventDefault();
          onClose();
          break;
      }
    },
    [items, activeIndex, onClose],
  );

  // Auto-focus
  useEffect(() => {
    menuRef.current?.focus();
  }, []);

  return createPortal(
    <div
      ref={menuRef}
      className={styles.menu}
      style={{ left: pos.x, top: pos.y }}
      role="menu"
      tabIndex={-1}
      onKeyDown={handleKeyDown}
    >
      {items.map((item, i) => (
        <button
          key={i}
          className={`${styles.menuItem} ${item.danger ? styles.danger : ''}`}
          role="menuitem"
          data-active={i === activeIndex}
          onClick={() => { item.onAction(); onClose(); }}
          onMouseEnter={() => setActiveIndex(i)}
        >
          {item.icon && <span className={styles.icon}>{item.icon}</span>}
          <span>{item.label}</span>
        </button>
      ))}
    </div>,
    document.body,
  );
}

/** Only enable context menus on fine-pointer devices (not touch) */
export function useContextMenu() {
  const [menu, setMenu] = useState<{ items: ContextMenuItem[]; position: { x: number; y: number } } | null>(null);

  const handleContextMenu = useCallback(
    (e: React.MouseEvent, items: ContextMenuItem[]) => {
      // Skip on touch devices
      if (!window.matchMedia('(pointer: fine)').matches) return;
      e.preventDefault();
      setMenu({ items, position: { x: e.clientX, y: e.clientY } });
    },
    [],
  );

  // Open the menu at given coordinates without an event object, for cases such as a menu button opened by a click
  const openMenu = useCallback(
    (position: { x: number; y: number }, items: ContextMenuItem[]) => {
      // Skip on touch devices
      if (!window.matchMedia('(pointer: fine)').matches) return;
      setMenu({ items, position });
    },
    [],
  );

  const closeMenu = useCallback(() => setMenu(null), []);

  return { menu, handleContextMenu, openMenu, closeMenu };
}
