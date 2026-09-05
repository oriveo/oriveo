'use client';

import { useCallback } from 'react';
import { useTranslations } from 'next-intl';
import type { ThemeOption } from '@oriveo/shared';
import { useIsDarkTheme } from '../lib/hooks/useIsDarkTheme';
import styles from './ThemeToggle.module.css';

/**
 * Dark/light toggle button, used on entry pages such as welcome and email sign-in that have no
 * AppShell.
 *
 * The displayed state is read from `html[data-theme]` via useIsDarkTheme rather than from the
 * store during render, so it does not blow up in unit tests that never mount StoreProvider. A
 * click writes the dataset immediately so the icon flips at once (driven by a MutationObserver),
 * then persists to the store asynchronously through a dynamic import, which keeps the sync chain
 * out of module load during tests. Theme is local-only.
 */
export function ThemeToggle({ className }: { className?: string }) {
  const t = useTranslations('pages.settings');
  const isDark = useIsDarkTheme();

  const toggle = useCallback(() => {
    const next: ThemeOption = isDark ? 'light' : 'dark';
    if (typeof document !== 'undefined') {
      document.documentElement.dataset.theme = next;
    }
    void persistTheme(next);
  }, [isDark]);

  return (
    <button
      type="button"
      className={`${styles.toggle} ${className ?? ''}`}
      onClick={toggle}
      aria-label={t('theme')}
      title={t('theme')}
    >
      <span key={isDark ? 'sun' : 'moon'} className={styles.iconWrap} aria-hidden="true">
        {isDark ? <SunIcon /> : <MoonIcon />}
      </span>
    </button>
  );
}

async function persistTheme(next: ThemeOption) {
  try {
    const [{ tryGetVanillaStore }, { updateTheme }] = await Promise.all([
      import('../providers/StoreProvider'),
      import('../lib/core/preference-ops'),
    ]);
    const store = tryGetVanillaStore();
    if (store) updateTheme(store, next);
  } catch {
    // A failed persist does not affect this immediate toggle: the next visit falls back to the stored preference or the system setting.
  }
}

function SunIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.9"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg
      width="18"
      height="18"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.9"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    </svg>
  );
}
