import type { ReactNode } from 'react';
import styles from './Badge.module.css';

interface BadgeProps {
  tone?: 'default' | 'success' | 'warning' | 'error' | 'info';
  children: ReactNode;
}

export function Badge({ tone = 'default', children }: BadgeProps) {
  return <span className={`${styles.badge} ${styles[tone]}`}>{children}</span>;
}
