'use client';

import { memo } from 'react';
import styles from './StreamingPulseDot.module.css';

interface StreamingPulseDotProps {
  ariaLabel: string;
}

/**
 *   — 6×6px  
 * `prefers-reduced-motion`  
 */
export const StreamingPulseDot = memo(function StreamingPulseDot({
  ariaLabel,
}: StreamingPulseDotProps) {
  return <span className={styles.dot} role="status" aria-label={ariaLabel} />;
});
