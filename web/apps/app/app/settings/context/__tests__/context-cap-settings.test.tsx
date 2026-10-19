import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createTranslator } from 'use-intl/core';
import { createStore, type StoreApi } from 'zustand/vanilla';
import type { AIModel, AppPreference, Conversation, Provider } from '@oriveo/shared';
import type { BudgetCapOption, WindowKind } from '@oriveo/core/context/budget';
import { ContextSettingsPage } from '../ContextSettingsPage';
import { ContextUsagePanel } from '../../../../components/chat/ContextUsagePanel';
import {
  __seedMetadataCacheForTest,
  initMetadata,
} from '../../../../lib/core/metadata/metadata-client';
import {
  capPanelOf,
  capPickerOf,
  capPresentationInputOf,
  commitCustomCap,
  contextRowValueText,
  settingsCapOf,
} from '../../../../lib/core/chat/context-visibility/cap-presentation';

// Settings > Context "Default cap".

type MockState = {
  preferences: Partial<AppPreference>;
  setPreferences: (prefs: Partial<AppPreference>) => void;
};

const mocks = vi.hoisted(() => ({
  routerBack: vi.fn(),
  routerPush: vi.fn(),
  // When non-null, useTranslations uses the real messages (render assertions need to see "x2").
  messages: null as Record<string, unknown> | null,
  // The vanilla store used for writing the conversation cap (holds only conversations).
  store: null as StoreApi<{ conversations: Conversation[] }> | null,
}));

let mockState: MockState;

vi.mock('next/navigation', () => ({
  useRouter: () => ({ back: mocks.routerBack, push: mocks.routerPush }),
}));

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations: (namespace: string) => {
    if (mocks.messages) {
      const t = createTranslator({ locale: 'en', messages: mocks.messages, namespace } as never) as unknown as (
        key: string,
        values?: Record<string, unknown>,
      ) => string;
      return (key: string, values?: Record<string, unknown>) => t(key, values);
    }
    return (key: string, values?: Record<string, unknown>) =>
      values ? `${namespace}.${key}(${JSON.stringify(values)})` : `${namespace}.${key}`;
  },
}));

vi.mock('../../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
  getVanillaStore: () => mocks.store,
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

type WindowCaseInput = {
  W: number | null;
  windowKind: WindowKind;
  maxOutput: { user?: number | null; recipe?: number | null; model?: number | null };
  priceLineTokens: number | null;
  conversationCap: BudgetCapOption | null;
  globalCap: BudgetCapOption;
};

type FixtureCase<I, E> = { id: string; input: I; expected: E };

const fixture = JSON.parse(
  readFileSync(repoFile('shared/context-contracts/context-cap-presentation.v1.json'), 'utf8'),
) as {
  pickerCases: FixtureCase<WindowCaseInput, unknown>[];
  commitCases: FixtureCase<{ text: string; U: number | null; previous: number }, unknown>[];
  panelCases: FixtureCase<
    WindowCaseInput & {
      used: number;
      pricing?: {
        base?: { prompt?: number; completion?: number };
        long?: { prompt?: number; completion?: number };
      };
    },
    unknown
  >[];
  settingsCases: FixtureCase<{ stored: unknown }, unknown>[];
};

const LOCALES = [
  'en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es',
  'pt-BR', 'ru', 'tr', 'id', 'vi', 'th', 'hi', 'ar',
];

function readMessages(locale: string): Record<string, unknown> {
  return JSON.parse(readFileSync(path.join(process.cwd(), 'messages', `${locale}.json`), 'utf8'));
}

function getNested(source: unknown, keyPath: string): unknown {
  return keyPath.split('.').reduce<unknown>(
    (node, key) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[key] : undefined),
    source,
  );
}

/** A minimal translator that does {name} substitution with the real messages (used only for the row-value assertions in this test). */
function translatorOf(messages: Record<string, unknown>, namespace: string) {
  return (key: string, values?: Record<string, string>) => {
    const template = getNested(messages, `${namespace}.${key}`);
    if (typeof template !== 'string') throw new Error(`${namespace}.${key}`);
    return template.replace(/\{(\w+)\}/g, (_, name: string) => values?.[name] ?? `{${name}}`);
  };
}

const GROK_ID = 'grok-4.7';

async function seedGrokMetadata() {
  const models = {
    [GROK_ID]: {
      canonicalModelId: GROK_ID,
      contextLength: 2000000,
      maxOutputTokens: 32000,
      pricingUnit: 'per_token',
      pricingStatus: 'priced',
      capabilities: ['text'],
      pricing: {
        promptPerMToken: 2,
        completionPerMToken: 6,
        longContext: { thresholdTokens: 200000, promptPerMToken: 4, completionPerMToken: 12 },
      },
    },
  };
  const data = {
    version: 1,
    contractVersion: 1,
    updatedAt: '2026-10-17T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: { grok: { models } },
    providerConfigs: [],
  };
  await __seedMetadataCacheForTest({ data: data as never, timestamp: Date.now() });
  await initMetadata();
}

describe('ContextCapSettings', () => {
  beforeEach(() => {
    mocks.messages = null;
    mockState = {
      preferences: {},
      setPreferences: vi.fn((prefs: Partial<AppPreference>) => {
        mockState = { ...mockState, preferences: { ...mockState.preferences, ...prefs } };
      }),
    };
  });

  it('presentation_matches_fixture', () => {
    expect(fixture.pickerCases.length).toBeGreaterThan(0);
    for (const c of fixture.pickerCases) {
      expect({ id: c.id, ...capPickerOf(c.input) }).toEqual({ id: c.id, ...(c.expected as object) });
    }
    expect(fixture.panelCases.length).toBeGreaterThan(0);
    for (const c of fixture.panelCases) {
      expect({ id: c.id, ...capPanelOf(c.input) }).toEqual({ id: c.id, ...(c.expected as object) });
    }
    expect(fixture.settingsCases.length).toBeGreaterThan(0);
    for (const c of fixture.settingsCases) {
      expect({ id: c.id, ...settingsCapOf(c.input.stored) }).toEqual({ id: c.id, ...(c.expected as object) });
    }
  });

  it('commit_matches_fixture', () => {
    expect(fixture.commitCases.length).toBeGreaterThan(0);
    for (const c of fixture.commitCases) {
      const { text, U, previous } = c.input;
      expect({ id: c.id, ...commitCustomCap(text, U, previous) }).toEqual({ id: c.id, ...(c.expected as object) });
    }
  });

  it('settings_default_cap_roundtrip', () => {
    const { rerender } = render(<ContextSettingsPage />);
    const group = screen.getByRole('radiogroup', { name: /pages\.settings\.context\.capHeader/ });
    expect(group).toBeTruthy();
    // Default = automatic; the custom input is not expanded
    expect(screen.getByTestId('settings-context-cap-auto').getAttribute('aria-checked')).toBe('true');
    expect(screen.queryByTestId('settings-context-cap-input')).toBeNull();

    fireEvent.click(screen.getByTestId('settings-context-cap-custom'));
    expect(mockState.preferences.contextDefaultCap).toBe(256000);
    rerender(<ContextSettingsPage />);
    expect(screen.getByTestId('settings-context-cap-custom').getAttribute('aria-checked')).toBe('true');
    const input = screen.getByTestId('settings-context-cap-input') as HTMLInputElement;
    expect(input.value).toBe('256000');

    // Enter during IME composition does not submit
    fireEvent.change(input, { target: { value: '190000' } });
    fireEvent.keyDown(input, { key: 'Enter', isComposing: true });
    expect(mockState.preferences.contextDefaultCap).toBe(256000);

    fireEvent.blur(input);
    expect(mockState.preferences.contextDefaultCap).toBe(190000);
    rerender(<ContextSettingsPage />);
    expect((screen.getByTestId('settings-context-cap-input') as HTMLInputElement).value).toBe('190000');
    expect(screen.getByText(/pages\.chat\.contextCap\.inputEcho/).textContent).toContain('190K');
    expect(screen.queryByText(/pages\.chat\.contextCap\.adjusted/)).toBeNull();

    // Below the lower bound: clamp to 32000 and hint in place
    const again = screen.getByTestId('settings-context-cap-input') as HTMLInputElement;
    fireEvent.change(again, { target: { value: '1000' } });
    fireEvent.keyDown(again, { key: 'Enter' });
    expect(mockState.preferences.contextDefaultCap).toBe(32000);
    rerender(<ContextSettingsPage />);
    expect(screen.getByText(/pages\.chat\.contextCap\.adjusted/).textContent).toContain('32K');

    // Cannot be parsed: restore the original value, do not write the preference
    const third = screen.getByTestId('settings-context-cap-input') as HTMLInputElement;
    fireEvent.change(third, { target: { value: 'abc' } });
    fireEvent.blur(third);
    expect(mockState.preferences.contextDefaultCap).toBe(32000);
    expect((screen.getByTestId('settings-context-cap-input') as HTMLInputElement).value).toBe('32000');

    fireEvent.click(screen.getByTestId('settings-context-cap-unlimited'));
    expect(mockState.preferences.contextDefaultCap).toBe('unlimited');
    rerender(<ContextSettingsPage />);
    expect(screen.getByTestId('settings-context-cap-unlimited').getAttribute('aria-checked')).toBe('true');
    expect(screen.queryByTestId('settings-context-cap-input')).toBeNull();
    expect(screen.getByText(/pages\.settings\.context\.capFooter/)).toBeTruthy();
  });

  it('price_line_reminder_is_switch', () => {
    // The price-line reminder uses a switch (McpSwitch) like iOS / Android, not a native checkbox; behavior and aria are unchanged.
    const { container } = render(<ContextSettingsPage />);
    const toggle = within(container).getByTestId('settings-context-price-line-reminder');
    expect(toggle.tagName).toBe('BUTTON');
    expect(toggle.getAttribute('role')).toBe('switch');
    expect(toggle.getAttribute('aria-checked')).toBe('true');
    expect(toggle.getAttribute('aria-describedby')).toBe('context-price-line-reminder-footer');
    expect(container.querySelector('input[type="checkbox"]')).toBeNull();
    fireEvent.click(toggle);
    expect(mockState.preferences.contextPriceLineReminderEnabled).toBe(false);
  });

  it('settings_row_value_text', () => {
    const en = readMessages('en');
    const tContext = translatorOf(en, 'pages.settings.context');
    const tCap = translatorOf(en, 'pages.chat.contextCap');
    expect(contextRowValueText({}, 'en', tContext, tCap)).toBe('Automatic · Your messages only');
    expect(contextRowValueText({ contextDefaultCap: 'unlimited', contextAISummaryEnabled: true }, 'en', tContext, tCap))
      .toBe('No limit · AI summary');
    expect(contextRowValueText({ contextDefaultCap: 190000 }, 'en', tContext, tCap))
      .toBe('\u2068190K\u2069 · Your messages only');

    const zh = readMessages('zh-Hans');
    expect(
      contextRowValueText(
        { contextDefaultCap: 190000, contextAISummaryEnabled: true },
        'zh-Hans',
        translatorOf(zh, 'pages.settings.context'),
        translatorOf(zh, 'pages.chat.contextCap'),
      ),
    ).toBe('\u206819\u4e07\u2069 · AI \u6458\u8981');
  });

  it('panel_cap_row_from_production_metadata', async () => {
    await seedGrokMetadata();
    // Neither window nor price is written on the model: they come only from production metadata decoding.
    const model = { id: GROK_ID, name: GROK_ID, capabilities: ['text'], isAvailable: true } as unknown as AIModel;
    const provider = {
      id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [model], catalogModels: [],
    } as unknown as Provider;
    const conversation = { id: 'c-grok', messages: [] } as unknown as Conversation;

    const input = capPresentationInputOf({ conversation, preferences: {}, provider, model });
    expect(input?.priceLineTokens).toBe(200000);
    expect(input?.conversationCap).toBeNull();
    expect(input?.globalCap).toBe('auto');
    const panel = capPanelOf({ ...input!, used: 50000 });
    expect(panel.capValue).toBe(200000);
    expect(panel.windowLine).toBe('windowPriceLine');
    expect(panel.multiplier).toEqual({ input: 20, output: 20 });

    mocks.messages = readMessages('en');
    render(
      <ContextUsagePanel
        open
        onClose={() => {}}
        conversationId={conversation.id}
        state={null}
        sending={false}
        onNewChatWithSummary={() => {}}
        conversation={conversation}
        provider={provider}
        currentModel={model}
      />,
    );
    const row = screen.getByTestId('chat-context-cap-row');
    expect(row.textContent).toContain('Limit for this chat');
    expect(row.textContent).toContain('\u2068200K\u2069');
    const windowRow = screen.getByTestId('chat-context-window-row');
    expect(windowRow.textContent).toContain('×2');
    expect(windowRow.textContent).toContain('input and output ×2');
    expect(windowRow.textContent).toContain('\u2068200K\u2069');
    expect(screen.queryByTestId('chat-context-cap-limited')).toBeNull();
    // Tapping the cap row switches to the picker view inside the popover
    fireEvent.click(row);
    expect(screen.getByTestId('chat-context-cap-follow').getAttribute('aria-checked')).toBe('true');
    expect(screen.queryByTestId('chat-context-cap-row')).toBeNull();
    cleanup();

    // When usage is unknown, the small label under the ring falls back to "measured / estimated" and does not say "T left to the price line"
    mocks.messages = null;
    const aboveConversation = { id: 'c-grok', messages: [], contextCap: 500000 } as unknown as Conversation;
    const aboveInput = capPresentationInputOf({ conversation: aboveConversation, preferences: {}, provider, model });
    expect(capPanelOf({ ...aboveInput!, used: 0 }).windowLine).toBe('aboveLine');
    const summary = {
      display: 'percent', percent: 10, basis: 'estimated', used: null, B: 500000,
      segments: null, omitted: null, tone: 'neutral',
    };
    render(
      <ContextUsagePanel
        open
        onClose={() => {}}
        conversationId={aboveConversation.id}
        state={{ summary, checkpoint: null } as never}
        sending={false}
        onNewChatWithSummary={() => {}}
        conversation={aboveConversation}
        provider={provider}
        currentModel={model}
      />,
    );
    expect(screen.getByText('pages.chat.contextUsage.estimated')).toBeTruthy();
    expect(screen.queryByText(/estimatedPriceLine/)).toBeNull();
  });

  it('picker_writes_conversation_cap', async () => {
    await seedGrokMetadata();
    const model = { id: GROK_ID, name: GROK_ID, capabilities: ['text'], isAvailable: true } as unknown as AIModel;
    const provider = {
      id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [model], catalogModels: [],
    } as unknown as Provider;
    const store = createStore<{ conversations: Conversation[] }>(() => ({
      conversations: [{ id: 'c-grok', messages: [] } as unknown as Conversation],
    }));
    mocks.store = store;
    const current = () => store.getState().conversations[0];
    const panel = () => (
      <ContextUsagePanel
        open
        onClose={() => {}}
        conversationId="c-grok"
        state={null}
        sending={false}
        onNewChatWithSummary={() => {}}
        conversation={current()}
        provider={provider}
        currentModel={model}
      />
    );
    const { rerender } = render(panel());
    fireEvent.click(screen.getByTestId('chat-context-cap-row'));
    expect(screen.getByTestId('chat-context-cap-follow').getAttribute('aria-checked')).toBe('true');
    expect(screen.queryByTestId('chat-context-cap-slider')).toBeNull();

    // The option is written immediately: unlimited
    fireEvent.click(screen.getByTestId('chat-context-cap-unlimited'));
    expect(current().contextCap).toBe('unlimited');
    rerender(panel());
    expect(screen.getByTestId('chat-context-cap-unlimited').getAttribute('aria-checked')).toBe('true');

    // Follow global = clear the conversation cap
    fireEvent.click(screen.getByTestId('chat-context-cap-follow'));
    expect(current().contextCap).toBeUndefined();
    rerender(panel());

    // Custom: start from the effective value, expand the slider and input
    fireEvent.click(screen.getByTestId('chat-context-cap-custom'));
    expect(current().contextCap).toBe(200000);
    rerender(panel());
    const input = screen.getByTestId('chat-context-cap-input') as HTMLInputElement;
    expect(input.value).toBe('200000');
    // The slider always draws the price-line label
    expect(screen.getByTestId('chat-context-cap-tick-price-line').textContent).toContain('priceLineTick');
    expect(screen.getByTestId('chat-context-cap-custom-hint').textContent).toContain('customAt');
    // The draft being typed does not change the hint (it changes after submit); echo = the clamped value that will be stored
    fireEvent.change(input, { target: { value: '300000' } });
    expect(screen.getByTestId('chat-context-cap-custom-hint').textContent).toContain('customAt');
    expect(screen.getByText(/pages\.chat\.contextCap\.inputEcho/).textContent).toContain('300K');
    // Cannot be parsed: hide the echo
    fireEvent.change(input, { target: { value: 'abc' } });
    expect(screen.queryByText(/pages\.chat\.contextCap\.inputEcho/)).toBeNull();

    // Enter during IME composition does not submit; a normal Enter submits
    fireEvent.change(input, { target: { value: '190000' } });
    fireEvent.keyDown(input, { key: 'Enter', isComposing: true });
    expect(current().contextCap).toBe(200000);
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(current().contextCap).toBe(190000);
    rerender(panel());
    expect((screen.getByTestId('chat-context-cap-input') as HTMLInputElement).value).toBe('190000');
    expect(screen.queryByText(/pages\.chat\.contextCap\.adjusted/)).toBeNull();

    // Below the lower bound: clamp to 32000 and hint in place
    const again = screen.getByTestId('chat-context-cap-input') as HTMLInputElement;
    fireEvent.change(again, { target: { value: '1000' } });
    fireEvent.blur(again);
    expect(current().contextCap).toBe(32000);
    rerender(panel());
    expect(screen.getByText(/pages\.chat\.contextCap\.adjusted/).textContent).toContain('32K');
    expect(screen.getByText(/pages\.chat\.contextCap\.inputEcho/).textContent).toContain('32K');

    // The slider binds to the tick index: dragging does not write, releasing does
    const picker = capPickerOf(capPresentationInputOf({ conversation: current(), preferences: {}, provider, model })!);
    const target = picker.ticks.length - 1;
    const slider = screen.getByTestId('chat-context-cap-slider') as HTMLInputElement;
    expect(slider.value).toBe(String(picker.sliderIndex));
    fireEvent.input(slider, { target: { value: String(target) } });
    expect(current().contextCap).toBe(32000);
    fireEvent.pointerUp(slider);
    expect(current().contextCap).toBe(picker.ticks[target]);
    rerender(panel());
    // Crossing the price line: the hint turns amber
    expect(screen.getByTestId('chat-context-cap-custom-hint').getAttribute('data-over')).toBe('true');

    // The back button returns to the panel
    fireEvent.click(screen.getByTestId('chat-context-cap-back'));
    expect(screen.getByTestId('chat-context-cap-row')).toBeTruthy();
    expect(screen.queryByTestId('chat-context-cap-follow')).toBeNull();
    cleanup();

    // Window unknown: both "Automatic" and "Unlimited" show the window-unknown note
    const mystery = { id: 'mystery-model', name: 'mystery-model', capabilities: ['text'], isAvailable: true } as unknown as AIModel;
    const mysteryProvider = { ...provider, models: [mystery] } as unknown as Provider;
    store.setState({ conversations: [{ id: 'c-mystery', messages: [] } as unknown as Conversation] });
    expect(capPresentationInputOf({ conversation: current(), preferences: {}, provider: mysteryProvider, model: mystery })?.W)
      .toBeNull();
    render(
      <ContextUsagePanel
        open
        onClose={() => {}}
        conversationId="c-mystery"
        state={null}
        sending={false}
        onNewChatWithSummary={() => {}}
        conversation={current()}
        provider={mysteryProvider}
        currentModel={mystery}
      />,
    );
    fireEvent.click(screen.getByTestId('chat-context-cap-row'));
    expect(within(screen.getByTestId('chat-context-cap-auto')).getByText(/hintWindowUnknown/)).toBeTruthy();
    expect(within(screen.getByTestId('chat-context-cap-unlimited')).getByText(/hintWindowUnknown/)).toBeTruthy();
  });

  it('cap_strings_present_in_16_locales', () => {
    const paths = [
      ...['capHeader', 'capFooter', 'rowValue', 'modeFallbackHint', 'rowValueFallback', 'modeAi'].map(
        (key) => `pages.settings.context.${key}`,
      ),
      ...[
        'auto', 'unlimited', 'custom', 'inputLabel', 'inputUnit', 'inputEcho', 'adjusted',
        'title', 'rowLimited', 'windowLine', 'windowLinePrice', 'windowLinePricePlain', 'aboveLine',
        'multBoth', 'multInput', 'multOutput', 'multSplit',
        'follow', 'followHint', 'head', 'headPriceLine', 'headUnknown', 'autoHintPriceLine', 'autoHintDefault',
        'autoHintDefaultBelowLine', 'autoHintWindow', 'unlimitedHint', 'unlimitedHintPriceLine', 'priceLineTick',
        'customOver', 'customOverPlain', 'customAt', 'customUnder', 'footer', 'sliderA11y', 'hintWindowUnknown',
      ].map((key) => `pages.chat.contextCap.${key}`),
      ...[
        'legendPriceLine', 'measuredPriceLine', 'estimatedPriceLine', 'measuredPriceLineCrossed',
        'estimatedPriceLineCrossed',
      ].map((key) => `pages.chat.contextUsage.${key}`),
    ];
    const placeholders: Record<string, string[]> = {
      'pages.settings.context.capFooter': ['{max}', '{min}'],
      'pages.settings.context.rowValue': ['{cap}', '{mode}'],
      'pages.chat.contextCap.inputEcho': ['{value}'],
      'pages.chat.contextCap.adjusted': ['{value}'],
      'pages.chat.contextCap.rowLimited': ['{value}'],
      'pages.chat.contextCap.windowLine': ['{window}'],
      'pages.chat.contextCap.windowLinePrice': ['{window}', '{line}', '{mult}'],
      'pages.chat.contextCap.windowLinePricePlain': ['{window}', '{line}'],
      'pages.chat.contextCap.aboveLine': ['{line}'],
      'pages.chat.contextCap.multBoth': ['{a}'],
      'pages.chat.contextCap.multInput': ['{a}'],
      'pages.chat.contextCap.multOutput': ['{b}'],
      'pages.chat.contextCap.multSplit': ['{a}', '{b}'],
      'pages.chat.contextCap.followHint': ['{value}'],
      'pages.chat.contextCap.head': ['{model}', '{window}', '{usable}'],
      'pages.chat.contextCap.headPriceLine': ['{head}', '{line}'],
      'pages.chat.contextCap.headUnknown': ['{model}'],
      'pages.chat.contextCap.autoHintPriceLine': ['{value}'],
      'pages.chat.contextCap.autoHintDefault': ['{value}', '{max}'],
      'pages.chat.contextCap.autoHintDefaultBelowLine': ['{value}', '{max}'],
      'pages.chat.contextCap.autoHintWindow': ['{value}'],
      'pages.chat.contextCap.unlimitedHint': ['{value}'],
      'pages.chat.contextCap.unlimitedHintPriceLine': ['{value}', '{line}'],
      'pages.chat.contextCap.priceLineTick': ['{value}'],
      'pages.chat.contextCap.customOver': ['{line}', '{mult}'],
      'pages.chat.contextCap.customOverPlain': ['{line}'],
      'pages.chat.contextCap.customUnder': ['{gap}'],
      'pages.chat.contextCap.sliderA11y': ['{value}'],
      'pages.chat.contextUsage.measuredPriceLine': ['{value}'],
      'pages.chat.contextUsage.estimatedPriceLine': ['{value}'],
    };
    const retired = LOCALES.filter(
      (locale) => getNested(readMessages(locale), 'pages.chat.contextUsage.effectiveLimit') !== undefined,
    );
    expect(retired).toEqual([]);
    const problems = LOCALES.flatMap((locale) => {
      const messages = readMessages(locale);
      return paths.flatMap((keyPath) => {
        const value = getNested(messages, keyPath);
        if (typeof value !== 'string' || value.trim().length === 0) return [`${locale}:${keyPath}`];
        return (placeholders[keyPath] ?? [])
          .filter((token) => !value.includes(token))
          .map((token) => `${locale}:${keyPath}:${token}`);
      });
    });
    expect(problems).toEqual([]);
  });
});
