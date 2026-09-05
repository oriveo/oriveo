'use client';

import styles from './Skeleton.module.css';

export function Skeleton() {
  return (
    <div className={styles.shell}>
      {/* Sidebar skeleton */}
      <div className={styles.sidebar}>
        <div className={styles.sidebarHeader}>
          <div className={`${styles.block} ${styles.brand}`} />
        </div>
        <div className={styles.sidebarItems}>
          {Array.from({ length: 6 }).map((_, i) => (
            <div key={i} className={styles.sidebarItem}>
              <div className={`${styles.block} ${styles.itemTitle}`} />
              <div className={`${styles.block} ${styles.itemPreview}`} />
            </div>
          ))}
        </div>
      </div>

      {/* Main content skeleton */}
      <div className={styles.main}>
        {/* TopBar */}
        <div className={styles.topBar}>
          <div className={`${styles.block} ${styles.topBarModel}`} />
        </div>

        {/* Messages */}
        <div className={styles.messages}>
          <div className={`${styles.msgRow} ${styles.msgUser}`}>
            <div className={`${styles.block} ${styles.msgBubble} ${styles.short}`} />
          </div>
          <div className={`${styles.msgRow} ${styles.msgAssistant}`}>
            <div className={`${styles.block} ${styles.msgBubble} ${styles.long}`} />
          </div>
          <div className={`${styles.msgRow} ${styles.msgUser}`}>
            <div className={`${styles.block} ${styles.msgBubble} ${styles.medium}`} />
          </div>
          <div className={`${styles.msgRow} ${styles.msgAssistant}`}>
            <div className={`${styles.block} ${styles.msgBubble} ${styles.long}`} />
          </div>
        </div>

        {/* InputComposer */}
        <div className={styles.inputArea}>
          <div className={`${styles.block} ${styles.inputBar}`} />
        </div>
      </div>
    </div>
  );
}
