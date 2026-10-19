// @vitest-environment jsdom
//
// Conversation settings: draft instructions, save on close, inherit source, 16-locale copy.
// Assertions go through the real store (createAppStore) and the conversation object produced by prepareSendStart.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { act, fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import { useStore } from 'zustand';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

import { createAppStore } from '../../../store/app-store';
import { prepareSendStart } from '../../send-start';
import { createUserMessage } from '../../message-factory';
import { carryOverSource, commitConversationSettings, instructionsBadgeVisible, settingsSaveValue } from '../conversation-settings';
import { ConversationSettingsDialog } from '../../../../../components/chat/ConversationSettingsDialog';

const testStore = vi.hoisted(() => ({ current: null as unknown }));

vi.mock('next-intl', () => ({
  useTranslations: () => (key: string) => key,
  useLocale: () => 'en',
}));

vi.mock('../../../../../providers/StoreProvider', () => ({
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  useAppStore: (selector: (s: any) => unknown) => useStore(testStore.current as any, selector),
  getVanillaStore: () => testStore.current,
}));

vi.mock('../../../telemetry', () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: () => 'openRouter',
  telemetryModelID: () => 'gpt-4',
}));

const provider: Provider = {
  id: 'p1', kind: 'openRouter', name: 'OpenRouter',
  apiKey: 'sk-test', apiKeyPreview: 'sk-...test',
  status: { kind: 'connected' },
  models: [], catalogModels: [],
  createdAt: '', updatedAt: '',
};

const model: AIModel = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'],
  reasoningModeAvailable: false, isAvailable: true, isDefault: false,
  priceTier: '$$', groupKey: 'openai', groupName: 'OpenAI',
};

function conv(id: string, updatedAt: string, instructions?: string): Conversation {
  return {
    id,
    title: id,
    hasCustomTitle: false,
    providerID: 'p1',
    providerKind: 'openRouter',
    modelID: 'gpt-4',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt,
    createdAt: updatedAt,
    ...(instructions !== undefined ? { instructions } : {}),
  };
}

const C1 = '11111111-1111-4111-8111-111111111111';
const C2 = '22222222-2222-4222-8222-222222222222';
const C3 = '33333333-3333-4333-8333-333333333333';

describe('conversation settings', () => {
  it('settings_draft_instructions_written_on_create', () => {
    const store = createAppStore();
    // Row not created yet: closing the Dialog writes the store draft (normalized).
    commitConversationSettings(store, null, '', '  Write in Arabic  ');
    expect(store.getState().draftConversationInstructions).toBe('  Write in Arabic  ');

    const userMsg: ChatMessage = createUserMessage({ text: 'hi', provider, model });
    const assistantMsg = { ...userMsg, id: 'a1', role: 'assistant' as const, text: '' };
    const { finalConvId, initialConversationSnapshot } = prepareSendStart({
      store,
      userMsg,
      assistantMsg,
      prevMessages: [],
      conversation: undefined,
      provider,
      model,
      reasoningMode: 'off' as never,
      webSearchEnabled: undefined,
      attachments: undefined,
      skillId: undefined,
    });
    // On first send the instructions are written into the object before it is stored.
    expect(initialConversationSnapshot?.instructions).toBe('  Write in Arabic  ');
    const stored = store.getState().conversations.find((c) => c.id === finalConvId);
    expect(stored?.instructions).toBe('  Write in Arabic  ');
    // Cleared after consumption.
    expect(store.getState().draftConversationInstructions).toBe('');
  });

  it('draft clears when active conversation changes', () => {
    const store = createAppStore();
    store.getState().setDraftConversationInstructions('x');
    store.getState().setActiveConversationId(C1);
    expect(store.getState().draftConversationInstructions).toBe('');
  });

  it('settings_save_normalizes_on_close', () => {
    // Whitespace only -> ''; over 8000 code points is truncated; unchanged -> null (no write).
    expect(settingsSaveValue('', '   \n ')).toBeNull();
    expect(settingsSaveValue('abc', '  \n')).toBe('');
    expect(settingsSaveValue('abc', 'abc')).toBeNull();
    expect([...(settingsSaveValue('', '😀'.repeat(8001)) ?? '')].length).toBe(8000);

    const store = createAppStore({ conversations: [conv(C1, '2026-10-15T00:00:00.000Z', 'old')] });
    const spy = vi.spyOn(store.getState(), 'updateConversation');
    commitConversationSettings(store, C1, 'old', 'old');
    expect(spy).not.toHaveBeenCalled();
    commitConversationSettings(store, C1, 'old', '\t ');
    expect(store.getState().conversations[0].instructions).toBe('');
  });

  it('settings_carry_over_source_is_latest_other_conversation', () => {
    const list = [
      conv(C1, '2026-10-15T03:00:00.000Z', 'current-newest'),
      conv(C2, '2026-10-15T02:00:00.000Z', 'latest-other'),
      conv(C3, '2026-10-15T01:00:00.000Z', 'older'),
    ];
    expect(carryOverSource(list, C1, '')).toBe('latest-other');
    // Draft (no current conversation): take the latest across all conversations.
    expect(carryOverSource(list, null, '')).toBe('current-newest');
    // If the latest other conversation has empty instructions -> not shown (do not look further).
    const emptyLatest = [conv(C1, '2026-10-15T03:00:00.000Z'), conv(C2, '2026-10-15T02:00:00.000Z', ''), conv(C3, '2026-10-15T01:00:00.000Z', 'older')];
    expect(carryOverSource(emptyLatest, C1, '')).toBeNull();
  });

  it('settings_carry_over_hidden_when_current_non_empty', () => {
    const list = [conv(C1, '2026-10-15T01:00:00.000Z', 'mine'), conv(C2, '2026-10-15T02:00:00.000Z', 'other')];
    expect(carryOverSource(list, C1, 'mine')).toBeNull();
    expect(carryOverSource(list, C1, '')).toBe('other');
  });

  it('settings_badge_visible_for_draft_instructions', () => {
    const store = createAppStore();
    expect(instructionsBadgeVisible(undefined, store.getState().draftConversationInstructions)).toBe(false);
    commitConversationSettings(store, null, '', 'Write in Arabic');
    expect(instructionsBadgeVisible(undefined, store.getState().draftConversationInstructions)).toBe(true);
    // A whitespace-only draft is not shown; with a conversation, look at the conversation itself.
    expect(instructionsBadgeVisible(undefined, ' \n')).toBe(false);
    expect(instructionsBadgeVisible(conv(C1, '2026-10-15T00:00:00.000Z'), 'Write in Arabic')).toBe(false);
    expect(instructionsBadgeVisible(conv(C1, '2026-10-15T00:00:00.000Z', 'x'), '')).toBe(true);
  });

  it('settings_close_without_edit_keeps_remote_change', () => {
    const store = createAppStore({ conversations: [conv(C1, '2026-10-15T00:00:00.000Z', 'old')] });
    testStore.current = store;
    const Harness = () => {
      const c = useStore(store, (s) => s.conversations[0]);
      return <ConversationSettingsDialog open conversation={c} onClose={() => {}} />;
    };
    render(<Harness />);
    expect((screen.getByRole('textbox') as HTMLTextAreaElement).value).toBe('old');
    // The remote changed the instructions while open, and the user did not touch the edit box.
    act(() => store.getState().updateConversation(C1, { instructions: 'remote' }));
    fireEvent.click(screen.getByText('done'));
    expect(store.getState().conversations[0].instructions).toBe('remote');
  });

  it('settings_memory_switch_follows_memory_items', () => {
    // The toggle only appears when there is an active semantic memory item (same condition as the top-bar memory indicator), no longer depending on memoryText.
    const store = createAppStore({ conversations: [conv(C1, '2026-10-15T00:00:00.000Z', '')] });
    testStore.current = store;
    const { rerender } = render(<ConversationSettingsDialog open conversation={store.getState().conversations[0]} hasMemory={false} onClose={() => {}} />);
    expect(screen.queryByText('conversationUseMemory')).toBeNull();
    rerender(<ConversationSettingsDialog open conversation={store.getState().conversations[0]} hasMemory onClose={() => {}} />);
    expect(screen.getAllByText('conversationUseMemory').length).toBeGreaterThan(0);
  });

  it('strings_present_in_16_locales', () => {
    const locales = ['zh-Hans', 'en', 'zh-Hant', 'ja', 'ko', 'de', 'fr', 'es', 'pt-BR', 'ru', 'tr', 'ar', 'hi', 'vi', 'id', 'th'];
    const settingsKeys = ['title', 'instructionsHeader', 'instructionsPlaceholder', 'instructionsFooter', 'carryOver', 'usage', 'badge', 'badgeA11y'];
    const suggestionKeys = ['prompt', 'accept', 'ignore', 'added'];
    const memorySuggestionKeys = ['prompt', 'save', 'edit', 'ignore', 'saved', 'failed', 'memoryOff'];
    const memoryInboxKeys = [
      'inboxTitle',
      'inboxEmpty',
      'inboxFootnote',
      'inboxAutoSuggest',
      'inboxAutoSuggestFootnote',
      'extractionTitleDraft',
      'extractionTitleOrganize',
      'extractionModel',
      'extractionScopeDraft',
      'extractionScopeOrganize',
      'extractionNoFallback',
      'extractionSend',
    ];
    for (const locale of locales) {
      const messages = JSON.parse(readFileSync(join(__dirname, '../../../../../messages', `${locale}.json`), 'utf8'));
      const chat = messages.pages.chat;
      for (const key of settingsKeys) {
        expect(typeof chat.conversationSettings?.[key], `${locale}.conversationSettings.${key}`).toBe('string');
        expect(chat.conversationSettings[key].trim()).not.toBe('');
      }
      for (const key of suggestionKeys) {
        expect(typeof chat.directiveSuggestion?.[key], `${locale}.directiveSuggestion.${key}`).toBe('string');
        expect(chat.directiveSuggestion[key].trim()).not.toBe('');
      }
      for (const key of memorySuggestionKeys) {
        expect(typeof chat.memorySuggestion?.[key], `${locale}.memorySuggestion.${key}`).toBe('string');
        expect(chat.memorySuggestion[key].trim()).not.toBe('');
      }
      for (const key of memoryInboxKeys) {
        expect(typeof messages.pages.memory?.[key], `${locale}.memory.${key}`).toBe('string');
        expect(messages.pages.memory[key].trim()).not.toBe('');
      }
    }
    const en = JSON.parse(readFileSync(join(__dirname, '../../../../../messages', 'en.json'), 'utf8')).pages.chat;
    expect(en.conversationSettings.title).toBe('Chat Settings');
    expect(en.directiveSuggestion.added).toBe("Added to this chat's instructions");
  });
});
