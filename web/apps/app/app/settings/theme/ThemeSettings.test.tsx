import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { useStore } from 'zustand';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
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

/** Same as StoreProvider's ThemeSyncer: preferences to <html data-theme / data-palette>. */
function ThemeSyncerHarness() {
  const theme = useStore(holder.store, (s) => s.preferences.theme);
  const darkPalette = useStore(holder.store, (s) => s.preferences.darkPalette);
  useTheme(theme);
  useDarkPalette(darkPalette);
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
  it('swatches: Light, Dark + 6 palettes, aria-label is the name, aria-pressed marks the selection', () => {
    setPrefs({ theme: 'dark', darkPalette: 'dark-ocean' });
    renderPage();
    const names = screen.getAllByRole('button', { pressed: false }).map((b) => b.getAttribute('aria-label'));
    expect(names).toEqual(expect.arrayContaining([
      'themeLight', 'themeDark', 'themePalettePurple', 'themePaletteGraphite',
      'themePaletteBlack', 'themePaletteForest', 'themePaletteSunset',
    ]));
    expect(swatch('themePaletteOcean').getAttribute('aria-pressed')).toBe('true');
    expect(screen.getAllByRole('button', { pressed: true })).toHaveLength(1);
    // Each swatch and preview carries its own data-theme / data-palette, and all colors come from tokens
    expect(swatch('themePaletteOcean').querySelector('[data-palette="dark-ocean"][data-theme="dark"]')).not.toBeNull();
    expect(swatch('themeLight').querySelector('[data-theme="light"]')).not.toBeNull();
    const preview = screen.getByTestId('theme-preview');
    expect(preview.dataset.theme).toBe('dark');
    expect(preview.dataset.palette).toBe('dark-ocean');
    // One horizontally scrolling row of 8 cards: Light, Dark, Purple ... Sunset
    expect(screen.getByText('themeSectionPalettes')).not.toBeNull();
    expect(Array.from(document.querySelectorAll('[data-swatch]')).map((b) => b.getAttribute('data-swatch'))).toEqual([
      'light', 'dark', 'dark-purple', 'dark-graphite', 'dark-black', 'dark-ocean', 'dark-forest', 'dark-sunset',
    ]);
  });

  it('tapping a palette with follow off: writes theme=dark + darkPalette immediately and <html> follows', () => {
    setPrefs({ theme: 'light' });
    renderPage();
    expect(html().theme).toBe('light');

    fireEvent.click(swatch('themePaletteForest'));

    const prefs = holder.store.getState().preferences;
    expect(prefs.theme).toBe('dark');
    expect(prefs.darkPalette).toBe('dark-forest');
    expect(prefs.darkPaletteSetByUser).toBe(true);
    expect(html().theme).toBe('dark');
    expect(html().palette).toBe('dark-forest');
    expect(swatch('themePaletteForest').getAttribute('aria-pressed')).toBe('true');

    fireEvent.click(swatch('themeLight'));
    expect(holder.store.getState().preferences.darkPalette).toBe('dark-forest');
    expect(html().theme).toBe('light');
    expect(swatch('themeLight').getAttribute('aria-pressed')).toBe('true');
    expect(screen.getByTestId('theme-preview').dataset.theme).toBe('light');
  });

  it('follow system: while on, tapping a palette writes only darkPalette and theme stays system; turning it off takes the current system appearance', () => {
    setPrefs({ theme: 'system', darkPalette: 'dark' });
    holder.systemDark = true;
    renderPage();
    const toggle = screen.getByRole('switch');
    // The switch is a styled button, not a checkbox
    expect(toggle.tagName).toBe('BUTTON');
    expect(toggle.getAttribute('aria-checked')).toBe('true');
    expect(swatch('themeDark').getAttribute('aria-pressed')).toBe('true');
    expect(swatch('themeLight').getAttribute('aria-pressed')).toBe('false');

    fireEvent.click(swatch('themePaletteSunset'));
    expect(holder.store.getState().preferences.theme).toBe('system');
    expect(holder.store.getState().preferences.darkPalette).toBe('dark-sunset');
    expect(html().palette).toBe('dark-sunset');

    fireEvent.click(toggle);
    expect(holder.store.getState().preferences.theme).toBe('dark');
    expect(toggle.getAttribute('aria-checked')).toBe('false');

    fireEvent.click(toggle);
    expect(holder.store.getState().preferences.theme).toBe('system');
    expect(toggle.getAttribute('aria-checked')).toBe('true');
  });

  it('switching theme and palette does not remount the page (same DOM node)', () => {
    setPrefs({ theme: 'dark', darkPalette: 'dark-black' });
    renderPage();
    const preview = screen.getByTestId('theme-preview');
    const oceanButton = swatch('themePaletteOcean');

    fireEvent.click(oceanButton);
    fireEvent.click(swatch('themeLight'));
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
    // To screen readers the whole card is a single "preview"; its internals are not exposed
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
    // Each card is itself a container (the name scales with the card width), so the wide-screen rule must look up the palette group by name; without a name, elements inside the card would query the 67px card itself, stretching the card face back to 76px in the grid and eating the gaps
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
