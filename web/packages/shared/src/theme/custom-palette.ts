/**
 * Custom dark palette (the 8th palette, id `custom`).
 * The user picks a single seed color #RRGGBB and the whole set of 15 color values is derived by formula.
 * Parameter source of truth: `custom` in shared/theme-contracts/dark-palettes.v1.json (defaultSeed / presets / hueSlider / derivation);
 * the formulas are oklch / fromOklch / hueSliderSeed / deriveCustom ported from the contrast reference implementation,
 * and custom-palette.test.ts checks derivationCases and the JSON parameters one by one.
 */
import { resolveDarkPaletteId, type DarkPaletteId } from './dark-palettes';

export const CUSTOM_PALETTE_ID = 'custom' as const;
export type CustomPaletteId = typeof CUSTOM_PALETTE_ID;

/** JSON `custom.defaultSeed` */
export const DEFAULT_CUSTOM_SEED = '#60A5FA';

/** JSON `custom.presets` (the 12 preset colors of the color picker, in display order) */
export const CUSTOM_PRESETS: readonly string[] = [
  '#FF8A65',
  '#FB923C',
  '#FBBF24',
  '#A3E635',
  '#4ADE80',
  '#2DD4BF',
  '#22D3EE',
  '#60A5FA',
  '#818CF8',
  '#C084FC',
  '#F472B6',
  '#FB7185',
];

/** JSON `custom.hueSlider`: hue slider h -> seed = OKLCH(lightness, chroma, h) */
export const CUSTOM_HUE_SLIDER = { lightness: 0.78, chroma: 0.14, min: 0, max: 359 } as const;

/** The 15 color fields of the derived output (the same set as the preset palette sections in variables.css). */
export const CUSTOM_PALETTE_TOKENS = [
  'bg',
  'bgSubtle',
  'bgInset',
  'surface',
  'surfaceRaised',
  'text',
  'textSecondary',
  'textTertiary',
  'primary',
  'primaryHover',
  'primaryActive',
  'accent',
  'onPrimary',
  'codeBg',
  'codeHeaderBg',
] as const;
export type CustomPaletteToken = (typeof CUSTOM_PALETTE_TOKENS)[number];

type FamilyToken = 'bg' | 'bgSubtle' | 'bgInset' | 'surface' | 'surfaceRaised' | 'text' | 'textSecondary' | 'textTertiary' | 'codeBg' | 'codeHeaderBg';

/** JSON `custom.derivation` (see its `$steps` for a step-by-step description) */
export const CUSTOM_DERIVATION = {
  familyChroma: {
    bg: 0.014,
    bgSubtle: 0.015,
    bgInset: 0.016,
    surface: 0.017,
    surfaceRaised: 0.02,
    text: 0.008,
    textSecondary: 0.02,
    textTertiary: 0.02,
    codeBg: 0.012,
    codeHeaderBg: 0.016,
  } as Record<FamilyToken, number>,
  minChroma: 0.04,
  primaryLightness: [0.72, 0.88] as const,
  maxLightness: 0.96,
  lightenStep: 0.01,
  accent: { hueShift: 35, lightnessDelta: 0.05, chromaScale: 0.9, maxLightness: 0.9 },
  hover: { lightnessDelta: 0.07, chromaScale: 0.8, maxLightness: 0.94 },
  active: { lightnessDelta: 0.08 },
  onPrimary: { startLightness: 0.22, minLightness: 0.08, maxChroma: 0.06 },
  gamutStep: 0.004,
  adjustedNoticeDelta: 0.02,
  glowK: 1,
} as const;

/** JSON `custom.derivation.ladderFrom` = 'dark': the default dark background family and text (the lightness ladder is taken from here; equal to JSON palettes.dark). */
export const CUSTOM_LADDER: Record<FamilyToken, string> = {
  bg: '#111113',
  bgSubtle: '#151517',
  bgInset: '#19191C',
  surface: '#1C1C1F',
  surfaceRaised: '#27272B',
  text: '#EDEDEF',
  textSecondary: '#B3B3BA',
  textTertiary: '#8E8E96',
  codeBg: '#0B0B0D',
  codeHeaderBg: '#17171A',
};

/** JSON `contrastRules`: surfaces / minSecondaryOnSurfaces / minOnPrimary */
const CONTRAST_SURFACES: readonly FamilyToken[] = ['bg', 'surface', 'surfaceRaised'];
const MIN_SECONDARY_ON_SURFACES = 4.5;
const MIN_ON_PRIMARY = 4.5;

export type CustomPaletteAdjustment = null | 'lightened' | 'darkened';

export interface CustomPaletteDerivation {
  palette: Record<CustomPaletteToken, string>;
  /** JSON `custom.derivation.glowK` */
  glowK: number;
  /** Hint direction when the primary lightness change exceeds adjustedNoticeDelta (it does not block, the value is adjusted automatically) */
  adjusted: CustomPaletteAdjustment;
}

export type PaletteChoice =
  | { kind: 'preset'; id: DarkPaletteId }
  | { kind: 'custom'; seed: string };

const SEED_PATTERN = /^#[0-9A-Fa-f]{6}$/;

/** Accepts only `#RRGGBB` (either case) and returns it uppercased; anything else is null. */
export function parseSeed(value: unknown): string | null {
  return typeof value === 'string' && SEED_PATTERN.test(value) ? value.toUpperCase() : null;
}

/** Raw preference value to the palette to render: `custom` uses a valid seed (invalid / missing = default seed), anything else resolves as a preset id (unknown falls back to dark). */
export function resolvePaletteChoice(stored: unknown, seed: unknown): PaletteChoice {
  if (stored === CUSTOM_PALETTE_ID) return { kind: 'custom', seed: parseSeed(seed) ?? DEFAULT_CUSTOM_SEED };
  return { kind: 'preset', id: resolveDarkPaletteId(stored) };
}

/** Palette ids recognized when a locally stored value is pushed: the 7 presets + custom. */
export function isKnownPaletteChoiceId(value: unknown): value is DarkPaletteId | CustomPaletteId {
  return value === CUSTOM_PALETTE_ID || resolveDarkPaletteId(value) === value;
}

// ── Color math (ported from the contrast reference implementation) ──

type Rgb = [number, number, number];

function parseHex(hex: string): Rgb {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function channel(c: number): number {
  const s = c / 255;
  return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
}

function luminance(rgb: Rgb): number {
  return 0.2126 * channel(rgb[0]) + 0.7152 * channel(rgb[1]) + 0.0722 * channel(rgb[2]);
}

function contrast(a: string, b: string): number {
  const la = luminance(parseHex(a));
  const lb = luminance(parseHex(b));
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function fromLinear(x: number): number {
  const v = x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055;
  return v * 255;
}

const hex2 = (n: number) => n.toString(16).padStart(2, '0').toUpperCase();
function toHex(rgb: number[]): string {
  return `#${rgb.map((v) => hex2(Math.max(0, Math.min(255, Math.round(v))))).join('')}`;
}

/** sRGB hex → [L, C, H°] */
export function oklch(hex: string): [number, number, number] {
  const [r, g, b] = parseHex(hex).map(channel) as Rgb;
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
  const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
  return [L, Math.hypot(A, B), ((Math.atan2(B, A) * 180) / Math.PI + 360) % 360];
}

/** OKLCH to sRGB hex: when out of gamut, chroma is reduced step by step by gamutStep until it falls inside the gamut. */
export function fromOklch(L: number, C: number, H: number, gamutStep: number = CUSTOM_DERIVATION.gamutStep): string {
  const rad = (H * Math.PI) / 180;
  for (let i = 0; C - gamutStep * i >= 0; i += 1) {
    const c = C - gamutStep * i;
    const a = c * Math.cos(rad);
    const b = c * Math.sin(rad);
    const l = (L + 0.3963377774 * a + 0.2158037573 * b) ** 3;
    const m = (L - 0.1055613458 * a - 0.0638541728 * b) ** 3;
    const s = (L - 0.0894841775 * a - 1.291485548 * b) ** 3;
    const rgb = [
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
    ];
    if (rgb.every((v) => v >= -1e-4 && v <= 1 + 1e-4)) {
      return toHex(rgb.map((v) => fromLinear(Math.max(0, Math.min(1, v)))));
    }
  }
  return toHex([L, L, L].map((v) => fromLinear(Math.max(0, Math.min(1, v ** 3)))));
}

/** Hue slider value h (integer degrees) to seed color. */
export function hueSliderSeed(hue: number): string {
  return fromOklch(CUSTOM_HUE_SLIDER.lightness, CUSTOM_HUE_SLIDER.chroma, hue);
}

// ── User bubble stops (bubbleStops ported from the contrast reference implementation) ──

/** Number of stops (fixture derived.userBubble.stops). */
export const USER_BUBBLE_STOP_COUNT = 7;

/** The CSS variable that carries the stops: the value is comma-separated #RRGGBB (top to bottom), and --o-user-bubble-bg assembles them into a 180deg gradient in the default section. */
export const USER_BUBBLE_STOPS_CSS_VAR = '--o-user-bubble-stops';

/**
 * Interpolates between the two end colors in OKLCH (L and C linear, hue along the short arc) to take n stops, top to bottom;
 * when one end is near-gray (C < 0.02) the other end's hue is reused. The platform gradient interpolates in sRGB between adjacent stops.
 */
export function bubbleStops(topHex: string, bottomHex: string, n: number = USER_BUBBLE_STOP_COUNT): string[] {
  const a = oklch(topHex);
  const b = oklch(bottomHex);
  let ha = a[2];
  let hb = b[2];
  if (a[1] < 0.02) ha = hb;
  if (b[1] < 0.02) hb = ha;
  let dh = hb - ha;
  if (dh > 180) dh -= 360;
  if (dh < -180) dh += 360;
  const out: string[] = [];
  for (let i = 0; i < n; i += 1) {
    const t = n === 1 ? 0 : i / (n - 1);
    out.push(fromOklch(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, (ha + dh * t + 360) % 360));
  }
  return out;
}

const bubbleStopsCache = new Map<string, readonly string[]>();

/** Custom seed to dark bubble stops (accent to primary), cached by seed. */
export function customBubbleStops(seed: string): readonly string[] {
  const key = parseSeed(seed) ?? DEFAULT_CUSTOM_SEED;
  const cached = bubbleStopsCache.get(key);
  if (cached) return cached;
  const { accent, primary } = deriveCustom(key).palette;
  const result = Object.freeze(bubbleStops(accent, primary));
  bubbleStopsCache.set(key, result);
  return result;
}

// Called often during rendering (theme switches, first-frame cache, preview), so derived results are cached by seed
const derivationCache = new Map<string, CustomPaletteDerivation>();

/** Seed color to the full dark palette. An invalid seed is derived as the default seed. */
export function deriveCustom(seed: string): CustomPaletteDerivation {
  const key = parseSeed(seed) ?? DEFAULT_CUSTOM_SEED;
  const cached = derivationCache.get(key);
  if (cached) return cached;
  const result = computeCustom(key);
  derivationCache.set(key, result);
  return result;
}

function computeCustom(seed: string): CustomPaletteDerivation {
  const d = CUSTOM_DERIVATION;
  const [L0, C0, H] = oklch(seed);
  const C = Math.max(C0, d.minChroma);
  const family = {} as Record<FamilyToken, string>;
  for (const key of Object.keys(d.familyChroma) as FamilyToken[]) {
    family[key] = fromOklch(oklch(CUSTOM_LADDER[key])[0], d.familyChroma[key], H);
  }
  const minOnSurfaces = (hex: string) => Math.min(...CONTRAST_SURFACES.map((s) => contrast(hex, family[s])));

  // Primary: clamp lightness into the range; if it still fails the gate, brighten by the step (hue and chroma unchanged)
  const pBase = Math.min(d.primaryLightness[1], Math.max(d.primaryLightness[0], L0));
  let pL = pBase;
  let primary = pBase === L0 ? seed : fromOklch(pL, C, H);
  for (let i = 1; minOnSurfaces(primary) < MIN_SECONDARY_ON_SURFACES && pBase + d.lightenStep * i <= d.maxLightness; i += 1) {
    pL = pBase + d.lightenStep * i;
    primary = fromOklch(pL, C, H);
  }
  // Secondary: hue shifted, lightness slightly higher, chroma slightly lower; brightened if it fails the gate too
  const aBase = Math.min(d.accent.maxLightness, pL + d.accent.lightnessDelta);
  const aC = C * d.accent.chromaScale;
  const aH = (H + d.accent.hueShift) % 360;
  let accent = fromOklch(aBase, aC, aH);
  for (let i = 1; minOnSurfaces(accent) < MIN_SECONDARY_ON_SURFACES && aBase + d.lightenStep * i <= d.maxLightness; i += 1) {
    accent = fromOklch(aBase + d.lightenStep * i, aC, aH);
  }
  const primaryHover = fromOklch(Math.min(d.hover.maxLightness, pL + d.hover.lightnessDelta), C * d.hover.chromaScale, H);
  const actBase = pL - d.active.lightnessDelta;
  let primaryActive = fromOklch(actBase, C, H);

  // on-primary: a dark color of the same hue, pushed down from the starting lightness until it passes against all four backgrounds
  const onC = Math.min(C, d.onPrimary.maxChroma);
  const minOnP = (hex: string) => Math.min(...[primary, accent, primaryHover, primaryActive].map((b) => contrast(hex, b)));
  let onPrimary = fromOklch(d.onPrimary.startLightness, onC, H);
  for (let i = 1; minOnP(onPrimary) < MIN_ON_PRIMARY && d.onPrimary.startLightness - d.lightenStep * i >= d.onPrimary.minLightness; i += 1) {
    onPrimary = fromOklch(d.onPrimary.startLightness - d.lightenStep * i, onC, H);
  }
  // When the pressed state is so dark that on-primary fails the gate, lighten it back (not beyond the primary's lightness)
  for (let i = 1; contrast(onPrimary, primaryActive) < MIN_ON_PRIMARY && actBase + d.lightenStep * i <= pL; i += 1) {
    primaryActive = fromOklch(actBase + d.lightenStep * i, C, H);
  }
  const adjusted: CustomPaletteAdjustment = Math.abs(pL - L0) > d.adjustedNoticeDelta
    ? (pL > L0 ? 'lightened' : 'darkened')
    : null;
  return {
    palette: { ...family, primary, primaryHover, primaryActive, accent, onPrimary },
    glowK: d.glowK,
    adjusted,
  };
}

/** Field to CSS variable name (bgSubtle to --o-bg-subtle). */
export function customPaletteCssVarName(token: CustomPaletteToken | 'glowK'): string {
  return `--o-${token.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`;
}

/** Derived result to the same set of CSS variables as the preset palette sections in variables.css (15 colors + --o-glow-k + bubble stops); derived tokens follow through var() / color-mix in the default section. */
export function customPaletteCssVars(seed: string): Record<string, string> {
  const { palette, glowK } = deriveCustom(seed);
  const vars: Record<string, string> = {};
  for (const token of CUSTOM_PALETTE_TOKENS) vars[customPaletteCssVarName(token)] = palette[token];
  vars[customPaletteCssVarName('glowK')] = String(glowK);
  vars[USER_BUBBLE_STOPS_CSS_VAR] = customBubbleStops(seed).join(',');
  return vars;
}
