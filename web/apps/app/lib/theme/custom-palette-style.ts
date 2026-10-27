/**
 * Rendering carrier of the custom palette (darkPalette = 'custom'), shared by useTheme and ThemeInitScript.
 * Derived values are not written into documentElement.style: inline variables do not distinguish light from dark and would leak the dark background into the light appearance;
 * they are written instead as two rules in <head> shaped like the preset palette sections in variables.css:
 * [data-theme='dark'][data-palette='custom'] (the 15 dark colors + glow-k + bubble stops) and
 * [data-theme='light'][data-palette='custom'] (the light brand-color family + bubble stops). Both sections are present at once, so switching appearance needs no rewrite.
 */
export const CUSTOM_PALETTE_STYLE_ID = 'oriveo-custom-palette';

/** localStorage first-frame cache that prevents a flash: { seed, vars, lightVars }; ThemeInitScript applies it directly when the preference seed matches and both groups are present. */
export const CUSTOM_PALETTE_VARS_CACHE_KEY = 'oriveo.customPaletteVars';

export const CUSTOM_PALETTE_SELECTOR = "[data-theme='dark'][data-palette='custom']";
export const CUSTOM_PALETTE_LIGHT_SELECTOR = "[data-theme='light'][data-palette='custom']";

export interface CustomPaletteVarsCache {
  seed: string;
  vars: Record<string, string>;
  lightVars: Record<string, string>;
}

/**
 * Variable names may only be --o-*, and values may only be #RRGGBB, a comma-separated list of #RRGGBB (the --o-user-bubble-stops bubble stops), or a number
 * (the cache comes from localStorage and is filtered before being spliced into <style>).
 */
export const CUSTOM_PALETTE_VAR_NAME_PATTERN = /^--o-[a-z-]+$/;
export const CUSTOM_PALETTE_VAR_VALUE_PATTERN = /^(#[0-9A-Fa-f]{6}(,#[0-9A-Fa-f]{6})*|[0-9.]+)$/;

function cssBody(vars: Record<string, string>): string {
  return Object.entries(vars)
    .filter(([name, value]) => CUSTOM_PALETTE_VAR_NAME_PATTERN.test(name) && CUSTOM_PALETTE_VAR_VALUE_PATTERN.test(value))
    .map(([name, value]) => `${name}:${value};`)
    .join('');
}

/** Dark section + light section (variable names / values filtered by the same whitelist). */
export function customPaletteCssText(vars: Record<string, string>, lightVars: Record<string, string>): string {
  return `${CUSTOM_PALETTE_SELECTOR}{${cssBody(vars)}}${CUSTOM_PALETTE_LIGHT_SELECTOR}{${cssBody(lightVars)}}`;
}
