/**
 * Provider brand colour used as TEXT (ring centre title, hero pill label, provider row name).
 * Fills, dots, chart slices, icons and decorations keep the raw brand colour.
 * Hue and chroma come from the brand colour; OKLCH lightness steps by `step` (light: darker,
 * dark: lighter) until contrast >= `minContrast` against every background of the mode.
 * Already-passing colours are returned unchanged.
 * Shared fixture (repo shared contracts dir): test-fixtures/provider-tint/provider-text-tint.v1.json (reference: scripts/provider-text-tint.mjs).
 */
import { contrast, fromOklch, oklch } from './custom-palette';

export const PROVIDER_TEXT_TINT_RULE = {
  minContrast: 4.5,
  step: 0.01,
  light: ['#FFFFFF', '#F2EEF7'],
  dark: ['#1C1C1F', '#27272A', '#30343B'],
} as const;

function minContrast(hex: string, backgrounds: readonly string[]): number {
  return Math.min(...backgrounds.map((bg) => contrast(hex, bg)));
}

/** #RRGGBB brand colour → text variant for the given appearance (#RRGGBB, upper case). */
export function providerTextTint(hex: string, isDark: boolean): string {
  const rule = PROVIDER_TEXT_TINT_RULE;
  const raw = hex.toUpperCase();
  const backgrounds = isDark ? rule.dark : rule.light;
  if (minContrast(raw, backgrounds) >= rule.minContrast) return raw;
  const [L0, C, H] = oklch(raw);
  const dir = isDark ? 1 : -1;
  for (let n = 1; ; n += 1) {
    const L = Math.min(1, Math.max(0, L0 + dir * rule.step * n));
    const out = fromOklch(L, C, H);
    if (minContrast(out, backgrounds) >= rule.minContrast || L === 0 || L === 1) return out;
  }
}
