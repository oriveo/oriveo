'use client';

import { useEffect } from 'react';
import { resolveDarkPaletteId } from '@oriveo/shared';
import type { DarkPaletteId, ThemeOption } from '@oriveo/shared';
import { syncThemeColorMeta } from '../theme/theme-color';

/**
 * Switch the dark palette at runtime: only <html data-palette> changes, CSS variables cascade, and the page is not rebuilt.
 * Unknown ids / non-strings fall back to the default dark; preferences are not written (writing goes through preference-ops.updateDarkPalette).
 */
export function applyDarkPalette(id: unknown): DarkPaletteId {
  const palette = resolveDarkPaletteId(id);
  if (typeof document !== 'undefined') {
    document.documentElement.dataset.palette = palette;
    syncThemeColorMeta();
  }
  return palette;
}

function applyTheme(theme: ThemeOption) {
  if (typeof window === 'undefined') return;

  if (theme === 'light' || theme === 'dark') {
    document.documentElement.dataset.theme = theme;
  } else {
    // 'system' — resolve from media query
    const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    document.documentElement.dataset.theme = isDark ? 'dark' : 'light';
  }
  syncThemeColorMeta();
}

/**
 * The app root follows darkPalette in preferences: the stored raw value may be an unknown id, and rendering falls back to dark via applyDarkPalette
 * without writing preferences back. Runs only when the value changes, so switching palettes does not rebuild the page.
 */
export function useDarkPalette(darkPalette: unknown) {
  useEffect(() => {
    applyDarkPalette(darkPalette);
  }, [darkPalette]);
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
      syncThemeColorMeta();
    };
    mq.addEventListener('change', handler);
    return () => mq.removeEventListener('change', handler);
  }, [theme]);
}
