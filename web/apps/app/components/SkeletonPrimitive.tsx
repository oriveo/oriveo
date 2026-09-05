'use client';

import styles from './SkeletonPrimitive.module.css';

interface SkeletonLineProps {
  width?: string;
  height?: string;
}

export function SkeletonLine({ width = '100%', height = '14px' }: SkeletonLineProps) {
  return <div className={styles.line} style={{ width, height }} />;
}

export function SkeletonCircle({ size = '32px' }: { size?: string }) {
  return <div className={styles.circle} style={{ width: size, height: size }} />;
}

export function SkeletonConversationList() {
  return (
    <div className={styles.convList}>
      {Array.from({ length: 6 }, (_, i) => (
        <div key={i} className={styles.convItem}>
          <div className={styles.convContent}>
            <SkeletonLine width={`${65 + (i * 7) % 30}%`} height="14px" />
            <SkeletonLine width={`${45 + (i * 11) % 40}%`} height="11px" />
          </div>
        </div>
      ))}
    </div>
  );
}

export function SkeletonProviderCard() {
  return (
    <div className={styles.providerCard}>
      <div className={styles.providerHeader}>
        <SkeletonCircle size="40px" />
        <div className={styles.providerInfo}>
          <SkeletonLine width="120px" height="16px" />
          <SkeletonLine width="80px" height="12px" />
        </div>
      </div>
      <SkeletonLine width="60%" height="12px" />
    </div>
  );
}

export function SkeletonModelRow() {
  return (
    <div className={styles.modelRow}>
      <SkeletonLine width="60%" height="14px" />
      <SkeletonLine width="40px" height="24px" />
    </div>
  );
}
