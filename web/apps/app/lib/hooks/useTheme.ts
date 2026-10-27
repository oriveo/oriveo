'use client';

import { useEffect } from 'react';
import { CUSTOM_PALETTE_ID, customLightBrandCssVars, customPaletteCssVars, resolvePaletteChoice } from '@oriveo/shared';
import type { CustomPaletteId, DarkPaletteId, ThemeOption } from '@oriveo/shared';
import { safeLocalStorage } from '../infra/storage/web-storage';
import {
  CUSTOM_PALETTE_STYLE_ID,
  CUSTOM_PALETTE_VARS_CACHE_KEY,
  customPaletteCssText,
  type CustomPaletteVarsCache,
} from '../theme/custom-palette-style';
import { syncThemeColorMeta } from '../theme/theme-color';

/** Write the custom palette's dark and light sections into a dedicated <style> in <head>; null removes it (switched back to a preset). Unchanged content is not rewritten. */
function writeCustomPaletteStyle(vars: Record<string, string> | null, lightVars: Record<string, string> = {}): void {
  let el = document.getElementById(CUSTOM_PALETTE_STYLE_ID);
  if (!vars) {
    el?.remove();
    return;
  }
  if (!el) {
    el = document.createElement('style');
    el.id = CUSTOM_PALETTE_STYLE_ID;
    document.head.appendChild(el);
  }
  const css = customPaletteCssText(vars, lightVars);
  if (el.textContent !== css) el.textContent = css;
}

/** First-paint cache that prevents a flash: ThemeInitScript applies it directly when the seed matches. Unchanged values are not rewritten. */
function cacheCustomPaletteVars(seed: string, vars: Record<string, string>, lightVars: Record<string, string>): void {
  const next = JSON.stringify({ seed, vars, lightVars } satisfies CustomPaletteVarsCache);
  if (safeLocalStorage.getItem(CUSTOM_PALETTE_VARS_CACHE_KEY) !== next) {
    safeLocalStorage.setItem(CUSTOM_PALETTE_VARS_CACHE_KEY, next);
  }
}

/**
 * Switch the palette at runtime: <html data-palette> changes, CSS variables cascade, and the page is not rebuilt.
 * Preset: an unknown id / non-string falls back to the default dark. Custom ('custom'): derived from the seed (invalid / missing = default seed);
 * the derived values are written as a [data-theme='dark'][data-palette='custom'] section and a [data-theme='light'][data-palette='custom'] section
 * (the same variable sets as the dark and light preset sections in variables.css), and removed when switching back to a preset.
 * Preferences are not written (writing goes through preference-ops.updateDarkPalette).
 */
export function applyDarkPalette(id: unknown, seed?: unknown): DarkPaletteId | CustomPaletteId {
  const choice = resolvePaletteChoice(id, seed);
  const palette = choice.kind === 'custom' ? CUSTOM_PALETTE_ID : choice.id;
  if (typeof document !== 'undefined') {
    if (choice.kind === 'custom') {
      const vars = customPaletteCssVars(choice.seed);
      const lightVars = customLightBrandCssVars(choice.seed);
      writeCustomPaletteStyle(vars, lightVars);
      cacheCustomPaletteVars(choice.seed, vars, lightVars);
    } else {
      writeCustomPaletteStyle(null);
    }
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
 * The app root follows darkPalette in preferences (with the darkPaletteCustom seed color when custom): the stored raw value may be an unknown id, and rendering falls back to dark via applyDarkPalette
 * without writing preferences back. Runs only when the value changes, so switching palettes does not rebuild the page.
 */
export function useDarkPalette(darkPalette: unknown, darkPaletteCustom?: unknown) {
  useEffect(() => {
    applyDarkPalette(darkPalette, darkPaletteCustom);
  }, [darkPalette, darkPaletteCustom]);
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
