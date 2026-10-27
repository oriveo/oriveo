import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { useStore } from 'zustand';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_CUSTOM_SEED, deriveCustom, deriveCustomLight, hueSliderSeed } from '@oriveo/shared';
import { createAppStore, type AppStore } from '../../../lib/core/store/app-store';
import { useDarkPalette, useTheme } from '../../../lib/hooks/useTheme';
import { ThemeSettings } from './ThemeSettings';

const holder = vi.hoisted(() => ({
  store: null as unknown as ReturnType<typeof import('../../../lib/core/store/app-store').createAppStore>,
  systemDark: false,
  routerPush: vi.fn(),
}));

// The translate function must be stable; with parameters it appends them so assertions can verify template filling
const translate = (key: string, values?: Record<string, string>) =>
  values ? `${key}(${Object.values(values).join(',')})` : key;
vi.mock('next-intl', () => ({ useTranslations: () => translate, useLocale: () => 'en' }));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: holder.routerPush }) }));
vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: <T,>(selector: (state: AppStore) => T) => useStore(holder.store, selector),
  getVanillaStore: () => holder.store,
}));

/** Same as StoreProvider's ThemeSyncer: preferences -> <html data-theme / data-palette>. */
function ThemeSyncerHarness() {
  const theme = useStore(holder.store, (s) => s.preferences.theme);
  const darkPalette = useStore(holder.store, (s) => s.preferences.darkPalette);
  const darkPaletteCustom = useStore(holder.store, (s) => s.preferences.darkPaletteCustom);
  useTheme(theme);
  useDarkPalette(darkPalette, darkPaletteCustom);
  return null;
}

function renderPage() {
  return render(
    <>
      <ThemeSyncerHarness />
      <ThemeSettings />
    </>,
  );
}

function setPrefs(patch: Partial<AppStore['preferences']>) {
  holder.store.getState().setPreferences(patch);
}

const swatch = (name: string) => screen.getByRole('button', { name });
const segment = (name: string) => screen.getByRole('radio', { name });
const prefs = () => holder.store.getState().preferences;
const cardOrder = () => Array.from(document.querySelectorAll('[data-swatch]')).map((b) => b.getAttribute('data-swatch'));
const html = () => document.documentElement.dataset;

beforeEach(() => {
  holder.store = createAppStore();
  holder.systemDark = false;
  holder.routerPush.mockReset();
  vi.stubGlobal('matchMedia', (query: string) => ({
    matches: query.includes('dark') ? holder.systemDark : false,
    media: query,
    addEventListener: () => {},
    removeEventListener: () => {},
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  delete document.documentElement.dataset.theme;
  delete document.documentElement.dataset.palette;
});

describe('ThemeSettings (Settings > Theme)', () => {
  it('8 palette cards: default first in a fixed order, aria-pressed marks the selection, cascading in place by the current appearance', () => {
    setPrefs({ theme: 'dark', darkPalette: 'dark-ocean' });
    renderPage();
    expect(cardOrder()).toEqual([
      'dark', 'dark-purple', 'dark-graphite', 'dark-black', 'dark-ocean', 'dark-forest', 'dark-sunset', 'custom',
    ]);
    expect(document.querySelector('[data-swatch]')!.getAttribute('aria-label')).toBe('themePaletteDefault');
    expect(swatch('themePaletteOcean').getAttribute('aria-pressed')).toBe('true');
    expect(screen.getAllByRole('button', { pressed: true })).toHaveLength(1);
    expect(swatch('themePaletteOcean').querySelector('[data-palette="dark-ocean"][data-theme="dark"]')).not.toBeNull();
    const preview = screen.getByTestId('theme-preview');
    expect(preview.dataset.theme).toBe('dark');
    expect(preview.dataset.palette).toBe('dark-ocean');
    // The light card, the follow-system switch and its hint are gone
    expect(screen.queryByRole('switch')).toBeNull();
    expect(screen.queryByText('themeFollowSystemHint')).toBeNull();
    // The custom area only appears when custom is selected
    expect(screen.queryByTestId('theme-custom-color')).toBeNull();

    act(() => setPrefs({ theme: 'light' }));
    // Light appearance: cards and preview draw the light version, and the selection ring stays on resolve(darkPalette)
    expect(swatch('themePaletteOcean').querySelector('[data-palette="dark-ocean"][data-theme="light"]')).not.toBeNull();
    expect(swatch('themePaletteOcean').getAttribute('aria-pressed')).toBe('true');
    expect(preview.dataset.theme).toBe('light');
  });

  it('tapping a palette card writes only darkPalette and leaves the appearance alone', () => {
    setPrefs({ theme: 'light' });
    renderPage();
    fireEvent.click(swatch('themePaletteForest'));
    expect(prefs().theme).toBe('light');
    expect(prefs().darkPalette).toBe('dark-forest');
    expect(prefs().darkPaletteSetByUser).toBe(true);
    expect(html().theme).toBe('light');
    expect(html().palette).toBe('dark-forest');
    expect(swatch('themePaletteForest').getAttribute('aria-pressed')).toBe('true');

    fireEvent.click(swatch('themePaletteDefault'));
    expect(prefs()).toMatchObject({ theme: 'light', darkPalette: 'dark' });
  });

  it('three appearance segments: radiogroup, writes only theme; follow-system draws by the system appearance', () => {
    setPrefs({ theme: 'dark', darkPalette: 'dark-sunset' });
    holder.systemDark = false;
    renderPage();
    expect(screen.getByRole('radiogroup')).not.toBeNull();
    expect(screen.getAllByRole('radio').map((r) => r.textContent)).toEqual(['themeLight', 'themeDark', 'themeSystem']);
    expect(segment('themeDark').getAttribute('aria-checked')).toBe('true');

    fireEvent.click(segment('themeSystem'));
    expect(prefs()).toMatchObject({ theme: 'system', darkPalette: 'dark-sunset' });
    expect(segment('themeSystem').getAttribute('aria-checked')).toBe('true');
    expect(screen.getByTestId('theme-preview').dataset.theme).toBe('light');

    fireEvent.keyDown(screen.getByRole('radiogroup'), { key: 'ArrowLeft' });
    expect(prefs().theme).toBe('dark');
    expect(prefs().darkPalette).toBe('dark-sunset');
  });

  it('tapping custom: writes the default seed when there is none and shows the color picker; tapping a preset dot writes the seed', () => {
    setPrefs({ theme: 'dark', darkPalette: 'dark-black' });
    renderPage();
    fireEvent.click(swatch('themePaletteCustom'));
    expect(prefs()).toMatchObject({ theme: 'dark', darkPalette: 'custom', darkPaletteCustom: DEFAULT_CUSTOM_SEED });
    expect(html().palette).toBe('custom');
    const area = screen.getByTestId('theme-custom-color');
    expect(area.querySelectorAll('[data-seed]')).toHaveLength(12);
    expect(swatch('themeColorBlue').getAttribute('aria-pressed')).toBe('true');
    // Primary / secondary colors are shown from the dark derivation
    const derived = deriveCustom(DEFAULT_CUSTOM_SEED).palette;
    expect(area.textContent).toContain(derived.primary);
    expect(area.textContent).toContain(derived.accent);

    fireEvent.click(swatch('themeColorPink'));
    expect(prefs()).toMatchObject({ theme: 'dark', darkPalette: 'custom', darkPaletteCustom: '#F472B6' });
    expect(swatch('themeColorPink').getAttribute('aria-pressed')).toBe('true');

    // Switching back to a preset keeps the seed, and tapping custom again restores it
    fireEvent.click(swatch('themePaletteOcean'));
    expect(prefs()).toMatchObject({ darkPalette: 'dark-ocean', darkPaletteCustom: '#F472B6' });
    expect(screen.queryByTestId('theme-custom-color')).toBeNull();
    fireEvent.click(swatch('themePaletteCustom'));
    expect(prefs()).toMatchObject({ darkPalette: 'custom', darkPaletteCustom: '#F472B6' });
  });

  it('dragging the hue slider only changes the preview on this page; preferences are written on release', () => {
    setPrefs({ theme: 'dark', darkPalette: 'custom', darkPaletteCustom: '#4ADE80' });
    renderPage();
    const slider = screen.getByRole('slider', { name: 'themeHue' });
    const draft = hueSliderSeed(200);

    fireEvent.input(slider, { target: { value: '200' } });
    expect(prefs().darkPaletteCustom).toBe('#4ADE80');
    const preview = screen.getByTestId('theme-preview');
    expect(preview.dataset.palette).toBe('custom');
    expect(preview.style.getPropertyValue('--o-primary')).toBe(deriveCustom(draft).palette.primary);
    expect(swatch('themePaletteCustom').querySelector('[data-palette="custom"]')!.getAttribute('style'))
      .toContain(deriveCustom(draft).palette.primary);

    fireEvent.change(slider);
    expect(prefs()).toMatchObject({ darkPalette: 'custom', darkPaletteCustom: draft, theme: 'dark' });
    expect((slider as HTMLInputElement).value).toBe('200');
  });

  it('light appearance: hex shows the light brand ink / secondary color; the lightening hint appears only when the derivation adjusted', () => {
    setPrefs({ theme: 'light', darkPalette: 'custom', darkPaletteCustom: '#1E3A8A' });
    renderPage();
    const brand = deriveCustomLight('#1E3A8A');
    const area = screen.getByTestId('theme-custom-color');
    expect(area.textContent).toContain(brand.ink);
    expect(area.textContent).toContain(brand.accent);
    expect(deriveCustom('#1E3A8A').adjusted).toBe('lightened');
    expect(screen.getByTestId('theme-custom-adjusted').textContent).toBe('themeCustomLightened');

    act(() => setPrefs({ darkPaletteCustom: '#A3E635' }));
    expect(deriveCustom('#A3E635').adjusted).toBeNull();
    expect(screen.queryByTestId('theme-custom-adjusted')).toBeNull();
  });

  it('switching appearance and palette does not remount the page (same DOM node)', () => {
    setPrefs({ theme: 'dark', darkPalette: 'dark-black' });
    renderPage();
    const preview = screen.getByTestId('theme-preview');
    const oceanButton = swatch('themePaletteOcean');

    fireEvent.click(oceanButton);
    fireEvent.click(segment('themeLight'));
    act(() => setPrefs({ darkPalette: 'dark-graphite' }));

    expect(screen.getByTestId('theme-preview')).toBe(preview);
    expect(swatch('themePaletteOcean')).toBe(oceanButton);
  });

  it('preview reply: the emphasized word and inline code are filled into the template placeholders', () => {
    renderPage();
    const preview = screen.getByTestId('theme-preview');
    expect(preview.querySelector('strong')?.textContent).toBe('themePreviewOwner');
    expect(preview.querySelector('code')?.textContent).toBe('&T');
    expect(preview.textContent).toContain('themePreviewQuestion');
    // To a screen reader the whole card is a single "preview"; its internals are not exposed
    expect(preview.getAttribute('role')).toBe('img');
    expect(preview.getAttribute('aria-label')).toBe('backup.preview');
    expect(preview.textContent).toContain('thinkingBlock.thoughtFor(4s)');
  });

  it('mini code block: two lines of plain code, no comments', () => {
    renderPage();
    const code = screen.getByTestId('theme-preview').querySelector('pre')?.textContent;
    expect(code).toBe('let s = String::from("hi");\nlet r = &s;');
  });

  it('wide screens use an 8-column equal grid with no horizontal scroll; only when 8 cards of at least 64px do not fit does it scroll; the preview grows with its content without clipping', () => {
    const css = readFileSync(join(process.cwd(), 'app/settings/theme/ThemeSettings.module.css'), 'utf8');
    const wide = /@container palette-group \(min-width: (\d+)px\) \{([\s\S]*?)\n\}/.exec(css);
    expect(wide).not.toBeNull();
    // Each card is also a container (its name scales with card width), so the wide-screen rule must query the palette group by name; without a name the elements inside a card would query the 67px card itself, stretching the card face back to 76px in the grid and eating the gaps
    expect(css).toMatch(/\n\.group \{[^}]*container: palette-group \/ inline-size/);
    expect(css).not.toMatch(/@container \(min-width/);
    const [, minWidth, body] = wide!;
    const gap = Number(/\.cardRow \{[^}]*?column-gap: (\d+)px/.exec(body)![1]);
    // Leave 8px between adjacent cards so they do not touch
    expect(gap).toBe(8);
    expect(body).toMatch(/\.swatch \{[^}]*width: 100%/);
    // The threshold is exactly 8 cards of 64px + 7 gaps
    expect(Number(minWidth)).toBe(8 * 64 + 7 * gap);
    expect(body).toMatch(/grid-template-columns: repeat\(8, minmax\(0, 1fr\)\)/);
    expect(body).toMatch(/overflow-x: visible/);
    expect(body).toMatch(/aspect-ratio: 76 \/ 104/);
    const preview = /\n\.preview \{([^}]*)\}/.exec(css)![1];
    expect(preview).toMatch(/min-height: 352px/);
    expect(preview).not.toMatch(/(^|\s)height:/);
  });
});
