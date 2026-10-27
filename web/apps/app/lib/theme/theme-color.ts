/**
 * <meta name="theme-color"> follows the current page background (--o-bg).
 * The first frame (ThemeInitScript, the stylesheet may not have arrived yet) only distinguishes light from the default dark;
 * after hydration useTheme overrides it with the computed --o-bg whenever the theme or palette changes, so each of the 7 dark palettes uses its own bg.
 * The two constants must equal --o-bg in the light and default dark sections of variables.css (locked by theme-color.test).
 */
export const THEME_COLOR_LIGHT = '#FAFAFA';
export const THEME_COLOR_DARK_DEFAULT = '#111113';

export const THEME_COLOR_META_SELECTOR = 'meta[name="theme-color"]';

/** Update theme-color from the --o-bg currently in effect on <html>; when styles are not ready, fall back to the first-frame constant for the theme. */
export function syncThemeColorMeta(): void {
  if (typeof document === 'undefined') return;
  const meta = document.querySelector<HTMLMetaElement>(THEME_COLOR_META_SELECTOR);
  if (!meta) return;
  const root = document.documentElement;
  const bg = getComputedStyle(root).getPropertyValue('--o-bg').trim();
  const fallback = root.dataset.theme === 'light' ? THEME_COLOR_LIGHT : THEME_COLOR_DARK_DEFAULT;
  const next = bg || fallback;
  // Skip identical values to avoid needless attribute mutations
  if (meta.getAttribute('content') !== next) meta.setAttribute('content', next);
}
