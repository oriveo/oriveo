/**
 * Light-appearance brand colors: a palette also takes effect in the light appearance;
 * neutral surfaces / text / borders stay the same and only the brand-color family changes.
 * Source of truth: `light` (derivation / palettes) in shared/theme-contracts/dark-palettes.v1.json;
 * the formula is deriveLight ported from the contrast reference implementation, and light-brand.test.ts checks it against the fixture one by one.
 * The light of the default palette (dark) is hand-tuned, and web rendering uses the default section of variables.css (lightBrandFor returns null).
 */
import type { DarkPaletteId } from './dark-palettes';
import {
  CUSTOM_DERIVATION,
  USER_BUBBLE_STOPS_CSS_VAR,
  bubbleStops,
  deriveCustom,
  fromOklch,
  oklch,
  parseSeed,
  DEFAULT_CUSTOM_SEED,
  type PaletteChoice,
} from './custom-palette';

/** Light brand color fields (JSON `light.palettes.<id>` without mode). */
export const LIGHT_BRAND_TOKENS = [
  'ink',
  'textSafe',
  'fill',
  'fillText',
  'fillPressed',
  'gradStart',
  'gradEnd',
  'soft',
  'accent',
  'bgTop',
  'bgBottom',
  'pill',
  'onPrimary',
] as const;
export type LightBrandToken = (typeof LIGHT_BRAND_TOKENS)[number];

export type LightBrandMode = 'white' | 'bright';
export type LightBrand = Record<LightBrandToken, string> & { mode: LightBrandMode };

type LadderKey = 'ink' | 'textSafe' | 'fill' | 'fillText' | 'fillPressed' | 'gradStart' | 'gradEnd' | 'soft' | 'accent' | 'bgTop' | 'bgBottom' | 'pill';
type FillKey = 'fill' | 'fillText' | 'fillPressed' | 'gradStart' | 'gradEnd';

/** JSON `light.derivation` (see its `$steps` for a step-by-step description); ladder = [L, C]. */
export const LIGHT_DERIVATION = {
  ladder: {
    ink: [0.612, 0.22],
    textSafe: [0.491, 0.241],
    fill: [0.612, 0.22],
    fillText: [0.491, 0.241],
    fillPressed: [0.545, 0.246],
    gradStart: [0.57, 0.242],
    gradEnd: [0.493, 0.204],
    soft: [0.943, 0.028],
    accent: [0.667, 0.259],
    bgTop: [0.973, 0.008],
    bgBottom: [0.955, 0.013],
    pill: [0.96, 0.014],
  } as Record<LadderKey, readonly [number, number]>,
  bright: { fill: 0.75, fillText: 0.75, fillPressed: 0.7, gradStart: 0.8, gradEnd: 0.74 } as Record<FillKey, number>,
  step: 0.01,
  minLightness: 0.2,
  maxLightness: 0.95,
  minInk: 3,
  minText: 4.5,
  minInkText: 3.8,
} as const;

/** JSON `light.palettes`: the light brand colors of the 7 presets (dark is the hand-tuned default, the rest are deriveLight output). */
export const LIGHT_BRAND_PRESETS: Record<DarkPaletteId, LightBrand> = {
  dark: { ink: '#8C5FF8', textSafe: '#6D28D9', fill: '#8C5FF8', fillText: '#6D28D9', fillPressed: '#7B3DEF', gradStart: '#8347F5', gradEnd: '#6B3BC7', soft: '#EDE9FE', accent: '#D946EF', bgTop: '#F7F5FB', bgBottom: '#F2EEF7', pill: '#F3F0FA', onPrimary: '#FFFFFF', mode: 'white' },
  'dark-purple': { ink: '#8F5DF8', textSafe: '#6F27D8', fill: '#8F5DF8', fillText: '#6F27D8', fillPressed: '#7E3BED', gradStart: '#8547F4', gradEnd: '#6C3BC7', soft: '#EDE9FE', accent: '#D847F1', bgTop: '#F6F5FB', bgBottom: '#F0EFF8', pill: '#F2F0FB', onPrimary: '#FFFFFF', mode: 'white' },
  'dark-graphite': { ink: '#0076FD', textSafe: '#025AC4', fill: '#0076FD', fillText: '#025AC4', fillPressed: '#0169E2', gradStart: '#0370EF', gradEnd: '#055BC4', soft: '#E3EDFD', accent: '#149BB8', bgTop: '#F3F6FC', bgBottom: '#EBF1F9', pill: '#ECF2FB', onPrimary: '#FFFFFF', mode: 'white' },
  'dark-black': { ink: '#E42E7A', textSafe: '#B00358', fill: '#E42E7A', fillText: '#B00358', fillPressed: '#CB0667', gradStart: '#D8016D', gradEnd: '#B10759', soft: '#FEE5EB', accent: '#0298C9', bgTop: '#FBF4F6', bgBottom: '#F8EDEF', pill: '#FBEEF1', onPrimary: '#FFFFFF', mode: 'white' },
  'dark-ocean': { ink: '#0E8B7C', textSafe: '#0C7064', fill: '#14C9B4', fillText: '#0EC9B4', fillPressed: '#18B7A4', gradStart: '#0FDBC4', gradEnd: '#06C5B1', soft: '#D9F3ED', accent: '#0693F0', bgTop: '#F1F8F6', bgBottom: '#E7F3F1', pill: '#E8F5F2', onPrimary: '#021614', mode: 'bright' },
  'dark-forest': { ink: '#0F8D63', textSafe: '#03734F', fill: '#0DCD91', fillText: '#05CD90', fillPressed: '#06BB83', gradStart: '#13DF9E', gradEnd: '#16C98E', soft: '#DCF2E7', accent: '#779A0E', bgTop: '#F2F8F4', bgBottom: '#E9F3EE', pill: '#EAF5EF', onPrimary: '#03160C', mode: 'bright' },
  'dark-sunset': { ink: '#A77201', textSafe: '#815705', fill: '#E59E08', fillText: '#E59E02', fillPressed: '#D19005', gradStart: '#F9AD0D', gradEnd: '#E09B12', soft: '#F7EAD8', accent: '#FF474D', bgTop: '#F9F5F0', bgBottom: '#F5EFE7', pill: '#F7F1E8', onPrimary: '#241005', mode: 'bright' },
};

/**
 * Light brand colors to web CSS variables (the same set as the [data-theme='light'][data-palette='*'] sections in variables.css and the custom <style> section).
 * Values are chosen by whether text is drawn on top: --o-primary is the icon / stroke / emphasis color on a white background (ink); --o-primary-active is used as a text color in light (textSafe);
 * --o-primary-hover is the pressed / hover fill (fillPressed); --o-primary-text-safe is a fill that carries text (fillText), and --o-primary-fill is a fill for icons only (fill);
 * the text / icon on top of both is --o-primary-text (onPrimary). In bright-fill palettes ink and onPrimary are both dark and cannot be paired.
 * soft / pill have no counterpart on the web (subtle is ink @ 8%, derived by color-mix in the default section).
 */
export const LIGHT_BRAND_CSS_VARS: ReadonlyArray<readonly [LightBrandToken, string]> = [
  ['ink', '--o-primary'],
  ['fillPressed', '--o-primary-hover'],
  ['textSafe', '--o-primary-active'],
  ['onPrimary', '--o-primary-text'],
  ['textSafe', '--o-primary-text-on-surface'],
  ['fillText', '--o-primary-text-safe'],
  ['fill', '--o-primary-fill'],
  ['accent', '--o-brand-accent'],
  ['gradStart', '--o-brand-grad-start'],
  ['gradEnd', '--o-brand-grad-end'],
  ['bgTop', '--o-brand-bg-top'],
  ['bgBottom', '--o-brand-bg-bottom'],
];

// ── Color math (the same oklch / fromOklch as custom-palette; contrast is computed here separately to avoid widening custom-palette's exports) ──

function channel(c: number): number {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

function luminance(hex: string): number {
  const n = parseInt(hex.slice(1), 16);
  return 0.2126 * channel((n >> 16) & 255) + 0.7152 * channel((n >> 8) & 255) + 0.0722 * channel(n & 255);
}

function contrast(a: string, b: string): number {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/** The three fields of this dark palette that the light derivation uses. */
export interface LightBrandSource {
  primary: string;
  accent: string;
  onPrimary: string;
}

/** Dark palette to light brand colors (port of deriveLight). */
export function deriveLight(palette: LightBrandSource): LightBrand {
  const d = LIGHT_DERIVATION;
  const g = CUSTOM_DERIVATION.gamutStep;
  const H = oklch(palette.primary)[2];
  const AH = oklch(palette.accent)[2];
  const white = '#FFFFFF';
  const at = (key: LadderKey, L: number = d.ladder[key][0]) => fromOklch(L, d.ladder[key][1], key === 'accent' ? AH : H, g);
  const out = {} as Record<LadderKey, string>;
  for (const key of Object.keys(d.ladder) as LadderKey[]) out[key] = at(key);
  // Step the lightness down the ladder until test(color) >= min
  const darken = (key: LadderKey, test: (hex: string) => number, min: number) => {
    const [L] = d.ladder[key];
    for (let i = 1; test(out[key]) < min && L - d.step * i >= d.minLightness; i += 1) out[key] = at(key, L - d.step * i);
  };
  // Ink is used for small text such as emphasized words and links: no lower than the default hand-tuned purple (3.80)
  darken('ink', (x) => contrast(x, out.bgTop), d.minInkText);
  darken('accent', (x) => contrast(x, out.bgTop), d.minInk);
  darken('textSafe', (x) => Math.min(contrast(x, white), contrast(x, out.bgTop), contrast(x, out.soft)), d.minText);

  // Fill color: darkened with white text vs a bright background with dark text, whichever gives the gradient start higher chroma
  const probe = d.ladder.gradStart;
  const chroma = (L: number) => oklch(fromOklch(L, probe[1], H, g))[1];
  const bright = chroma(d.bright.gradStart) > chroma(probe[0]);
  const onPrimary = bright ? palette.onPrimary : white;
  const fillKeys: FillKey[] = ['fill', 'fillText', 'fillPressed', 'gradStart', 'gradEnd'];
  if (bright) {
    for (const key of fillKeys) {
      const L = d.bright[key];
      out[key] = at(key, L);
      for (let i = 1; contrast(onPrimary, out[key]) < d.minText && L + d.step * i <= d.maxLightness; i += 1) {
        out[key] = at(key, L + d.step * i);
      }
    }
  } else {
    out.fill = out.ink;
    out.fillText = out.textSafe;
    for (const key of ['fillPressed', 'gradStart', 'gradEnd'] as const) darken(key, (x) => contrast(x, white), d.minText);
  }
  return { ...out, onPrimary, mode: bright ? 'bright' : 'white' };
}

// Called often during rendering (theme switches, first-frame cache, preview), so results are cached by seed
const customLightCache = new Map<string, LightBrand>();

/** Custom seed to light brand colors (derive dark first, then light). An invalid seed is treated as the default seed. */
export function deriveCustomLight(seed: string): LightBrand {
  const key = parseSeed(seed) ?? DEFAULT_CUSTOM_SEED;
  const cached = customLightCache.get(key);
  if (cached) return cached;
  const result = deriveLight(deriveCustom(key).palette);
  customLightCache.set(key, result);
  return result;
}

/** The current palette's brand colors in light; the default palette returns null (it uses the hand-tuned values in the default section of variables.css). */
export function lightBrandFor(choice: PaletteChoice): LightBrand | null {
  if (choice.kind === 'custom') return deriveCustomLight(choice.seed);
  return choice.id === 'dark' ? null : LIGHT_BRAND_PRESETS[choice.id];
}

/** Same as above, but the default palette returns the hand-tuned defaults (use it when JS needs a concrete color value, such as the input to hsbAdjusted). */
export function lightBrandColors(choice: PaletteChoice): LightBrand {
  return lightBrandFor(choice) ?? LIGHT_BRAND_PRESETS.dark;
}

const customLightBubbleCache = new Map<string, readonly string[]>();

/** Custom seed to light bubble stops (gradEnd to gradStart), cached by seed. */
export function customLightBubbleStops(seed: string): readonly string[] {
  const key = parseSeed(seed) ?? DEFAULT_CUSTOM_SEED;
  const cached = customLightBubbleCache.get(key);
  if (cached) return cached;
  const { gradEnd, gradStart } = deriveCustomLight(key);
  const result = Object.freeze(bubbleStops(gradEnd, gradStart));
  customLightBubbleCache.set(key, result);
  return result;
}

/** Custom seed to light CSS variables (the same keys as the light preset sections of variables.css: brand-color family + bubble stops). */
export function customLightBrandCssVars(seed: string): Record<string, string> {
  const brand = deriveCustomLight(seed);
  const vars: Record<string, string> = {};
  for (const [token, name] of LIGHT_BRAND_CSS_VARS) vars[name] = brand[token];
  vars[USER_BUBBLE_STOPS_CSS_VAR] = customLightBubbleStops(seed).join(',');
  return vars;
}
