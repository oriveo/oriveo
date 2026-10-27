import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { act, render, renderHook } from '@testing-library/react';
import { useState } from 'react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DARK_PALETTE_IDS, customLightBrandCssVars, customPaletteCssVars, deriveCustom, deriveCustomLight, resolveDarkPaletteId } from '@oriveo/shared';
import { ThemeInitScript } from './ThemeInitScript';
import { applyDarkPalette, useDarkPalette, useTheme } from '../lib/hooks/useTheme';
import { setPreference } from '../lib/infra/storage/preferences';
import { THEME_COLOR_DARK_DEFAULT, THEME_COLOR_LIGHT } from '../lib/theme/theme-color';
import { CUSTOM_PALETTE_STYLE_ID, CUSTOM_PALETTE_VARS_CACHE_KEY } from '../lib/theme/custom-palette-style';

const REPO_ROOT = join(process.cwd(), '../../..');
const contract = JSON.parse(
  readFileSync(join(REPO_ROOT, 'shared/theme-contracts/dark-palettes.v1.json'), 'utf8'),
) as {
  defaultId: string;
  order: string[];
  palettes: Record<string, { bg: string }>;
  resolveCases: Array<{ name: string; stored: unknown; renders: string }>;
  custom: { defaultSeed: string; resolveCases: Array<{ name: string; stored: string; storedSeed: string | null; seed: string | null }> };
};

/** Take the inline script ThemeInitScript actually injects and run it (the same code as the production first frame). */
function runInitScript() {
  const { container, unmount } = render(<ThemeInitScript />);
  const code = container.querySelector('script')?.innerHTML ?? '';
  unmount();
  expect(code.length).toBeGreaterThan(0);
  new Function(code)();
}

function resetRoot() {
  delete document.documentElement.dataset.theme;
  delete document.documentElement.dataset.palette;
  document.getElementById(CUSTOM_PALETTE_STYLE_ID)?.remove();
  localStorage.clear();
}

beforeEach(resetRoot);
afterEach(resetRoot);

describe('dark palette id resolution', () => {
  it('the shared id table matches the JSON order', () => {
    expect([...DARK_PALETTE_IDS]).toEqual(contract.order);
  });

  it.each(contract.resolveCases)('unknown_or_missing_palette_resolves_default: $name', ({ stored, renders }) => {
    expect(resolveDarkPaletteId(stored)).toBe(renders);
    expect(applyDarkPalette(stored)).toBe(renders);
    expect(document.documentElement.dataset.palette).toBe(renders);
  });
});

describe('ThemeInitScript first-frame palette', () => {
  it('a valid darkPalette in preferences is written to data-palette', () => {
    localStorage.setItem('oriveo.guest.preferences', JSON.stringify({ theme: 'dark', darkPalette: 'dark-ocean' }));
    runInitScript();
    expect(document.documentElement.dataset.theme).toBe('dark');
    expect(document.documentElement.dataset.palette).toBe('dark-ocean');
  });

  it('the per-UID key wins and is read from the same JSON as theme', () => {
    localStorage.setItem('oriveo.guest.preferences', JSON.stringify({ theme: 'dark', darkPalette: 'dark-ocean' }));
    localStorage.setItem('oriveo.u1.preferences', JSON.stringify({ theme: 'light', darkPalette: 'dark-forest' }));
    runInitScript();
    expect(document.documentElement.dataset.theme).toBe('light');
    expect(document.documentElement.dataset.palette).toBe('dark-forest');
  });

  it.each([
    ['unknown id', 'dark-aurora-future'],
    ['non-string', 42],
    ['missing', undefined],
  ])('%s does not set data-palette and falls back to the default dark section', (_label, darkPalette) => {
    localStorage.setItem('oriveo.preferences', JSON.stringify({ theme: 'dark', darkPalette }));
    runInitScript();
    expect(document.documentElement.dataset.theme).toBe('dark');
    expect(document.documentElement.dataset.palette).toBeUndefined();
  });

  it('the first frame reads exactly the darkPalette field the production preference write path stores', () => {
    const known = contract.resolveCases.find((c) => c.name === 'known_id_applies')!;
    setPreference('preferences', { theme: 'dark', language: 'system', sendShortcut: 'enter', darkPalette: known.stored, darkPaletteSetByUser: true });
    runInitScript();
    expect(document.documentElement.dataset.palette).toBe(known.renders);
  });

  it('an unknown id stored by the production write path does not set data-palette', () => {
    const unknown = contract.resolveCases.find((c) => c.name === 'unknown_id_falls_back_without_write_back')!;
    setPreference('preferences', { theme: 'dark', language: 'system', sendShortcut: 'enter', darkPalette: unknown.stored, darkPaletteSetByUser: true });
    runInitScript();
    expect(document.documentElement.dataset.theme).toBe('dark');
    expect(document.documentElement.dataset.palette).toBeUndefined();
  });

  it('corrupted preferences JSON does not throw and the result is still the default dark', () => {
    localStorage.setItem('oriveo.preferences', '{not json');
    runInitScript();
    expect(document.documentElement.dataset.theme).toBe('dark');
    expect(document.documentElement.dataset.palette).toBeUndefined();
  });
});

describe('useDarkPalette follows the preference', () => {
  it('an unknown id renders dark, and switching to a known id switches over', () => {
    const { rerender } = renderHook(({ p }: { p: unknown }) => useDarkPalette(p), {
      initialProps: { p: 'dark-aurora-future' as unknown },
    });
    expect(document.documentElement.dataset.palette).toBe('dark');
    rerender({ p: 'dark-ocean' });
    expect(document.documentElement.dataset.palette).toBe('dark-ocean');
  });
});

describe('switching_palette_keeps_view_state', () => {
  function View() {
    const [text, setText] = useState('');
    return (
      <div>
        <input aria-label="draft" value={text} onChange={(e) => setText(e.target.value)} />
        <div data-testid="scroller" style={{ height: 40, overflow: 'auto' }}>
          <div style={{ height: 400 }} />
        </div>
      </div>
    );
  }

  it('after switching palettes the same view instance, input text and scroll position are unchanged, and colors become the new palette', () => {
    // Mount the real token file into the document so colors come from the cascade rather than from constants
    const style = document.createElement('style');
    style.textContent = readFileSync(join(REPO_ROOT, 'web/packages/ui/src/tokens/variables.css'), 'utf8');
    document.head.appendChild(style);
    try {
      document.documentElement.dataset.theme = 'dark';
      const { getByLabelText, getByTestId } = render(<View />);
      const input = getByLabelText('draft') as HTMLInputElement;
      const scroller = getByTestId('scroller');
      act(() => {
        input.focus();
      });
      input.value = 'draft text';
      input.dispatchEvent(new Event('input', { bubbles: true }));
      scroller.scrollTop = 120;
      const bgBefore = getComputedStyle(document.documentElement).getPropertyValue('--o-bg').trim();

      act(() => {
        applyDarkPalette('dark-ocean');
      });

      expect(getByLabelText('draft')).toBe(input);
      expect(getByTestId('scroller')).toBe(scroller);
      expect(input.value).toBe('draft text');
      expect(scroller.scrollTop).toBe(120);
      expect(document.documentElement.dataset.palette).toBe('dark-ocean');
      const bgAfter = getComputedStyle(document.documentElement).getPropertyValue('--o-bg').trim();
      expect(bgBefore.toUpperCase()).toBe(contract.palettes[contract.defaultId].bg.toUpperCase());
      expect(bgAfter.toUpperCase()).toBe(contract.palettes['dark-ocean'].bg.toUpperCase());
    } finally {
      style.remove();
    }
  });
});

describe('theme_color_follows_current_bg', () => {
  const CSS = readFileSync(join(REPO_ROOT, 'web/packages/ui/src/tokens/variables.css'), 'utf8');
  let meta: HTMLMetaElement;
  let style: HTMLStyleElement | null = null;

  beforeEach(() => {
    meta = document.createElement('meta');
    meta.name = 'theme-color';
    meta.content = THEME_COLOR_DARK_DEFAULT;
    document.head.appendChild(meta);
  });
  afterEach(() => {
    meta.remove();
    style?.remove();
    style = null;
  });
  const mountTokens = () => {
    style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);
  };
  const metaColor = () => (meta.getAttribute('content') ?? '').toUpperCase();

  it('the first-frame constants equal the JSON default dark bg and the light --o-bg in variables.css', () => {
    expect(THEME_COLOR_DARK_DEFAULT.toUpperCase()).toBe(contract.palettes[contract.defaultId].bg.toUpperCase());
    mountTokens();
    document.documentElement.dataset.theme = 'light';
    const lightBg = getComputedStyle(document.documentElement).getPropertyValue('--o-bg').trim();
    expect(THEME_COLOR_LIGHT.toUpperCase()).toBe(lightBg.toUpperCase());
  });

  it.each([
    ['stored light', { theme: 'light' }, THEME_COLOR_LIGHT],
    ['stored dark + palette', { theme: 'dark', darkPalette: 'dark-ocean' }, THEME_COLOR_DARK_DEFAULT],
    ['never set', null, THEME_COLOR_DARK_DEFAULT],
  ])('ThemeInitScript first frame: %s', (_label, prefs, expected) => {
    meta.content = '#000000';
    if (prefs) localStorage.setItem('oriveo.guest.preferences', JSON.stringify(prefs));
    runInitScript();
    expect(metaColor()).toBe(expected.toUpperCase());
  });

  it.each(contract.order)('after useTheme switches to %s, theme-color == that palette bg', (id) => {
    mountTokens();
    renderHook(() => useTheme('dark'));
    act(() => {
      applyDarkPalette(id);
    });
    expect(metaColor()).toBe(contract.palettes[id].bg.toUpperCase());
  });

  it('after useTheme switches back to light, theme-color == the light bg', () => {
    mountTokens();
    document.documentElement.dataset.palette = 'dark-ocean';
    const { rerender } = renderHook(({ t }: { t: 'light' | 'dark' }) => useTheme(t), { initialProps: { t: 'dark' } });
    expect(metaColor()).toBe(contract.palettes['dark-ocean'].bg.toUpperCase());
    rerender({ t: 'light' });
    expect(metaColor()).toBe(THEME_COLOR_LIGHT.toUpperCase());
  });
});

describe('custom palette rendering and first frame', () => {
  const CSS = readFileSync(join(REPO_ROOT, 'web/packages/ui/src/tokens/variables.css'), 'utf8');
  const withSeed = contract.custom.resolveCases.find((c) => c.name === 'custom_with_seed')!;
  const rootVar = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim().toUpperCase();
  let tokens: HTMLStyleElement;
  beforeEach(() => {
    tokens = document.createElement('style');
    tokens.textContent = CSS;
    document.head.appendChild(tokens);
  });
  afterEach(() => tokens.remove());

  it('applyDarkPalette(custom, seed): dark uses the derived values, light is unaffected, switching back to a preset removes the section', () => {
    document.documentElement.dataset.theme = 'dark';
    expect(applyDarkPalette(withSeed.stored, withSeed.storedSeed)).toBe('custom');
    const { palette } = deriveCustom(withSeed.seed!);
    expect(document.documentElement.dataset.palette).toBe('custom');
    expect(rootVar('--o-bg')).toBe(palette.bg);
    expect(rootVar('--o-primary')).toBe(palette.primary);
    expect(rootVar('--o-on-primary')).toBe(palette.onPrimary);
    // First-frame cache
    expect(JSON.parse(localStorage.getItem(CUSTOM_PALETTE_VARS_CACHE_KEY)!)).toEqual({
      seed: withSeed.seed,
      vars: customPaletteCssVars(withSeed.seed!),
      lightVars: customLightBrandCssVars(withSeed.seed!),
    });
    // Light: the neutral background is unchanged, and the brand-color family follows this seed's light derivation
    document.documentElement.dataset.theme = 'light';
    expect(rootVar('--o-bg')).toBe(THEME_COLOR_LIGHT.toUpperCase());
    const light = deriveCustomLight(withSeed.seed!);
    expect(rootVar('--o-primary')).toBe(light.ink);
    expect(rootVar('--o-primary-text-safe')).toBe(light.fillText);
    expect(rootVar('--o-brand-grad-start')).toBe(light.gradStart);
    document.documentElement.dataset.theme = 'dark';
    applyDarkPalette('dark-ocean');
    expect(document.getElementById(CUSTOM_PALETTE_STYLE_ID)).toBeNull();
    expect(rootVar('--o-bg')).toBe(contract.palettes['dark-ocean'].bg.toUpperCase());
  });

  it('an invalid / missing seed renders with the default seed', () => {
    document.documentElement.dataset.theme = 'dark';
    applyDarkPalette('custom', 'blue');
    expect(rootVar('--o-bg')).toBe(deriveCustom(contract.custom.defaultSeed).palette.bg);
  });

  it('ThemeInitScript: with custom and a matching cached seed the cache is applied (theme-color included)', () => {
    const meta = document.createElement('meta');
    meta.name = 'theme-color';
    document.head.appendChild(meta);
    try {
      document.documentElement.dataset.theme = 'dark';
      applyDarkPalette(withSeed.stored, withSeed.storedSeed);
      document.getElementById(CUSTOM_PALETTE_STYLE_ID)?.remove();
      delete document.documentElement.dataset.palette;
      setPreference('preferences', {
        theme: 'dark', language: 'system', sendShortcut: 'enter',
        darkPalette: withSeed.stored, darkPaletteSetByUser: true, darkPaletteCustom: withSeed.storedSeed!.toLowerCase(),
      });
      runInitScript();
      const { palette } = deriveCustom(withSeed.seed!);
      expect(document.documentElement.dataset.palette).toBe('custom');
      expect(rootVar('--o-bg')).toBe(palette.bg);
      expect(rootVar('--o-accent')).toBe(palette.accent);
      expect((meta.getAttribute('content') ?? '').toUpperCase()).toBe(palette.bg);
      document.documentElement.dataset.theme = 'light';
      expect(rootVar('--o-primary')).toBe(deriveCustomLight(withSeed.seed!).ink);
    } finally {
      meta.remove();
    }
  });

  it('ThemeInitScript: with no cache or a mismatched seed the default dark section applies first', () => {
    localStorage.setItem('oriveo.guest.preferences', JSON.stringify({ theme: 'dark', darkPalette: 'custom', darkPaletteCustom: '#C084FC' }));
    runInitScript();
    expect(document.documentElement.dataset.palette).toBeUndefined();
    expect(document.getElementById(CUSTOM_PALETTE_STYLE_ID)).toBeNull();
    localStorage.setItem(CUSTOM_PALETTE_VARS_CACHE_KEY, JSON.stringify({ seed: '#60A5FA', vars: customPaletteCssVars('#60A5FA'), lightVars: customLightBrandCssVars('#60A5FA') }));
    runInitScript();
    expect(document.documentElement.dataset.palette).toBeUndefined();
    expect(rootVar('--o-bg')).toBe(contract.palettes[contract.defaultId].bg.toUpperCase());
    // An old cache (no lightVars) is not applied even when the seed matches: a light section missing the brand variables would break the shared derivations
    localStorage.setItem(CUSTOM_PALETTE_VARS_CACHE_KEY, JSON.stringify({ seed: '#C084FC', vars: customPaletteCssVars('#C084FC') }));
    runInitScript();
    expect(document.documentElement.dataset.palette).toBeUndefined();
    expect(document.getElementById(CUSTOM_PALETTE_STYLE_ID)).toBeNull();
  });

  it('ThemeInitScript: invalid variable names / values in the cache are not spliced into the style', () => {
    localStorage.setItem('oriveo.guest.preferences', JSON.stringify({ theme: 'dark', darkPalette: 'custom' }));
    localStorage.setItem(CUSTOM_PALETTE_VARS_CACHE_KEY, JSON.stringify({
      seed: contract.custom.defaultSeed,
      vars: { '--o-bg': '#123456', '--o-text': 'red}body{x:1', 'color': '#FFFFFF' },
      lightVars: { '--o-primary': '#654321', '--o-brand-accent': 'url(x)', '--O-X': '#FFFFFF' },
    }));
    runInitScript();
    expect(document.getElementById(CUSTOM_PALETTE_STYLE_ID)?.textContent).toBe(
      "[data-theme='dark'][data-palette='custom']{--o-bg:#123456;}[data-theme='light'][data-palette='custom']{--o-primary:#654321;}",
    );
  });

  it('light preset palettes: brand-color family == fixture light.palettes, and the default palette keeps its hand-tuned section', () => {
    const lightJson = (contract as unknown as { light: { palettes: Record<string, Record<string, string>> } }).light.palettes;
    document.documentElement.dataset.theme = 'light';
    applyDarkPalette('dark-ocean');
    expect(rootVar('--o-primary')).toBe(lightJson['dark-ocean'].ink);
    expect(rootVar('--o-primary-text')).toBe(lightJson['dark-ocean'].onPrimary);
    expect(rootVar('--o-bg')).toBe(THEME_COLOR_LIGHT.toUpperCase());
    applyDarkPalette('dark');
    expect(rootVar('--o-primary')).toBe('#8B5CF6');
  });
});
