'use client';

import { useEffect } from 'react';
import type { ThemeOption } from '@oriveo/shared';

function applyTheme(theme: ThemeOption) {
  if (typeof window === 'undefined') return;

  if (theme === 'light' || theme === 'dark') {
    document.documentElement.dataset.theme = theme;
    return;
  }

  // 'system' — resolve from media query
  const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  document.documentElement.dataset.theme = isDark ? 'dark' : 'light';
}

export function useTheme(theme: ThemeOption) {
  // Apply theme immediately on value change
  useEffect(() => {
    applyTheme(theme);

    // If system, listen for OS-level changes
    if (theme !== 'system') return;

    const mq = window.matchMedia('(prefers-color-scheme: dark)');
    const handler = (e: MediaQueryListEvent) => {
      document.documentElement.dataset.theme = e.matches ? 'dark' : 'light';
    };
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, [theme]);
}
