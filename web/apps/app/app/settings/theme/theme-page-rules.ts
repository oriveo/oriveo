import { resolveDarkPaletteId } from '@oriveo/shared';
import type { DarkPaletteId, ThemeOption } from '@oriveo/shared';

/**
 * Theme page rules. Pure functions only; the
 * cases live in shared/theme-contracts/dark-palettes.v1.json `themePageCases`.
 */

/** A swatch on the theme page: the light base swatch or one of the dark palettes ("dark" included). */
export type ThemeSwatchId = 'light' | DarkPaletteId;

export type SystemAppearance = 'light' | 'dark';

export type ThemePageAction =
  | { kind: 'tap'; swatch: ThemeSwatchId }
  | { kind: 'toggleFollow'; on: boolean };

export interface ThemePageState {
  theme: ThemeOption;
  /** Raw stored value; may be unset or an unknown id. */
  darkPalette: unknown;
}

/** Fields the page writes back; absent field = untouched. */
export interface ThemePageWrites {
  theme?: ThemeOption;
  darkPalette?: DarkPaletteId;
}

/** Applies one user action and returns the preference fields to write. */
export function themePageWrites(
  state: ThemePageState,
  action: ThemePageAction,
  systemAppearance: SystemAppearance,
): ThemePageWrites {
  const writes: ThemePageWrites = {};
  const setTheme = (theme: ThemeOption) => {
    if (theme !== state.theme) writes.theme = theme;
  };
  if (action.kind === 'toggleFollow') {
    setTheme(action.on ? 'system' : systemAppearance);
    return writes;
  }
  if (action.swatch === 'light') {
    setTheme('light');
    return writes;
  }
  // Tapping a dark swatch always records the explicit choice (also for the default "dark").
  writes.darkPalette = action.swatch;
  if (state.theme !== 'system') setTheme('dark');
  return writes;
}

/** Which swatch shows the selection ring (and drives the preview). */
export function selectedSwatch(theme: ThemeOption, darkPalette: unknown): ThemeSwatchId {
  if (theme === 'light') return 'light';
  return resolveDarkPaletteId(darkPalette);
}

const PALETTE_LABEL_KEYS: Record<DarkPaletteId, string> = {
  dark: 'themeDark',
  'dark-purple': 'themePalettePurple',
  'dark-graphite': 'themePaletteGraphite',
  'dark-black': 'themePaletteBlack',
  'dark-ocean': 'themePaletteOcean',
  'dark-forest': 'themePaletteForest',
  'dark-sunset': 'themePaletteSunset',
};

/** `pages.settings` key of a swatch name. */
export function swatchLabelKey(swatch: ThemeSwatchId): string {
  return swatch === 'light' ? 'themeLight' : PALETTE_LABEL_KEYS[swatch];
}

type Translate = (key: string, values?: Record<string, string>) => string;

/** Trailing summary of the Settings › Appearance › Theme row. */
export function themeRowSummary(theme: ThemeOption, darkPalette: unknown, t: Translate): string {
  if (theme === 'light') return t('themeLight');
  const palette = t(PALETTE_LABEL_KEYS[resolveDarkPaletteId(darkPalette)]);
  if (theme === 'dark') return palette;
  return t('themeSummaryFollowSystem', { palette });
}
