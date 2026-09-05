'use client';

import type { CSSProperties, ReactNode } from 'react';
import type { LucideIcon } from 'lucide-react';
import styles from './RelayTintedSection.module.css';

interface RelayTintedSectionProps {
  /** UPPERCASE title, already localised */
  title: string;
  /** lucide icon inside the leading 20px icon box */
  Icon: LucideIcon;
  /** Tint hex for the light theme (e.g. "#6366F1") */
  tint: string;
  /** Tint hex for the dark theme, usually a brighter shade of the same hue */
  tintDark: string;
  children: ReactNode;
}

export function RelayTintedSection({ title, Icon, tint, tintDark, children }: RelayTintedSectionProps) {
  // The dark theme uses the brighter hex; a data prop lets CSS decide which one applies
  return (
    <div
      className={styles.wrap}
      style={{
        ['--section-tint' as never]: tint,
        ['--section-tint-dark' as never]: tintDark,
      } as CSSProperties}
    >
      <div className={styles.header}>
        <span className={styles.icon} aria-hidden="true">
          <Icon size={11} strokeWidth={2.6} />
        </span>
        <span className={styles.title}>{title}</span>
      </div>
      <div className={styles.stack}>{children}</div>
    </div>
  );
}
