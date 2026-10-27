'use client';

// Settings home grid.
// No card background and no border; cells are separated only by thin cross-shaped fading lines pinned to the grid center, with no outer frame.

import type { CSSProperties, ReactNode } from 'react';
import { settingsGridShape } from './settings-home-rules';
import styles from './SettingsGrid.module.css';

export interface SettingsGridItem {
  key: string;
  icon: ReactNode;
  title: ReactNode;
  /** Current value; when absent the value line is not rendered (no placeholder, no "none" text). */
  value?: ReactNode;
  /** With an href it renders as a link (external / mailto); otherwise as a button that calls onSelect. */
  href?: string;
  external?: boolean;
  onSelect?: () => void;
  /** Written to data-settings-entry so tests and screenshots can locate the cell. */
  entry?: string;
  testId?: string;
}

export function SettingsGrid({
  items,
  variant = 'main',
  ariaLabel,
}: {
  items: SettingsGridItem[];
  /** main: AI / tools groups (cell height 104); compact: help and about (cell height 76). */
  variant?: 'main' | 'compact';
  ariaLabel?: string;
}) {
  const { columns, rows } = settingsGridShape(items.length);
  if (columns === 0) return null;

  // Vertical line inset: 10 for 2x2, 18 for a single row (1x2 / 1x3), 16 for the help group.
  const verticalInset = variant === 'compact' ? 16 : rows > 1 ? 10 : 18;
  const style = {
    '--sg-columns': columns,
    '--sg-v-inset': `${verticalInset}px`,
  } as CSSProperties;

  return (
    <div
      className={styles.grid}
      data-variant={variant}
      data-columns={columns}
      data-rows={rows}
      role="group"
      aria-label={ariaLabel}
      style={style}
    >
      {Array.from({ length: columns - 1 }, (_, index) => (
        <span
          key={`v${index}`}
          aria-hidden="true"
          className={styles.lineVertical}
          style={{ left: `${((index + 1) * 100) / columns}%` }}
        />
      ))}
      {Array.from({ length: rows - 1 }, (_, index) => (
        <span
          key={`h${index}`}
          aria-hidden="true"
          className={styles.lineHorizontal}
          style={{ top: `${((index + 1) * 100) / rows}%` }}
        />
      ))}
      {items.map((item) => {
        const content = (
          <>
            <span className={styles.icon}>{item.icon}</span>
            <span className={styles.title}>{item.title}</span>
            {item.value != null && item.value !== '' ? (
              <span className={styles.value}>{item.value}</span>
            ) : null}
          </>
        );
        if (item.href) {
          return (
            <a
              key={item.key}
              href={item.href}
              className={styles.cell}
              data-settings-entry={item.entry}
              data-testid={item.testId}
              {...(item.external ? { target: '_blank', rel: 'noopener noreferrer' } : {})}
            >
              {content}
            </a>
          );
        }
        return (
          <button
            key={item.key}
            type="button"
            className={styles.cell}
            data-settings-entry={item.entry}
            data-testid={item.testId}
            onClick={item.onSelect}
          >
            {content}
          </button>
        );
      })}
    </div>
  );
}
