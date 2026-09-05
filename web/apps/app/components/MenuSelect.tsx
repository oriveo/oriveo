'use client';

import { useEffect, useId, useRef, useState, type CSSProperties } from 'react';
import { Check, ChevronDown } from 'lucide-react';
import styles from './MenuSelect.module.css';

export interface MenuSelectOption<T extends string> {
  value: T;
  label: string;
  description?: string;
}

interface MenuSelectProps<T extends string> {
  value: T;
  options: MenuSelectOption<T>[];
  onChange: (value: T) => void;
  ariaLabel: string;
  className?: string;
  minWidth?: number | string;
  menuMinWidth?: number | string;
  align?: 'start' | 'end';
  size?: 'sm' | 'md';
  showSelectedDescription?: boolean;
}

function toCssDimension(value: number | string | undefined): string | undefined {
  if (value == null) {
    return undefined;
  }

  return typeof value === 'number' ? `${value}px` : value;
}

export function MenuSelect<T extends string>({
  value,
  options,
  onChange,
  ariaLabel,
  className,
  minWidth = 140,
  menuMinWidth,
  align = 'end',
  size = 'sm',
  showSelectedDescription = false,
}: MenuSelectProps<T>) {
  const [isOpen, setIsOpen] = useState(false);
  const [activeIndex, setActiveIndex] = useState(0);
  const rootRef = useRef<HTMLDivElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const ignoreInitialScrollRef = useRef(false);
  const triggerId = useId();

  if (options.length === 0) {
    return null;
  }

  const selectedIndex = Math.max(0, options.findIndex((option) => option.value === value));
  const selectedOption = options[selectedIndex] ?? options[0];

  const closeMenu = (restoreFocus = false) => {
    setIsOpen(false);

    if (restoreFocus) {
      requestAnimationFrame(() => {
        triggerRef.current?.focus();
      });
    }
  };

  useEffect(() => {
    if (!isOpen) {
      return;
    }

    setActiveIndex(selectedIndex);
  }, [isOpen, selectedIndex]);

  useEffect(() => {
    if (!isOpen) {
      return;
    }

    ignoreInitialScrollRef.current = true;
    menuRef.current?.focus({ preventScroll: true });

    const scrollGuardFrame = window.requestAnimationFrame(() => {
      ignoreInitialScrollRef.current = false;
    });

    const handlePointerDown = (event: PointerEvent) => {
      if (rootRef.current?.contains(event.target as Node)) {
        return;
      }
      closeMenu();
    };

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        closeMenu(true);
      }
    };

    const handleClose = () => closeMenu();
    const handleScroll = (event: Event) => {
      if (ignoreInitialScrollRef.current) {
        return;
      }
      // Scrolling inside the menu itself (a long list) must not close it; only an outer container scrolling does
      if (menuRef.current?.contains(event.target as Node)) {
        return;
      }
      closeMenu();
    };

    document.addEventListener('pointerdown', handlePointerDown);
    document.addEventListener('keydown', handleKeyDown);
    window.addEventListener('resize', handleClose);
    document.addEventListener('scroll', handleScroll, true);

    return () => {
      window.cancelAnimationFrame(scrollGuardFrame);
      ignoreInitialScrollRef.current = false;
      document.removeEventListener('pointerdown', handlePointerDown);
      document.removeEventListener('keydown', handleKeyDown);
      window.removeEventListener('resize', handleClose);
      document.removeEventListener('scroll', handleScroll, true);
    };
  }, [isOpen]);

  const style = {
    '--menu-select-min-width': toCssDimension(minWidth),
    '--menu-select-menu-min-width': toCssDimension(menuMinWidth ?? minWidth),
  } as CSSProperties;

  const rootClassName = className
    ? `${styles.root} ${className}`
    : styles.root;

  return (
    <div
      ref={rootRef}
      className={rootClassName}
      style={style}
      data-size={size}
      data-align={align}
      data-has-description={showSelectedDescription && selectedOption?.description ? 'true' : 'false'}
      onBlur={(event) => {
        const nextFocused = event.relatedTarget as Node | null;
        if (rootRef.current?.contains(nextFocused)) {
          return;
        }
        setIsOpen(false);
      }}
    >
      <button
        id={triggerId}
        ref={triggerRef}
        type="button"
        className={styles.trigger}
        data-open={isOpen}
        aria-label={ariaLabel}
        aria-haspopup="menu"
        aria-expanded={isOpen}
        onClick={() => setIsOpen((open) => !open)}
        onKeyDown={(event) => {
          if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            setIsOpen(true);
          }
        }}
      >
        <span
          className={styles.value}
          data-with-description={showSelectedDescription && selectedOption?.description ? 'true' : 'false'}
        >
          <span className={styles.valueLabel}>{selectedOption?.label ?? ''}</span>
          {showSelectedDescription && selectedOption?.description ? (
            <span className={styles.valueDescription}>{selectedOption.description}</span>
          ) : null}
        </span>
        <ChevronDown className={styles.icon} size={16} aria-hidden="true" />
      </button>

      {isOpen ? (
        <div
          ref={menuRef}
          className={styles.menu}
          role="menu"
          aria-labelledby={triggerId}
          tabIndex={-1}
          onKeyDown={(event) => {
            if (event.key === 'ArrowDown') {
              event.preventDefault();
              setActiveIndex((current) => (current + 1) % options.length);
              return;
            }

            if (event.key === 'ArrowUp') {
              event.preventDefault();
              setActiveIndex((current) => (current - 1 + options.length) % options.length);
              return;
            }

            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              const nextOption = options[activeIndex];
              if (!nextOption) {
                return;
              }
              onChange(nextOption.value);
              closeMenu(true);
              return;
            }

            if (event.key === 'Tab') {
              setIsOpen(false);
            }
          }}
        >
          {options.map((option, index) => {
            const isSelected = option.value === value;
            const isActive = activeIndex === index;

            return (
              <button
                key={option.value}
                type="button"
                className={styles.option}
                role="menuitemradio"
                aria-checked={isSelected}
                data-active={isActive}
                data-selected={isSelected}
                onMouseEnter={() => setActiveIndex(index)}
                onClick={() => {
                  onChange(option.value);
                  closeMenu();
                }}
              >
                <span className={styles.optionCopy}>
                  <span className={styles.optionLabel}>{option.label}</span>
                  {option.description ? (
                    <span className={styles.optionDescription}>{option.description}</span>
                  ) : null}
                </span>
                <span className={styles.optionCheck} aria-hidden="true">
                  {isSelected ? <Check size={14} strokeWidth={2.6} /> : null}
                </span>
              </button>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}
