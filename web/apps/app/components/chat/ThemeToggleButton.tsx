'use client';

import { useCallback } from 'react';
import { useTranslations } from 'next-intl';
import { MoonStar, SunMedium } from 'lucide-react';
import { getVanillaStore, useAppStore } from '../../providers/StoreProvider';
import * as preferenceOps from '../../lib/core/preference-ops';
import { useIsDarkTheme } from '../../lib/hooks/useIsDarkTheme';
import styles from './ChatView.module.css';

export function ThemeToggleButton() {
  const t = useTranslations('pages.settings');
  const preferenceTheme = useAppStore((s) => s.preferences.theme);
  const isDark = useIsDarkTheme();
  const nextTheme = isDark ? 'light' : 'dark';
  const label = t(nextTheme === 'dark' ? 'themeDark' : 'themeLight');

  const handleToggle = useCallback(() => {
    preferenceOps.updateTheme(getVanillaStore(), nextTheme);
  }, [nextTheme]);

  return (
    <button
      type="button"
      className={styles.themeToggleBtn}
      data-current-theme={preferenceTheme}
      data-resolved-theme={isDark ? 'dark' : 'light'}
      onClick={handleToggle}
      aria-label={label}
      title={label}
    >
      {isDark ? (
        <SunMedium size={16} strokeWidth={2.15} aria-hidden="true" />
      ) : (
        <MoonStar size={16} strokeWidth={2.15} aria-hidden="true" />
      )}
    </button>
  );
}
