'use client';

import { useAppStore } from '../../providers/StoreProvider';
import styles from './ConversationList.module.css';

export function SyncStatusIndicator() {
  const syncState = useAppStore((s) => s.syncState);
  const account = useAppStore((s) => s.account);
  if (!account || syncState === 'disabled') return null;

  const label = syncState === 'syncing' ? 'Syncing...'
    : syncState === 'error' ? 'Sync error'
    : null;

  if (!label) return null;

  return (
    <div className={styles.syncStatus}>
      {syncState === 'syncing' && (
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ animation: 'spin 1s linear infinite' }}>
          <path d="M21 12a9 9 0 11-6.219-8.56" />
        </svg>
      )}
      {syncState === 'error' && (
        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <circle cx="12" cy="12" r="10" />
          <line x1="12" y1="8" x2="12" y2="12" />
          <line x1="12" y1="16" x2="12.01" y2="16" />
        </svg>
      )}
      <span>{label}</span>
    </div>
  );
}
