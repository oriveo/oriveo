import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  CUSTOM_DERIVATION,
  CUSTOM_HUE_SLIDER,
  CUSTOM_LADDER,
  CUSTOM_PALETTE_ID,
  CUSTOM_PALETTE_TOKENS,
  CUSTOM_PRESETS,
  DEFAULT_CUSTOM_SEED,
  customPaletteCssVars,
  deriveCustom,
  hueSliderSeed,
  isKnownPaletteChoiceId,
  parseSeed,
  resolvePaletteChoice,
} from './custom-palette';

/**
 * Custom palette: reads the custom section of the shared fixture dark-palettes.v1.json at run time;
 * derivationCases match field by field and channel by channel with |difference| <= 1, and the hue slider matches values computed with the reference implementation.
 */
const REPO_ROOT = resolve(__dirname, '../../../../..');
const JSON_PATH = resolve(REPO_ROOT, 'shared/theme-contracts/dark-palettes.v1.json');

interface CustomJson {
  id: string;
  defaultSeed: string;
  presets: string[];
  hueSlider: { lightness: number; chroma: number; min: number; max: number };
  derivation: Record<string, unknown> & { ladderFrom: string };
  derivationCases: { seed: string; expect: Record<string, string>; adjusted: string | null }[];
  resolveCases: {
    name: string;
    stored: unknown;
    storedSeed: unknown;
    renders: string;
    seed: string | null;
    pushToCloud: boolean;
    pushSeed: boolean;
  }[];
}
const json = JSON.parse(readFileSync(JSON_PATH, 'utf8')) as {
  palettes: Record<string, Record<string, string | number>>;
  contrastRules: { surfaces: string[]; minSecondaryOnSurfaces: number; minOnPrimary: number };
  resolveCases: { name: string; stored: unknown; renders: string }[];
  custom: CustomJson;
};
const custom = json.custom;

const channels = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

describe('custom parameters == JSON', () => {
  it('id / defaultSeed / presets / hueSlider', () => {
    expect(CUSTOM_PALETTE_ID).toBe(custom.id);
    expect(DEFAULT_CUSTOM_SEED).toBe(custom.defaultSeed);
    expect([...CUSTOM_PRESETS]).toEqual(custom.presets);
    expect({ ...CUSTOM_HUE_SLIDER }).toEqual(
      Object.fromEntries(Object.entries(custom.hueSlider).filter(([k]) => !k.startsWith('$'))),
    );
  });

  it('derivation parameters are equal item by item, and the ladder == palettes[ladderFrom]', () => {
    const { $steps: _steps, ladderFrom, ...params } = custom.derivation;
    expect(JSON.parse(JSON.stringify(CUSTOM_DERIVATION))).toEqual(params);
    for (const [key, hex] of Object.entries(CUSTOM_LADDER)) {
      expect(hex.toUpperCase(), key).toBe(String(json.palettes[ladderFrom][key]).toUpperCase());
    }
    expect(json.contrastRules).toMatchObject({ surfaces: ['bg', 'surface', 'surfaceRaised'], minSecondaryOnSurfaces: 4.5, minOnPrimary: 4.5 });
  });
});

describe('deriveCustom == derivationCases', () => {
  expect(custom.derivationCases.length).toBeGreaterThan(0);

  it.each(custom.derivationCases.map((c) => [c.seed, c] as const))('%s', (_seed, c) => {
    const { palette, adjusted, glowK } = deriveCustom(c.seed);
    expect(Object.keys(c.expect).sort()).toEqual([...CUSTOM_PALETTE_TOKENS].sort());
    for (const token of CUSTOM_PALETTE_TOKENS) {
      const actual = channels(palette[token]);
      const expected = channels(c.expect[token]);
      for (let i = 0; i < 3; i++) {
        expect(Math.abs(actual[i] - expected[i]), `${c.seed}.${token}[${i}] ${palette[token]} vs ${c.expect[token]}`).toBeLessThanOrEqual(1);
      }
    }
    expect(adjusted).toBe(c.adjusted);
    expect(glowK).toBe(custom.derivation.glowK);
  });

  it('cached by seed: the same seed (different letter case) returns the same object; an invalid seed = the default seed', () => {
    expect(deriveCustom('#c084fc')).toBe(deriveCustom('#C084FC'));
    expect(deriveCustom('blue')).toBe(deriveCustom(DEFAULT_CUSTOM_SEED));
  });

  it('CSS variables: 15 colors + --o-glow-k + --o-user-bubble-stops', () => {
    const vars = customPaletteCssVars(custom.derivationCases[0].seed);
    expect(Object.keys(vars)).toHaveLength(17);
    expect(vars['--o-bg-subtle']).toBe(deriveCustom(custom.derivationCases[0].seed).palette.bgSubtle);
    expect(vars['--o-glow-k']).toBe(String(custom.derivation.glowK));
  });
});

describe('hueSliderSeed == reference values', () => {
  // Values computed once with the reference implementation (OKLCH lightness 0.78, chroma 0.14, gamut-clamped)
  const reference = ['#FF8FB4', '#07D0D8', '#FF8FB5'];

  it.each([[0, 0], [200, 1], [359, 2]])('h = %i', (hue, index) => {
    expect(hueSliderSeed(hue)).toBe(reference[index]);
  });
});

describe('parseSeed / resolvePaletteChoice', () => {
  it('parseSeed accepts only #RRGGBB and returns it uppercased', () => {
    expect(parseSeed('#c084fc')).toBe('#C084FC');
    for (const bad of ['blue', '#FFF', 'C084FC', '#C084FC00', 42, null, undefined]) expect(parseSeed(bad)).toBeNull();
  });

  it.each(custom.resolveCases.map((c) => [c.name, c] as const))('custom.resolveCases: %s', (_name, c) => {
    const choice = resolvePaletteChoice(c.stored, c.storedSeed);
    if (c.renders === CUSTOM_PALETTE_ID) {
      expect(choice).toEqual({ kind: 'custom', seed: c.seed });
    } else {
      expect(choice).toEqual({ kind: 'preset', id: c.renders });
      expect(c.seed).toBeNull();
    }
    expect(isKnownPaletteChoiceId(c.stored)).toBe(c.pushToCloud);
    expect(parseSeed(c.storedSeed) !== null).toBe(c.pushSeed);
  });

  it.each(json.resolveCases.map((c) => [c.name, c] as const))('top-level resolveCases: %s', (_name, c) => {
    expect(resolvePaletteChoice(c.stored, null)).toEqual({ kind: 'preset', id: c.renders });
  });
});
