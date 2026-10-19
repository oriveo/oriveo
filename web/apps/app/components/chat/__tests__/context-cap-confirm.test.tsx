import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { act, fireEvent, render, renderHook, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createTranslator } from 'use-intl/core';
import type { StoreApi } from 'zustand';
import type { AIModel, AppPreference, Attachment, Conversation, Provider } from '@oriveo/shared';
import { ContextBudget } from '@oriveo/core/context/budget';
import { ContextSettingsPage } from '../../../app/settings/context/ContextSettingsPage';
import { __seedMetadataCacheForTest, initMetadata } from '../../../lib/core/metadata/metadata-client';
import { capPresentationInputOf } from '../../../lib/core/chat/context-visibility/cap-presentation';
import {
  capConfirmInputOf,
  capConfirmModelName,
  capConfirmStateKey,
  capConfirmTextOf,
  decideCapConfirm,
  readCapConfirmState,
  recordCapConfirm,
  type CapConfirmDecision,
  type CapConfirmInput,
} from '../../../lib/core/chat/context-visibility/cap-confirm';
import { compactionSeparatorOf } from '../../../lib/core/chat/context-compaction/context-compaction-presentation';
import { compactionModelNameOf } from '../../../lib/core/chat/context-compaction/use-compaction-separator';
import type { ContextCheckpointRow } from '../../../lib/infra/storage/context-checkpoint-store';
import { setActiveUID } from '../../../lib/infra/storage/partition';
import {
  requestCapConfirmation,
  resolveCapConfirmation,
  type CapConfirmRequest,
} from '../../../lib/core/chat/context-visibility/cap-confirm-gate';
import { isVisibleConversation } from '../../../lib/utils/conversation-list';
import type { AppStore } from '../../../lib/core/store/app-store';
import { rollbackSendStart } from '../../../lib/core/chat/send-start';
import {
  clearDirectiveSuggestion,
  evaluateDirectiveSuggestion,
  getPendingDirectiveSuggestion,
} from '../../../lib/core/chat/conversation-instructions/directive-suggestion';
import {
  beginMemorySuggestion,
  clearMemorySuggestion,
  getPendingMemorySuggestion,
  showMemoryOffHint,
} from '../../../lib/core/chat/conversation-instructions/memory-suggestion';
import { ContextCapConfirmDialog } from '../ContextCapConfirmDialog';
import { composerAcceptsRestore } from '../composer-restore';
import { createAppStore } from '../../../lib/core/store/app-store';
import { stopStream } from '../../../lib/core/chat/stop-stream';
import { trackEvent } from '../../../lib/core/telemetry';
import { SEND_BLOCKED, useStreamChat } from '../../../lib/hooks/useStreamChat';

// Pre-send confirmation.

type MockState = {
  preferences: Partial<AppPreference>;
  setPreferences: (prefs: Partial<AppPreference>) => void;
  contextCapConfirmations?: Record<string, CapConfirmRequest>;
};

const mocks = vi.hoisted(() => ({
  routerBack: vi.fn(),
  routerPush: vi.fn(),
  routerReplace: vi.fn(),
  sendStream: vi.fn(),
  vanillaStore: null as unknown,
}));

let mockState: MockState;

vi.mock('next/navigation', () => ({
  useRouter: () => ({ back: mocks.routerBack, push: mocks.routerPush, replace: mocks.routerReplace }),
}));

vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations: (namespace: string) => (key: string) => `${namespace}.${key}`,
}));

vi.mock('../../../providers/StoreProvider', () => ({
  useAppStore: (selector: (state: MockState) => unknown) => selector(mockState),
  getVanillaStore: () => mocks.vanillaStore,
  tryGetVanillaStore: () => mocks.vanillaStore,
}));

// External dependencies of the send path (same set as the context-pipeline gate cases): the outbound transport only records calls and must not be reached.
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../../lib/core/providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../lib/core/usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../../lib/core/usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../../lib/core/sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../../lib/core/skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../../../lib/firebase/auth-service', () => ({ getCurrentUserIDToken: async () => 'id-token', getCurrentUserUID: () => 'uid-1' }));
vi.mock('../../../lib/core/chat/stop-stream', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/chat/stop-stream')>();
  return { ...actual, stopStream: vi.fn(actual.stopStream) };
});
vi.mock('../../../lib/core/telemetry', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/telemetry')>();
  return { ...actual, trackEvent: vi.fn(actual.trackEvent) };
});

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

type FixtureCase = { id: string; input: CapConfirmInput; expected: CapConfirmDecision };

const fixture = JSON.parse(
  readFileSync(repoFile('shared/context-contracts/context-cap-confirm.v1.json'), 'utf8'),
) as { cases: FixtureCase[] };

function caseOf(id: string): FixtureCase {
  const found = fixture.cases.find((c) => c.id === id);
  if (!found) throw new Error(id);
  return found;
}

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

function tCapOf(locale: string) {
  const t = createTranslator({
    locale,
    messages: readMessages(locale),
    namespace: 'pages.chat.contextCap',
  } as never) as unknown as (key: string, values?: Record<string, string>) => string;
  return (key: string, values?: Record<string, string>) => t(key, values);
}

const stripIsolates = (text: string) => text.replace(/[⁦-⁩]/g, '');

function textOf(input: CapConfirmInput, modelName: string, locale: string) {
  const decision = decideCapConfirm(input);
  const text = capConfirmTextOf(
    decision,
    { estimatedInput: input.estimatedInput, B: input.B, priceLineTokens: input.priceLineTokens, modelName, locale },
    tCapOf(locale),
  );
  return { decision, text };
}

const GROK_ID = 'grok-4.7';

// The gate's real queue: the pending request is written into mockState and the dialog reads it through useAppStore.
const gateStore = {
  getState: () => ({
    contextCapConfirmations: mockState.contextCapConfirmations ?? {},
    setContextCapConfirmation: (conversationId: string, request: CapConfirmRequest | null) => {
      const next = { ...(mockState.contextCapConfirmations ?? {}) };
      if (request) next[conversationId] = request;
      else delete next[conversationId];
      mockState = { ...mockState, contextCapConfirmations: next };
    },
  }),
} as unknown as StoreApi<AppStore>;

function askCapConfirm(id: string, caseId: string, conversationId = 'c-1') {
  const { input } = caseOf(caseId);
  return requestCapConfirmation(gateStore, {
    id,
    conversationId,
    decision: decideCapConfirm(input),
    estimatedInput: input.estimatedInput,
    B: input.B,
    priceLineTokens: input.priceLineTokens,
    modelName: 'Grok 4.7',
  }, new AbortController().signal);
}

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

const CHAT_KEYS = [
  'confirmOverCapTitle', 'confirmOverCapBody', 'confirmPriceLineTitle', 'confirmPriceLineBodyCost',
  'confirmPriceLineBodyMult', 'confirmPriceLineBody', 'confirmAlsoPriceLineCost', 'confirmAlsoPriceLineMult',
  'confirmAlsoPriceLine', 'confirmDontAsk', 'confirmSend',
];
const SETTINGS_KEYS = ['priceLineReminder', 'priceLineReminderFooter'];

describe('ContextCapConfirm', () => {
  beforeEach(async () => {
    localStorage.clear();
    await setActiveUID('guest');
    mockState = {
      preferences: {},
      setPreferences: vi.fn((prefs: Partial<AppPreference>) => {
        mockState = { ...mockState, preferences: { ...mockState.preferences, ...prefs } };
      }),
    };
  });

  it('confirm_matches_fixture', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
    for (const c of fixture.cases) {
      const actual = decideCapConfirm(c.input);
      const { cost, ...rest } = actual;
      const { cost: expectedCost, ...expectedRest } = c.expected;
      expect({ id: c.id, ...rest }).toEqual({ id: c.id, ...expectedRest });
      if (expectedCost === null) {
        expect({ id: c.id, cost }).toEqual({ id: c.id, cost: null });
      } else {
        expect(cost, c.id).not.toBeNull();
        expect(Math.abs(cost!.long - expectedCost.long), c.id).toBeLessThanOrEqual(1e-9);
        expect(Math.abs(cost!.base - expectedCost.base), c.id).toBeLessThanOrEqual(1e-9);
      }
    }
  });

  it('confirm_text_variants', () => {
    const zh = readMessages('zh-Hans');
    const cap = (key: string) => getNested(zh, `pages.chat.contextCap.${key}`) as string;

    const first = textOf(caseOf('price_line_first_cross').input, 'Grok 4.7', 'zh-Hans');
    expect(first.text?.title).toBe(cap('confirmPriceLineTitle'));
    expect(stripIsolates(first.text!.body)).toBe(
      '\u8fd9\u6b21\u7ea6 21.3\u4e07 token，\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39：\u7ea6 $0.85，\u4e0d\u8d8a\u7ebf\u7ea6 $0.43。',
    );
    expect(first.text?.showDontAsk).toBe(true);
    expect(first.text?.dontAsk).toBe(cap('confirmDontAsk'));
    expect(first.text?.confirm).toBe(cap('confirmSend'));

    const overCap = textOf(caseOf('over_cap_custom').input, 'Grok 4.7', 'zh-Hans');
    expect(overCap.text?.title).toBe(cap('confirmOverCapTitle'));
    expect(stripIsolates(overCap.text!.body)).toBe('\u8fd9\u6b21\u7ea6 15.2\u4e07 token，\u8d85\u8fc7\u6b64\u5bf9\u8bdd\u4e0a\u9650 12.8\u4e07。');
    expect(overCap.text?.showDontAsk).toBe(false);
    expect(overCap.text?.dontAsk).toBeNull();

    // Multiplier only: {multiplier} is the multiplier phrase
    const mult = textOf(caseOf('price_line_base_prompt_zero').input, 'Grok 4.7', 'zh-Hans');
    const multPhrase = stripIsolates(tCapOf('zh-Hans')('multOutput', { b: '2' }));
    expect(stripIsolates(mult.text!.body)).toBe(
      `\u8fd9\u6b21\u7ea6 21.3\u4e07 token\uff0c\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf\uff0c\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39\uff08${multPhrase}\uff09\u3002`,
    );

    // Neither amount nor multiplier
    const plain = textOf(caseOf('price_line_no_pricing').input, 'Grok 4.7', 'zh-Hans');
    expect(stripIsolates(plain.text!.body)).toBe(
      '\u8fd9\u6b21\u7ea6 21.3\u4e07 token，\u8d85\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39。',
    );

    // Both: over-cap title, the over-cap sentence joined by a line break with the "also" sentence
    const both = textOf(caseOf('over_cap_and_price_line').input, 'Grok 4.7', 'zh-Hans');
    expect(both.decision.kind).toBe('overCapAndPriceLine');
    expect(both.text?.title).toBe(cap('confirmOverCapTitle'));
    expect(stripIsolates(both.text!.body)).toBe(
      '\u8fd9\u6b21\u7ea6 26\u4e07 token，\u8d85\u8fc7\u6b64\u5bf9\u8bdd\u4e0a\u9650 24\u4e07。\n\u8fd9\u6b21\u8fd8\u4f1a\u8d8a\u8fc7 Grok 4.7 \u7684 20\u4e07 \u52a0\u4ef7\u7ebf，\u6574\u4e2a\u8bf7\u6c42\u6309\u957f\u4e0a\u4e0b\u6587\u4ef7\u8ba1\u8d39：\u7ea6 $1.04，\u4e0d\u8d8a\u7ebf\u7ea6 $0.52。',
    );
    expect(both.text?.showDontAsk).toBe(true);

    // No copy when not asking
    expect(textOf(caseOf('price_line_one_below').input, 'Grok 4.7', 'zh-Hans').text).toBeNull();
  });

  it('confirm_text_from_production_metadata', async () => {
    await seedGrokMetadata();
    // Window, price-tier line and price are not written on the model: they only come from the production metadata decode.
    const model = { id: GROK_ID, name: 'Grok 4.7', capabilities: ['text'], isAvailable: true } as unknown as AIModel;
    const provider = {
      id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [model], catalogModels: [],
    } as unknown as Provider;
    const conversation = { id: 'c-grok', messages: [] } as unknown as Conversation;
    const presentation = capPresentationInputOf({ conversation, preferences: {}, provider, model });
    expect(presentation?.priceLineTokens).toBe(200000);

    const input = capConfirmInputOf({
      presentation: presentation!,
      attempt: 'send',
      modelId: model.id,
      estimatedInput: 213000,
      preferences: {},
      conversationId: conversation.id,
    });
    expect(input.priceLineTokens).toBe(200000);
    expect(input.conversationState).toEqual({ suppressed: false, acknowledged: null });
    const decision = decideCapConfirm(input);
    expect(decision.kind).toBe('priceLine');
    expect(decision.acknowledgeOnConfirm).toEqual({ model: GROK_ID, T: 200000 });

    const text = capConfirmTextOf(
      decision,
      { estimatedInput: 213000, B: input.B, priceLineTokens: input.priceLineTokens, modelName: capConfirmModelName(model), locale: 'en' },
      tCapOf('en'),
    );
    expect(stripIsolates(text!.body)).toBe(
      'This request is about 213K tokens, past the 200K threshold for Grok 4.7, so the whole request is billed at the long-context rate: about $0.85, versus about $0.43 below it.',
    );
    expect(capConfirmModelName({ id: GROK_ID, name: '' })).toBe(GROK_ID);

    // No more asking once the master switch is off
    const off = capConfirmInputOf({
      presentation: presentation!,
      attempt: 'send',
      modelId: model.id,
      estimatedInput: 213000,
      preferences: { contextPriceLineReminderEnabled: false },
      conversationId: conversation.id,
    });
    expect(decideCapConfirm(off).kind).toBe('none');
  });

  it('confirm_state_store_roundtrip', () => {
    const id = 'c-1';
    expect(readCapConfirmState(id)).toEqual({ suppressed: false, acknowledged: null });
    const base = caseOf('price_line_first_cross').input;
    const decision = decideCapConfirm({ ...base, conversationState: readCapConfirmState(id) });
    expect(decision.kind).toBe('priceLine');

    // Confirm (unchecked): record {model, T}; the same line is not asked again
    recordCapConfirm(id, decision, false);
    expect(readCapConfirmState(id)).toEqual({ suppressed: false, acknowledged: { model: 'grok-4.7', T: 200000 } });
    expect(Object.keys(localStorage).some((key) => key.endsWith(capConfirmStateKey(id)))).toBe(true);
    expect(capConfirmStateKey(id)).toBe('context_price_line_confirm:c-1');
    expect(decideCapConfirm({ ...base, conversationState: readCapConfirmState(id) }).kind).toBe('none');
    // Switching models asks again
    expect(decideCapConfirm({ ...base, model: 'grok-4.8', conversationState: readCapConfirmState(id) }).kind).toBe(
      'priceLine',
    );

    // Confirming an over-cap-only prompt does not change state
    recordCapConfirm(id, decideCapConfirm(caseOf('over_cap_custom').input), true);
    expect(readCapConfirmState(id)).toEqual({ suppressed: false, acknowledged: { model: 'grok-4.7', T: 200000 } });

    // Check "Don't ask again for this conversation"
    const other = 'c-2';
    recordCapConfirm(other, decideCapConfirm(base), true);
    expect(readCapConfirmState(other)).toEqual({ suppressed: true, acknowledged: { model: 'grok-4.7', T: 200000 } });
    expect(decideCapConfirm({ ...base, model: 'grok-4.8', conversationState: readCapConfirmState(other) }).kind).toBe(
      'none',
    );
    // Other conversations are unaffected
    expect(readCapConfirmState('c-3')).toEqual({ suppressed: false, acknowledged: null });

    // A corrupted stored value falls back to the default
    localStorage.setItem(Object.keys(localStorage).find((key) => key.endsWith(capConfirmStateKey(id)))!, '"x"');
    expect(readCapConfirmState(id)).toEqual({ suppressed: false, acknowledged: null });
  });

  it('settings_price_line_reminder_roundtrip', () => {
    const { rerender } = render(<ContextSettingsPage />);
    const toggle = () => screen.getByRole('switch', { name: /pages\.settings\.context\.priceLineReminder$/ });
    // Default on
    expect(toggle().getAttribute('aria-checked')).toBe('true');
    expect(screen.getByText('pages.settings.context.priceLineReminderFooter')).toBeTruthy();

    fireEvent.click(toggle());
    expect(mockState.setPreferences).toHaveBeenLastCalledWith({ contextPriceLineReminderEnabled: false });
    rerender(<ContextSettingsPage />);
    expect(toggle().getAttribute('aria-checked')).toBe('false');

    fireEvent.click(toggle());
    expect(mockState.setPreferences).toHaveBeenLastCalledWith({ contextPriceLineReminderEnabled: true });
    rerender(<ContextSettingsPage />);
    expect(toggle().getAttribute('aria-checked')).toBe('true');
  });

  it('confirm_strings_present_in_16_locales', () => {
    const paths = [
      ...CHAT_KEYS.map((key) => `pages.chat.contextCap.${key}`),
      ...SETTINGS_KEYS.map((key) => `pages.settings.context.${key}`),
    ];
    const lineSentence = ['{estimate}', '{model}', '{line}'];
    const alsoSentence = ['{model}', '{line}'];
    const placeholders: Record<string, string[]> = {
      'pages.chat.contextCap.confirmOverCapBody': ['{estimate}', '{cap}'],
      'pages.chat.contextCap.confirmPriceLineBodyCost': [...lineSentence, '{cost}', '{base}'],
      'pages.chat.contextCap.confirmPriceLineBodyMult': [...lineSentence, '{multiplier}'],
      'pages.chat.contextCap.confirmPriceLineBody': lineSentence,
      'pages.chat.contextCap.confirmAlsoPriceLineCost': [...alsoSentence, '{cost}', '{base}'],
      'pages.chat.contextCap.confirmAlsoPriceLineMult': [...alsoSentence, '{multiplier}'],
      'pages.chat.contextCap.confirmAlsoPriceLine': alsoSentence,
    };
    const problems = LOCALES.flatMap((locale) => {
      const messages = readMessages(locale);
      return paths.flatMap((keyPath) => {
        const value = getNested(messages, keyPath);
        if (typeof value !== 'string' || value.trim().length === 0) return [`${locale}:${keyPath}`];
        return (placeholders[keyPath] ?? [])
          .filter((p) => !value.includes(p))
          .map((p) => `${locale}:${keyPath}:${p}`);
      });
    });
    expect(problems).toEqual([]);
  });

  it('separator_summary_uses_model_display_name', () => {
    const rho = 1;
    const messages = Array.from({ length: 6 }, (_, i) => ({
      id: `m-${i}`,
      role: i % 2 === 0 ? 'user' : 'assistant',
      text: `message ${i}`,
    }));
    const row = {
      conversationId: 'c', checkpointId: 'cp', kind: 'summary', coversFrom: 'm-0', coversTo: 'm-3', coversDigest: 'd',
      messagesCovered: 4, userMessageIds: ['m-0', 'm-2'], text: 'CONTEXT CHECKPOINT', summary: 's', language: 'en',
      model: 'gpt-x', packerVersion: '1', createdAt: 1, cost: null,
    } as ContextCheckpointRow;
    // Production lookup: find the current provider's model catalog name by id, fall back to the id when not found
    const provider = {
      id: 'p', kind: 'openai', models: [{ id: 'gpt-x', name: 'GPT X', capabilities: ['text'], isAvailable: true }],
    } as unknown as Provider;
    const lookup = compactionModelNameOf(provider);
    const named = compactionSeparatorOf(row, messages, rho, lookup);
    expect(named?.model).toBe('GPT X');
    expect(named?.after).toBe(ContextBudget.estimateMessage(row.text, rho));
    expect(compactionSeparatorOf({ ...row, model: 'gpt-y' }, messages, rho, lookup)?.model).toBe('gpt-y');
    expect(compactionSeparatorOf(row, messages, rho)?.model).toBe('gpt-x');
    expect(compactionSeparatorOf(row, messages, rho, compactionModelNameOf(undefined))?.model).toBe('gpt-x');
  });

  it('confirm_dialog_dont_ask_only_for_price_line', async () => {
    const dialog = (conversationId: string) => <ContextCapConfirmDialog conversationId={conversationId} />;

    // Price-tier line: there is a checkbox, unchecked by default; initial focus is on Cancel; checking it and clicking still sends
    const priceLine = askCapConfirm('r-1', 'price_line_first_cross');
    const { rerender } = render(dialog('c-1'));
    expect(screen.getByText('pages.chat.contextCap.confirmPriceLineTitle')).toBeTruthy();
    expect(screen.getByText('pages.chat.contextCap.confirmPriceLineBodyCost')).toBeTruthy();
    const dontAsk = screen.getByTestId('context-confirm-dont-ask') as HTMLInputElement;
    expect(dontAsk.checked).toBe(false);
    expect(screen.getByTestId('context-confirm-cancel').textContent).toBe('common.cancel');
    expect(screen.getByTestId('context-confirm-send').textContent).toBe('pages.chat.contextCap.confirmSend');
    await waitFor(() => expect(document.activeElement).toBe(screen.getByTestId('context-confirm-cancel')));
    fireEvent.click(dontAsk);
    fireEvent.click(screen.getByTestId('context-confirm-send'));
    await expect(priceLine).resolves.toEqual({ kind: 'confirm', dontAsk: true });
    rerender(dialog('c-1'));
    expect(screen.queryByTestId('context-confirm-send')).toBeNull();

    // Over-cap only: no checkbox; Esc = cancel
    const overCap = askCapConfirm('r-2', 'over_cap_custom');
    rerender(dialog('c-1'));
    expect(screen.getByText('pages.chat.contextCap.confirmOverCapTitle')).toBeTruthy();
    expect(screen.queryByTestId('context-confirm-dont-ask')).toBeNull();
    fireEvent.keyDown(document, { key: 'Escape' });
    await expect(overCap).resolves.toEqual({ kind: 'cancel' });

    // Both: there is a checkbox; sending without checking = dontAsk false
    const both = askCapConfirm('r-3', 'over_cap_and_price_line');
    rerender(dialog('c-1'));
    expect((screen.getByTestId('context-confirm-dont-ask') as HTMLInputElement).checked).toBe(false);
    fireEvent.click(screen.getByTestId('context-confirm-send'));
    await expect(both).resolves.toEqual({ kind: 'confirm', dontAsk: false });

    // Only the current conversation's is shown; clicking the backdrop = cancel
    const other = askCapConfirm('r-4', 'price_line_first_cross', 'c-9');
    rerender(dialog('c-1'));
    expect(screen.queryByTestId('context-confirm-send')).toBeNull();
    rerender(dialog('c-9'));
    expect(screen.getByTestId('context-confirm-send')).toBeTruthy();
    fireEvent.click(screen.getByRole('dialog'));
    await expect(other).resolves.toEqual({ kind: 'cancel' });
    rerender(dialog('c-9'));
    expect(screen.queryByTestId('context-confirm-send')).toBeNull();
  });

  it('composer_restored_after_cancel_only_when_empty', () => {
    const attachment = { id: 'a-1', kind: 'file', fileName: 'a.txt', mimeType: 'text/plain' } as unknown as Attachment;
    expect(composerAcceptsRestore({ text: '', attachments: [] })).toBe(true);
    expect(composerAcceptsRestore({ text: '  \n', attachments: [] })).toBe(true);
    // While waiting for the confirmation the user typed into the composer / added an attachment: not overwritten
    expect(composerAcceptsRestore({ text: 'typed while waiting', attachments: [] })).toBe(false);
    expect(composerAcceptsRestore({ text: '', attachments: [attachment] })).toBe(false);

    // The rollback also removes the "set as directive" and "save as memory?" suggestion bars hung on this send; other messages' bars stay
    const conversation = {
      id: 'c-r', createdAt: 1, updatedAt: 1,
      messages: [
        { id: 'u-old', role: 'user', text: 'hi', state: 'delivered', createdAt: 1 },
        { id: 'u-new', role: 'user', text: 'From now on, always reply in English.', state: 'delivered', createdAt: 2 },
        { id: 'a-new', role: 'assistant', text: '', state: 'streaming', createdAt: 3 },
      ],
    } as unknown as Conversation;
    const updateConversation = vi.fn();
    const store = {
      getState: () => ({ conversations: [conversation], updateConversation }),
    } as unknown as StoreApi<AppStore>;

    expect(evaluateDirectiveSuggestion({
      conversationId: 'c-r', messageId: 'u-old', text: 'From now on, always reply in English.', instructions: '',
    })).not.toBeNull();
    rollbackSendStart(store, 'c-r', ['u-new', 'a-new']);
    expect(getPendingDirectiveSuggestion()?.messageId).toBe('u-old');
    showMemoryOffHint(beginMemorySuggestion('c-r', 'u-old', 'a-old'));
    rollbackSendStart(store, 'c-r', ['u-new', 'a-new']);
    expect(getPendingMemorySuggestion()?.messageId).toBe('u-old');

    expect(evaluateDirectiveSuggestion({
      conversationId: 'c-r', messageId: 'u-new', text: 'From now on, always reply in English.', instructions: '',
    })).not.toBeNull();
    showMemoryOffHint(beginMemorySuggestion('c-r', 'u-new', 'a-new'));
    expect(getPendingMemorySuggestion()?.messageId).toBe('u-new');
    rollbackSendStart(store, 'c-r', ['u-new', 'a-new']);
    expect(getPendingDirectiveSuggestion()).toBeNull();
    expect(getPendingMemorySuggestion()).toBeNull();
    expect(updateConversation).toHaveBeenLastCalledWith('c-r', expect.objectContaining({
      messages: [conversation.messages[0]],
    }));
    clearDirectiveSuggestion();
    clearMemorySuggestion();
  });

  it('gate_stop_while_waiting_rolls_back', async () => {
    await seedGrokMetadata();
    const model = {
      id: GROK_ID, name: 'Grok 4.7', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true,
      isDefault: true, priceTier: '', transport: 'openai_chat_completions',
    } as unknown as AIModel;
    const provider = {
      id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [model], catalogModels: [],
      apiKey: 'sk-grok', apiKeyPreview: '••',
    } as unknown as Provider;
    // Tier 32000: a body of about 25,000 words is estimated over the tier, so the gate suspends and asks "over the cap".
    const conversation = {
      id: 'c-stop', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id,
      providerKind: provider.kind, previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
      contextCap: 32000, updatedAt: '2026-10-17T00:00:00.000Z', createdAt: '2026-10-17T00:00:00.000Z',
    } as unknown as Conversation;
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.vanillaStore = store;
    mocks.sendStream.mockReset();
    vi.mocked(stopStream).mockClear();
    vi.mocked(trackEvent).mockClear();

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel: model,
      conversation: store.getState().conversations[0],
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));
    const text = 'The quick brown fox jumps over the lazy dog. '.repeat(2500);
    let sending!: Promise<unknown>;
    act(() => {
      sending = result.current.send(text, [], store.getState().conversations[0]);
    });
    // Gate suspended: this pair of messages is already in the conversation, and the dialog waits for the user
    await waitFor(() => expect(store.getState().contextCapConfirmations['c-stop']?.conversationId).toBe('c-stop'), { timeout: 5000 });
    expect(store.getState().conversations[0].messages).toHaveLength(2);

    act(() => result.current.stop());
    await expect(sending).resolves.toBe(SEND_BLOCKED);

    // No chat request; this pair of messages is rolled back; stopStream was not used (not marked interrupted, not recorded as stopped)
    expect(mocks.sendStream).not.toHaveBeenCalled();
    const after = store.getState().conversations.find((c) => c.id === 'c-stop')!;
    expect(after.messages).toEqual([]);
    expect(vi.mocked(stopStream)).not.toHaveBeenCalled();
    expect(vi.mocked(trackEvent).mock.calls.some(([event]) => event === 'chat_message_stopped')).toBe(false);
    expect(store.getState().contextCapConfirmations).toEqual({});
    expect(store.getState().streamingTexts['c-stop']).toBeUndefined();
  });

  it('first_message_cancel_returns_to_draft', async () => {
    await seedGrokMetadata();
    const model = {
      id: GROK_ID, name: 'Grok 4.7', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true,
      isDefault: true, priceTier: '', transport: 'openai_chat_completions',
    } as unknown as AIModel;
    const provider = {
      id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [model], catalogModels: [],
      apiKey: 'sk-grok', apiKeyPreview: '••',
    } as unknown as Provider;
    // A new conversation follows the global default tier 32000: the first message is over the tier, so the gate suspends and asks "over the cap".
    const store = createAppStore({ providers: [provider], conversations: [] });
    store.getState().setPreferences({ contextDefaultCap: 32000 });
    mocks.vanillaStore = store;
    mocks.sendStream.mockReset();

    const { result } = renderHook(() => useStreamChat({
      provider,
      currentModel: model,
      conversation: undefined,
      messages: [],
      reasoningMode: 'automatic',
      onSendFailed: vi.fn(),
    }));
    const text = 'The quick brown fox jumps over the lazy dog. '.repeat(2500);
    let sending!: Promise<unknown>;
    act(() => {
      sending = result.current.send(text, [], undefined);
    });
    await waitFor(() => expect(Object.keys(store.getState().contextCapConfirmations)).toHaveLength(1), { timeout: 5000 });
    const [request] = Object.values(store.getState().contextCapConfirmations);
    const created = store.getState().conversations.find((c) => c.id === request.conversationId)!;
    expect(created.messages).toHaveLength(2);
    expect(isVisibleConversation(created)).toBe(true);

    act(() => resolveCapConfirmation(request.conversationId, { kind: 'cancel' }));
    await expect(sending).resolves.toBe(SEND_BLOCKED);

    // The conversation returns to a draft: no messages, absent from the list, no chat request
    const after = store.getState().conversations.find((c) => c.id === request.conversationId)!;
    expect(after.messages).toEqual([]);
    expect(after.isDraft).toBe(true);
    expect(isVisibleConversation(after)).toBe(false);
    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(store.getState().contextCapConfirmations).toEqual({});
  });
});
