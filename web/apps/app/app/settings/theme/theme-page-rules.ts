import {
  CUSTOM_PALETTE_ID,
  CUSTOM_PRESETS,
  DARK_PALETTE_IDS,
  DEFAULT_CUSTOM_SEED,
  parseSeed,
  resolvePaletteChoice,
} from '@oriveo/shared';
import type { CustomPaletteId, DarkPaletteId, PaletteChoice, ThemeOption } from '@oriveo/shared';

/**
 * Theme page rules. Pure functions only; the cases live in
 * shared/theme-contracts/dark-palettes.v1.json `appearancePageCases`.
 * Appearance (light / dark / system) and palette are independent: the segment only writes `theme`,
 * a card only writes `darkPalette` (+ `darkPaletteCustom` for the custom card).
 */

/** A palette card: the 7 presets ("dark" = the default card) and the custom card. */
export type PaletteCardId = DarkPaletteId | CustomPaletteId;

/** Card order: Default, Purple, Graphite, Black, Ocean, Forest, Sunset, Custom. */
export const PALETTE_CARDS: readonly PaletteCardId[] = [...DARK_PALETTE_IDS, CUSTOM_PALETTE_ID];

/** Appearance segments in display order. */
export const APPEARANCE_SEGMENTS: readonly ThemeOption[] = ['light', 'dark', 'system'];

export type AppearancePageAction =
  | { kind: 'setAppearance'; theme: ThemeOption }
  | { kind: 'tap'; card: PaletteCardId }
  /** A preset dot or a released hue slider. */
  | { kind: 'pickSeed'; seed: string };

export interface AppearancePageState {
  theme: ThemeOption;
  /** Raw stored values; may be unset or invalid. */
  darkPalette: unknown;
  seed: unknown;
}

/** Fields the page writes back; absent field = untouched. `palette` goes through updateDarkPalette. */
export interface AppearancePageWrites {
  theme?: ThemeOption;
  palette?: PaletteChoice;
}

/** Applies one user action and returns the preference fields to write. */
export function appearancePageWrites(state: AppearancePageState, action: AppearancePageAction): AppearancePageWrites {
  if (action.kind === 'setAppearance') return action.theme === state.theme ? {} : { theme: action.theme };
  if (action.kind === 'pickSeed') {
    const seed = parseSeed(action.seed);
    return seed ? { palette: { kind: 'custom', seed } } : {};
  }
  if (action.card === CUSTOM_PALETTE_ID) {
    // A seed picked earlier survives other palettes; never picked → the contract default seed.
    return { palette: { kind: 'custom', seed: parseSeed(state.seed) ?? DEFAULT_CUSTOM_SEED } };
  }
  return { palette: { kind: 'preset', id: action.card } };
}

/** Card carrying the selection ring in every appearance: resolve(darkPalette). */
export function selectedCard(darkPalette: unknown, seed: unknown): PaletteCardId {
  const choice = resolvePaletteChoice(darkPalette, seed);
  return choice.kind === 'custom' ? CUSTOM_PALETTE_ID : choice.id;
}

const CARD_LABEL_KEYS: Record<PaletteCardId, string> = {
  dark: 'themePaletteDefault',
  'dark-purple': 'themePalettePurple',
  'dark-graphite': 'themePaletteGraphite',
  'dark-black': 'themePaletteBlack',
  'dark-ocean': 'themePaletteOcean',
  'dark-forest': 'themePaletteForest',
  'dark-sunset': 'themePaletteSunset',
  custom: 'themePaletteCustom',
};

/** `pages.settings` key of a card name. */
export function cardLabelKey(card: PaletteCardId): string {
  return CARD_LABEL_KEYS[card];
}

const APPEARANCE_LABEL_KEYS: Record<ThemeOption, string> = {
  light: 'themeLight',
  dark: 'themeDark',
  system: 'themeSystem',
};

/** `pages.settings` key of an appearance segment. */
export function appearanceLabelKey(theme: ThemeOption): string {
  return APPEARANCE_LABEL_KEYS[theme];
}

const PRESET_COLOR_KEYS = [
  'themeColorCoral',
  'themeColorOrange',
  'themeColorAmber',
  'themeColorLime',
  'themeColorGreen',
  'themeColorTeal',
  'themeColorCyan',
  'themeColorBlue',
  'themeColorIndigo',
  'themeColorViolet',
  'themeColorPink',
  'themeColorRose',
] as const;

/** Custom palette preset dots in contract order, each with its accessible name key. */
export const CUSTOM_PRESET_DOTS: ReadonlyArray<{ seed: string; labelKey: string }> = CUSTOM_PRESETS.map((seed, index) => ({
  seed,
  labelKey: PRESET_COLOR_KEYS[index]!,
}));

const SUMMARY_KEYS: Record<ThemeOption, string> = {
  light: 'themeSummaryLight',
  dark: 'themeSummaryDark',
  system: 'themeSummaryFollowSystem',
};

type Translate = (key: string, values?: Record<string, string>) => string;

/** Trailing summary of the Settings › Theme row: default palette → appearance only; others → "<appearance> · <palette>". */
export function themeRowSummary(theme: ThemeOption, darkPalette: unknown, t: Translate): string {
  const card = selectedCard(darkPalette, undefined);
  if (card === 'dark') return t(appearanceLabelKey(theme));
  return t(SUMMARY_KEYS[theme], { palette: t(cardLabelKey(card)) });
}
