import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { ThemeOption } from '@oriveo/shared';
import {
  APPEARANCE_SEGMENTS,
  CUSTOM_PRESET_DOTS,
  PALETTE_CARDS,
  appearancePageWrites,
  cardLabelKey,
  selectedCard,
  themeRowSummary,
  type AppearancePageAction,
  type PaletteCardId,
} from './theme-page-rules';

interface PageState {
  theme: ThemeOption;
  darkPalette: string;
  seed: string | null;
}

interface AppearancePageCase {
  name: string;
  before: PageState;
  segment?: ThemeOption;
  tap?: string;
  pickSeed?: string;
  after: PageState;
}

const contract = JSON.parse(
  readFileSync(join(process.cwd(), '../../..', 'shared/theme-contracts/dark-palettes.v1.json'), 'utf8'),
) as {
  order: string[];
  appearancePageCases: AppearancePageCase[];
  custom: { defaultSeed: string; presets: string[] };
};

/** Same persistence semantics as updateTheme / updateDarkPalette: writing custom also writes the seed, writing a preset leaves the seed alone. */
function runCase(name: string) {
  const c = contract.appearancePageCases.find((item) => item.name === name);
  expect(c, `appearancePageCases.${name}`).toBeDefined();
  const { before, after } = c!;
  const action: AppearancePageAction =
    c!.segment !== undefined
      ? { kind: 'setAppearance', theme: c!.segment }
      : c!.pickSeed !== undefined
        ? { kind: 'pickSeed', seed: c!.pickSeed }
        : { kind: 'tap', card: c!.tap as PaletteCardId };
  const writes = appearancePageWrites(before, action);
  const next: PageState = { ...before };
  if (writes.theme !== undefined) next.theme = writes.theme;
  if (writes.palette?.kind === 'preset') next.darkPalette = writes.palette.id;
  if (writes.palette?.kind === 'custom') {
    next.darkPalette = 'custom';
    next.seed = writes.palette.seed;
  }
  expect(next).toEqual(after);
  // Selection ring = resolve(darkPalette), independent of appearance
  expect(selectedCard(next.darkPalette, next.seed)).toBe(after.darkPalette);
}

const TESTED_CASES = [
  'segment_light',
  'segment_dark',
  'segment_system',
  'tap_palette_keeps_appearance_light',
  'tap_palette_keeps_appearance_system',
  'tap_default_card',
  'tap_custom_without_seed_writes_default_seed',
  'tap_custom_keeps_existing_seed',
  'pick_seed_selects_custom',
  'tap_preset_keeps_seed',
];

describe('appearancePageCases (theme page interaction cases)', () => {
  it('segment_light', () => runCase('segment_light'));
  it('segment_dark', () => runCase('segment_dark'));
  it('segment_system', () => runCase('segment_system'));
  it('tap_palette_keeps_appearance_light', () => runCase('tap_palette_keeps_appearance_light'));
  it('tap_palette_keeps_appearance_system', () => runCase('tap_palette_keeps_appearance_system'));
  it('tap_default_card', () => runCase('tap_default_card'));
  it('tap_custom_without_seed_writes_default_seed', () => runCase('tap_custom_without_seed_writes_default_seed'));
  it('tap_custom_keeps_existing_seed', () => runCase('tap_custom_keeps_existing_seed'));
  it('pick_seed_selects_custom', () => runCase('pick_seed_selects_custom'));
  it('tap_preset_keeps_seed', () => runCase('tap_preset_keeps_seed'));

  it('every case in the JSON has a matching test', () => {
    expect(contract.appearancePageCases.map((c) => c.name).sort()).toEqual([...TESTED_CASES].sort());
  });

  it('the appearance segment only writes theme; an unchanged value is not written; an invalid seed is not written', () => {
    expect(appearancePageWrites({ theme: 'dark', darkPalette: 'dark-ocean', seed: null }, { kind: 'setAppearance', theme: 'dark' })).toEqual({});
    expect(appearancePageWrites({ theme: 'dark', darkPalette: 'dark', seed: null }, { kind: 'pickSeed', seed: 'red' })).toEqual({});
    expect(appearancePageWrites({ theme: 'dark', darkPalette: 'custom', seed: 'bogus' }, { kind: 'tap', card: 'custom' }))
      .toEqual({ palette: { kind: 'custom', seed: contract.custom.defaultSeed } });
  });
});

describe('cards and color picker', () => {
  it('8 cards: contract order + custom, first card is the default (dark)', () => {
    expect([...PALETTE_CARDS]).toEqual([...contract.order, 'custom']);
    expect(cardLabelKey('dark')).toBe('themePaletteDefault');
    expect(cardLabelKey('custom')).toBe('themePaletteCustom');
    expect([...APPEARANCE_SEGMENTS]).toEqual(['light', 'dark', 'system']);
  });

  it('selected card: an unknown id falls back to the default, custom selects the custom card regardless of seed', () => {
    expect(selectedCard(undefined, null)).toBe('dark');
    expect(selectedCard('dark-aurora-future', null)).toBe('dark');
    expect(selectedCard('custom', null)).toBe('custom');
    expect(selectedCard('dark-forest', '#4ADE80')).toBe('dark-forest');
  });

  it('preset dots follow custom.presets, each with a color-name key', () => {
    expect(CUSTOM_PRESET_DOTS.map((dot) => dot.seed)).toEqual(contract.custom.presets);
    expect(new Set(CUSTOM_PRESET_DOTS.map((dot) => dot.labelKey)).size).toBe(12);
  });
});

describe('themeRowSummary (theme row summary on the Settings home)', () => {
  const t = (key: string, values?: Record<string, string>) =>
    values ? `${key}(${JSON.stringify(values)})` : key;

  it('the default palette shows only the appearance name', () => {
    expect(themeRowSummary('light', 'dark', t)).toBe('themeLight');
    expect(themeRowSummary('dark', undefined, t)).toBe('themeDark');
    expect(themeRowSummary('system', 'dark-aurora-future', t)).toBe('themeSystem');
  });

  it('other palettes: <appearance> · <palette name>', () => {
    expect(themeRowSummary('light', 'dark-ocean', t)).toBe('themeSummaryLight({"palette":"themePaletteOcean"})');
    expect(themeRowSummary('dark', 'dark-sunset', t)).toBe('themeSummaryDark({"palette":"themePaletteSunset"})');
    expect(themeRowSummary('system', 'custom', t)).toBe('themeSummaryFollowSystem({"palette":"themePaletteCustom"})');
  });
});
