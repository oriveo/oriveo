'use client';

import { useState } from 'react';
import { useTranslations } from 'next-intl';
import { DatabaseZap, X } from 'lucide-react';
import { useAppStore } from '../providers/StoreProvider';

/**
 * Degraded-mode banner for "the browser has disabled site data".
 *
 * **Why this has to exist**: with storage disabled the app looks usable - you can type, send a
 * message and see a reply - but nothing survives: conversations, BYOK keys and every preference
 * are gone after a refresh. Without this notice the user simply concludes the product loses
 * data and leaves (one observed sample arrived from chatgpt.com and left after 42 seconds).
 *
 * Shown only when persistence is unavailable as a whole (IndexedDB cannot be opened). If only
 * localStorage fails while IDB still works, the user is not interrupted: their data is still stored,
 * only a few local preferences are missing.
 *
 * The dismissed flag is kept in memory only. This is not a one-off notice but a persistent
 * environment problem, so the next visit should warn again - and sessionStorage is equally broken
 * in this situation anyway.
 */
export function StoragePersistenceBanner() {
  const storageHealth = useAppStore((s) => s.storageHealth);
  const [dismissed, setDismissed] = useState(false);
  const t = useTranslations('storage');

  if (dismissed) return null;
  // null means detection has not finished; do not alarm the user while it is unknown
  if (!storageHealth || storageHealth.persistent) return null;

  return (
    <div
      role="alert"
      aria-live="assertive"
      style={{
        position: 'fixed',
        top: 'var(--o-space-sm)',
        left: '50%',
        transform: 'translateX(-50%)',
        // Same layer as ServiceReachabilityBanner; the two never appear together, since one is about the network and this one about local storage
        zIndex: 10010,
        maxWidth: 'calc(100vw - 32px)',
        display: 'flex',
        alignItems: 'flex-start',
        gap: 'var(--o-space-sm)',
        padding: 'var(--o-space-sm) var(--o-space-md)',
        background: 'var(--o-error-subtle)',
        border: '1px solid var(--o-error)',
        borderRadius: 'var(--o-radius-card)',
        boxShadow: 'var(--o-elevation-card)',
        backdropFilter: 'blur(12px)',
        WebkitBackdropFilter: 'blur(12px)',
        fontSize: 'var(--o-text-sm)',
        color: 'var(--o-text)',
      }}
    >
      <span
        aria-hidden="true"
        style={{ color: 'var(--o-error)', display: 'flex', alignItems: 'center', paddingTop: 2 }}
      >
        <DatabaseZap size={16} strokeWidth={2.25} />
      </span>
      <span style={{ lineHeight: 1.35, maxWidth: 420 }}>
        <strong style={{ display: 'block', fontWeight: 600 }}>{t('blockedTitle')}</strong>
        <span style={{ color: 'var(--o-secondary-text)' }}>{t('blockedHint')}</span>
      </span>
      <button
        type="button"
        aria-label={t('dismiss')}
        onClick={() => setDismissed(true)}
        style={{
          width: 28,
          height: 28,
          border: 0,
          borderRadius: 999,
          background: 'transparent',
          color: 'var(--o-error)',
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          cursor: 'pointer',
          padding: 0,
          flexShrink: 0,
        }}
      >
        <X size={14} strokeWidth={2.4} aria-hidden="true" />
      </button>
    </div>
  );
}
