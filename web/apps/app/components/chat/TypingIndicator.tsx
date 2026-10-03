'use client';

import type { StreamActivity } from '@oriveo/core/providers/types';
import { useStreamActivityLabel, type StreamActivityMcpContext } from './StreamActivityLine';
import styles from './TypingIndicator.module.css';

/** `activity`: an activity observed on the wire. When present it replaces the label; the dots stay. */
export function TypingIndicator({ activity, mcp }: { activity?: StreamActivity | null; mcp?: StreamActivityMcpContext | null }) {
  const label = useStreamActivityLabel(activity ?? 'neutral', mcp);

  return (
    <span className={styles.wrap} aria-label={label}>
      <span className={styles.dots} aria-hidden="true">
        <span className={styles.dot} />
        <span className={styles.dot} />
        <span className={styles.dot} />
      </span>
      <span className={styles.label}>{label}</span>
    </span>
  );
}
