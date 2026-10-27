import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { ThemeOption } from '@oriveo/shared';
import {
  selectedSwatch,
  themePageWrites,
  themeRowSummary,
  type SystemAppearance,
  type ThemePageAction,
} from './theme-page-rules';

interface ThemePageCase {
  name: string;
  before: { theme: ThemeOption; follow: boolean; darkPalette: string; systemAppearance?: SystemAppearance };
  tap?: string;
  toggleFollow?: boolean;
  after: { theme: ThemeOption; darkPalette: string };
}

const contract = JSON.parse(
  readFileSync(join(process.cwd(), '../../..', 'shared/theme-contracts/dark-palettes.v1.json'), 'utf8'),
) as { themePageCases: ThemePageCase[] };

function runCase(name: string) {
  const c = contract.themePageCases.find((item) => item.name === name);
  expect(c, `themePageCases.${name}`).toBeDefined();
  const { before, after } = c!;
  expect(before.follow).toBe(before.theme === 'system');
  const action: ThemePageAction =
    c!.toggleFollow !== undefined
      ? { kind: 'toggleFollow', on: c!.toggleFollow }
      : { kind: 'tap', swatch: c!.tap as 'light' };
  // A case that gives no system appearance is appearance-independent: both appearances must produce the same result
  const appearances: SystemAppearance[] = before.systemAppearance ? [before.systemAppearance] : ['light', 'dark'];
  for (const appearance of appearances) {
    const writes = themePageWrites({ theme: before.theme, darkPalette: before.darkPalette }, action, appearance);
    expect({ theme: before.theme, darkPalette: before.darkPalette, ...writes }).toEqual(after);
  }
}

describe('themePageCases (theme page interaction cases)', () => {
  it('tap_light', () => runCase('tap_light'));
  it('tap_palette_follow_off', () => runCase('tap_palette_follow_off'));
  it('tap_palette_follow_on', () => runCase('tap_palette_follow_on'));
  it('turn_follow_on', () => runCase('turn_follow_on'));
  it('turn_follow_off_uses_current_system_appearance', () => runCase('turn_follow_off_uses_current_system_appearance'));

  it('covers all 5 cases in the JSON', () => {
    expect(contract.themePageCases.map((c) => c.name).sort()).toEqual([
      'tap_light',
      'tap_palette_follow_off',
      'tap_palette_follow_on',
      'turn_follow_off_uses_current_system_appearance',
      'turn_follow_on',
    ]);
  });

  it('tapping Light does not write darkPalette; tapping "Dark" itself also counts as an explicit choice', () => {
    expect(themePageWrites({ theme: 'dark', darkPalette: undefined }, { kind: 'tap', swatch: 'light' }, 'dark'))
      .toEqual({ theme: 'light' });
    expect(themePageWrites({ theme: 'dark', darkPalette: undefined }, { kind: 'tap', swatch: 'dark' }, 'light'))
      .toEqual({ darkPalette: 'dark' });
  });
});

describe('selectedSwatch (selected display)', () => {
  it('follow system on: the ring is on resolve(darkPalette), Light is not selected', () => {
    expect(selectedSwatch('system', 'dark-ocean')).toBe('dark-ocean');
    expect(selectedSwatch('system', undefined)).toBe('dark');
    expect(selectedSwatch('system', 'dark-aurora-future')).toBe('dark');
  });

  it('follow system off: theme=light selects Light, theme=dark selects resolve(darkPalette)', () => {
    expect(selectedSwatch('light', 'dark-ocean')).toBe('light');
    expect(selectedSwatch('dark', 'dark-forest')).toBe('dark-forest');
    expect(selectedSwatch('dark', 42)).toBe('dark');
  });
});

describe('themeRowSummary (settings theme row summary)', () => {
  const t = (key: string, values?: Record<string, string>) =>
    values ? `${key}(${JSON.stringify(values)})` : key;

  it('light -> Light', () => {
    expect(themeRowSummary('light', 'dark-ocean', t)).toBe('themeLight');
  });

  it('dark -> palette name, the default palette shows "Dark"', () => {
    expect(themeRowSummary('dark', 'dark-sunset', t)).toBe('themePaletteSunset');
    expect(themeRowSummary('dark', undefined, t)).toBe('themeDark');
    expect(themeRowSummary('dark', 'dark-aurora-future', t)).toBe('themeDark');
  });

  it('system -> Follow System · <palette name>', () => {
    expect(themeRowSummary('system', 'dark-graphite', t)).toBe(
      'themeSummaryFollowSystem({"palette":"themePaletteGraphite"})',
    );
  });
});
