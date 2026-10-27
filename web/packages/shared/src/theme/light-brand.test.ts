import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { DEFAULT_CUSTOM_SEED } from './custom-palette';
import {
  LIGHT_BRAND_CSS_VARS,
  LIGHT_BRAND_PRESETS,
  LIGHT_BRAND_TOKENS,
  LIGHT_DERIVATION,
  customLightBrandCssVars,
  deriveCustomLight,
  deriveLight,
  lightBrandColors,
  lightBrandFor,
} from './light-brand';

/**
 * Light brand colors: reads the light section of the shared fixture dark-palettes.v1.json and custom.derivationCases[].light at run time,
 * field by field and channel by channel with |difference| <= 1.
 */
const REPO_ROOT = resolve(__dirname, '../../../../..');
const JSON_PATH = resolve(REPO_ROOT, 'shared/theme-contracts/dark-palettes.v1.json');

type LightJson = Record<string, string>;
const json = JSON.parse(readFileSync(JSON_PATH, 'utf8')) as {
  defaultId: string;
  order: string[];
  palettes: Record<string, Record<string, string | number>>;
  light: { derivation: Record<string, unknown>; palettes: Record<string, LightJson> };
  custom: { derivationCases: { seed: string; light: LightJson }[] };
};

const channels = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

function expectClose(actual: Record<string, string>, expected: LightJson, label: string) {
  expect(Object.keys(expected).filter((k) => k !== 'mode').sort(), label).toEqual([...LIGHT_BRAND_TOKENS].sort());
  for (const token of LIGHT_BRAND_TOKENS) {
    const a = channels(actual[token]);
    const e = channels(expected[token]);
    for (let i = 0; i < 3; i++) {
      expect(Math.abs(a[i] - e[i]), `${label}.${token}[${i}] ${actual[token]} vs ${expected[token]}`).toBeLessThanOrEqual(1);
    }
  }
  expect(actual.mode, `${label}.mode`).toBe(expected.mode);
}

describe('light parameters == JSON', () => {
  it('derivation parameters are equal item by item', () => {
    const { $steps: _steps, $minInkText: _note, ...params } = json.light.derivation;
    expect(JSON.parse(JSON.stringify(LIGHT_DERIVATION))).toEqual(params);
  });

  it('LIGHT_BRAND_PRESETS == light.palettes value for value (7 palettes, keys match order)', () => {
    expect(Object.keys(LIGHT_BRAND_PRESETS).sort()).toEqual([...json.order].sort());
    for (const id of json.order) expect(LIGHT_BRAND_PRESETS[id as keyof typeof LIGHT_BRAND_PRESETS], id).toEqual(json.light.palettes[id]);
  });
});

describe('deriveLight == light.palettes (the 6 non-default palettes are derived from the dark palettes)', () => {
  it.each(json.order.filter((id) => id !== json.defaultId))('%s', (id) => {
    const p = json.palettes[id];
    const out = deriveLight({ primary: String(p.primary), accent: String(p.accent), onPrimary: String(p.onPrimary) });
    expectClose(out, json.light.palettes[id], id);
  });
});

describe('deriveCustomLight == custom.derivationCases[].light', () => {
  expect(json.custom.derivationCases.length).toBeGreaterThan(0);

  it.each(json.custom.derivationCases.map((c) => [c.seed, c] as const))('%s', (seed, c) => {
    expectClose(deriveCustomLight(seed), c.light, seed);
  });

  it('cached by seed: different letter case returns the same object; an invalid seed = the default seed', () => {
    expect(deriveCustomLight('#c084fc')).toBe(deriveCustomLight('#C084FC'));
    expect(deriveCustomLight('blue')).toBe(deriveCustomLight(DEFAULT_CUSTOM_SEED));
  });
});

describe('lightBrandFor / lightBrandColors / CSS variables', () => {
  it('the default palette returns null (it uses the CSS default section), and lightBrandColors falls back to the hand-tuned defaults', () => {
    expect(lightBrandFor({ kind: 'preset', id: 'dark' })).toBeNull();
    expect(lightBrandColors({ kind: 'preset', id: 'dark' })).toEqual(json.light.palettes.dark);
  });

  it('a preset returns the fixture value and custom returns the seed derivation', () => {
    expect(lightBrandFor({ kind: 'preset', id: 'dark-ocean' })).toEqual(json.light.palettes['dark-ocean']);
    const c = json.custom.derivationCases[0];
    expect(lightBrandFor({ kind: 'custom', seed: c.seed })).toBe(deriveCustomLight(c.seed));
  });

  it('custom light CSS variables: one entry per mapping + bubble stops, with values from the derivation', () => {
    const c = json.custom.derivationCases[0];
    const vars = customLightBrandCssVars(c.seed);
    expect(Object.keys(vars)).toEqual([...LIGHT_BRAND_CSS_VARS.map(([, name]) => name), '--o-user-bubble-stops']);
    const brand = deriveCustomLight(c.seed);
    for (const [token, name] of LIGHT_BRAND_CSS_VARS) expect(vars[name], name).toBe(brand[token]);
  });
});
