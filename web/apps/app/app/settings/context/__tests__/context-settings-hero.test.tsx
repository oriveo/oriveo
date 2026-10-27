import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AppPreference } from '@oriveo/shared';
import { CONTEXT_BUDGET_CONSTANTS, type BudgetCapOption } from '@oriveo/core/context/budget';
import { ContextSettingsPage } from '../ContextSettingsPage';
import {
  CONTEXT_SETTINGS_HERO_CONSTANTS,
  contextSettingsHeroOf,
} from '../../../../lib/core/context-cap-preferences';

// Settings > Context overview card: reads the shared fixture shared/ui-contracts/context-settings-hero.v1.json, same-named cases as iOS / Android.

type MockState = {
  preferences: Partial<AppPreference>;
  setPreferences: (prefs: Partial<AppPreference>) => void;
};

let mockState: MockState;

vi.mock('next/navigation', () => ({
  useRouter: () => ({ back: vi.fn(), push: vi.fn() }),
}));

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations: (namespace: string) => (key: string, values?: Record<string, unknown>) =>
    values ? `${namespace}.${key}(${JSON.stringify(values)})` : `${namespace}.${key}`,
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
}));

function repoFile(relative: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const next = path.dirname(current);
    if (next === current) throw new Error(relative);
    current = next;
  }
}

type HeroCase = {
  name: string;
  cap: { kind: 'auto' } | { kind: 'unlimited' } | { kind: 'custom'; tokens: number };
  valueKind: 'count' | 'fullWindow';
  valueTokens?: number;
  hasUnit: boolean;
  captionKey: string;
  fill: number;
};

const fixture = JSON.parse(
  readFileSync(repoFile('shared/ui-contracts/context-settings-hero.v1.json'), 'utf8'),
) as {
  constants: { autoCapDefault: number; autoFill: number; priceLineMarker: number; minFill: number; maxFill: number };
  cases: HeroCase[];
};

function capOf(c: HeroCase): BudgetCapOption {
  return c.cap.kind === 'custom' ? c.cap.tokens : c.cap.kind;
}

/** Shared key settings_context_hero_caption_auto -> this platform's pages.settings.context.heroCaptionAuto. */
function webKey(sharedKey: string): string {
  return sharedKey.replace(/^settings_context_/, '').replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}

function caseNamed(name: string): HeroCase {
  const found = fixture.cases.find((c) => c.name === name);
  if (!found) throw new Error(name);
  return found;
}

function expectCase(name: string) {
  const c = caseNamed(name);
  const hero = contextSettingsHeroOf(capOf(c));
  expect(hero.valueKind).toBe(c.valueKind);
  expect(hero.valueTokens).toBe(c.valueKind === 'count' ? c.valueTokens : null);
  expect(hero.hasUnit).toBe(c.hasUnit);
  expect(hero.captionKey).toBe(webKey(c.captionKey));
  expect(Math.abs(hero.fill - c.fill)).toBeLessThanOrEqual(0.001);
}

describe('ContextSettingsHero', () => {
  beforeEach(() => {
    mockState = { preferences: {}, setPreferences: vi.fn() };
  });

  it('constants_match_fixture', () => {
    expect(CONTEXT_BUDGET_CONSTANTS.autoCapDefault).toBe(fixture.constants.autoCapDefault);
    expect(CONTEXT_SETTINGS_HERO_CONSTANTS).toEqual({
      autoFill: fixture.constants.autoFill,
      priceLineMarker: fixture.constants.priceLineMarker,
      minFill: fixture.constants.minFill,
      maxFill: fixture.constants.maxFill,
    });
    expect(fixture.cases.map((c) => c.name)).toEqual([
      'auto', 'unlimited', 'custom_min_clamps_up', 'custom_half_default', 'custom_equals_auto_default',
      'custom_huge_clamps_down',
    ]);
  });

  it('hero_auto', () => expectCase('auto'));
  it('hero_unlimited', () => expectCase('unlimited'));
  it('hero_custom_min_clamps_up', () => expectCase('custom_min_clamps_up'));
  it('hero_custom_half_default', () => expectCase('custom_half_default'));
  it('hero_custom_equals_auto_default', () => expectCase('custom_equals_auto_default'));
  it('hero_custom_huge_clamps_down', () => expectCase('custom_huge_clamps_down'));

  it('hero_renders_stored_cap', () => {
    mockState.preferences = { contextDefaultCap: 128000 };
    const { unmount } = render(<ContextSettingsPage />);
    expect(screen.getByTestId('settings-context-hero-value').textContent).toContain('128K');
    expect(screen.getByTestId('settings-context-hero-fill').style.width).toBe('33%');
    expect(screen.getByText('pages.settings.context.heroCaptionCustom')).toBeTruthy();
    unmount();

    mockState.preferences = { contextDefaultCap: 'unlimited' };
    render(<ContextSettingsPage />);
    expect(screen.getByTestId('settings-context-hero-value').textContent).toBe('pages.settings.context.heroFullWindow');
    expect(screen.getByTestId('settings-context-hero-fill').style.width).toBe('100%');
    expect(screen.queryByText('pages.chat.contextCap.inputUnit')).toBeNull();
  });

  it('hero_follows_custom_input_preview', () => {
    // The overview card and the input echo read the same preview: a value below the minimum shows the raised 32K, and it follows even before commit
    mockState.preferences = { contextDefaultCap: 216000 };
    render(<ContextSettingsPage />);
    expect(screen.getByTestId('settings-context-hero-value').textContent).toContain('216K');
    fireEvent.change(screen.getByTestId('settings-context-cap-input'), { target: { value: '21000' } });
    expect(screen.getByTestId('settings-context-hero-value').textContent).toContain('32K');
    expect(screen.getByText('pages.settings.context.heroCaptionCustom')).toBeTruthy();
    expect(screen.getByTestId('settings-context-hero-fill').style.width).toBe(
      `${CONTEXT_SETTINGS_HERO_CONSTANTS.minFill * 100}%`,
    );
    expect(mockState.setPreferences).not.toHaveBeenCalled();

    // Unparsable -> fall back to the stored value
    fireEvent.change(screen.getByTestId('settings-context-cap-input'), { target: { value: 'abc' } });
    expect(screen.getByTestId('settings-context-hero-value').textContent).toContain('216K');
  });

  it('enter_commits_once_and_blurs', () => {
    mockState.preferences = { contextDefaultCap: 216000 };
    render(<ContextSettingsPage />);
    const input = screen.getByTestId('settings-context-cap-input') as HTMLInputElement;
    input.focus();
    fireEvent.change(input, { target: { value: '100000' } });
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(document.activeElement).not.toBe(input);
    expect(mockState.setPreferences).toHaveBeenCalledTimes(1);
    expect(mockState.setPreferences).toHaveBeenCalledWith({ contextDefaultCap: 100000 });
  });
});
