'use client';

import { useCallback, useSyncExternalStore } from 'react';
import { isUnseen, subscribeFeatureBadges, type FeatureBadgeId } from '../lib/core/feature-badges';
import styles from './FeatureBadgeDot.module.css';

/** Decorative new-feature dot placed right after an entry row title; hidden from screen readers. */
export function FeatureBadgeDot({ id }: { id: FeatureBadgeId }) {
  const getSnapshot = useCallback(() => isUnseen(id), [id]);
  // Server snapshot is false so SSR output never shows a dot and hydration stays consistent.
  const visible = useSyncExternalStore(subscribeFeatureBadges, getSnapshot, () => false);
  if (!visible) return null;
  return <span className={styles.dot} aria-hidden="true" data-feature-badge={id} />;
}
