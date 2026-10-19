import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fireEvent, render, screen } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AppPreference } from '@oriveo/shared';
import { ContextSettingsPage } from '../../../../../app/settings/context/ContextSettingsPage';

type MockState = {
  preferences: Partial<AppPreference>;
  setPreferences: (prefs: Partial<AppPreference>) => void;
};

const mocks = vi.hoisted(() => ({ routerBack: vi.fn(), routerPush: vi.fn() }));

let mockState: MockState;

vi.mock('next/navigation', () => ({
  useRouter: () => ({ back: mocks.routerBack, push: mocks.routerPush }),
}));

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations: (namespace: string) => (key: string) => `${namespace}.${key}`,
}));

vi.mock('../../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
}));

const LOCALES = [
  'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es',
  'pt-BR', 'ru', 'tr', 'id', 'vi', 'th', 'hi', 'ar',
];

const COMPACTION_KEYS = [
  'summaryLine1', 'summaryLine2', 'fallbackLine1', 'fallbackLine2',
  'detailTitle', 'detailSummary', 'detailKept', 'detailFallbackNote',
  'detailModel', 'detailCost', 'detailCostUnavailable', 'detailNoExtraCost',
  'detailTime', 'actionCompact', 'actionRecompact', 'actionClear',
  'actionNewChatWithSummary', 'toastNoop', 'toastFallback', 'toastCleared',
  'inProgress', 'cancel', 'thirdHint', 'thirdHintNewChat', 'thirdHintDismiss',
  'quoteLabel',
].map((key) => `pages.chat.contextCompaction.${key}`);

const SETTINGS_KEYS = [
  'title', 'overflowHeader', 'modeFallback', 'modeFallbackHint', 'modeAi',
  'modeAiHint', 'overflowFooter', 'rowValueFallback', 'capHeader', 'capFooter', 'rowValue',
  'priceLineReminder', 'priceLineReminderFooter',
].map((key) => `pages.settings.context.${key}`);

function getNested(source: unknown, path: string): unknown {
  return path.split('.').reduce<unknown>(
    (node, key) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[key] : undefined),
    source,
  );
}

describe('context settings', () => {
  beforeEach(() => {
    mockState = {
      preferences: {},
      setPreferences: vi.fn((prefs: Partial<AppPreference>) => {
        mockState = { ...mockState, preferences: { ...mockState.preferences, ...prefs } };
      }),
    };
  });

  it('settings_mode_roundtrip', () => {
    const { rerender } = render(<ContextSettingsPage />);
    const fallback = screen.getByRole('radio', { name: /pages\.settings\.context\.modeFallback/ });
    const ai = screen.getByRole('radio', { name: /pages\.settings\.context\.modeAi/ });
    // Default = keep verbatim user messages only
    expect(fallback.getAttribute('aria-checked')).toBe('true');
    expect(ai.getAttribute('aria-checked')).toBe('false');

    fireEvent.click(ai);
    expect(mockState.setPreferences).toHaveBeenCalledWith({ contextAISummaryEnabled: true });
    expect(mockState.preferences.contextAISummaryEnabled).toBe(true);
    rerender(<ContextSettingsPage />);
    expect(screen.getByRole('radio', { name: /pages\.settings\.context\.modeAi/ }).getAttribute('aria-checked')).toBe('true');

    fireEvent.click(screen.getByRole('radio', { name: /pages\.settings\.context\.modeFallback/ }));
    expect(mockState.setPreferences).toHaveBeenLastCalledWith({ contextAISummaryEnabled: false });
    rerender(<ContextSettingsPage />);
    expect(screen.getByRole('radio', { name: /pages\.settings\.context\.modeFallback/ }).getAttribute('aria-checked')).toBe('true');
    expect(screen.getByRole('radiogroup', { name: /pages\.settings\.context\.overflowHeader/ })).toBeTruthy();
    expect(screen.getByText('pages.settings.context.overflowFooter')).toBeTruthy();
  });

  it('strings_present_in_16_locales', () => {
    const paths = [...COMPACTION_KEYS, ...SETTINGS_KEYS];
    expect(paths).toHaveLength(39);
    const missing = LOCALES.flatMap((locale) => {
      const messages = JSON.parse(readFileSync(join(process.cwd(), 'messages', `${locale}.json`), 'utf8'));
      return paths
        .filter((path) => {
          const value = getNested(messages, path);
          return typeof value !== 'string' || value.trim().length === 0;
        })
        .map((path) => `${locale}:${path}`);
    });
    expect(missing).toEqual([]);
  });
});
