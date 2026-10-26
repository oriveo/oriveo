// @vitest-environment jsdom
/**
 * The "Save to memory?" bar: production sendMessage routing + background candidate generation -> MessageList rendering;
 * the button actions [Save][Edit][Ignore] go through the real candidate repository and item repository.
 * The state module and the candidate repository both use the real implementation (fake-indexeddb), and assertions read the repository's actual result.
 * The bar hangs under that turn's assistant answer and appears once streaming ends; this file's connection is first marked as degraded, so it takes the fallback path.
 */
import 'fake-indexeddb/auto';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  showToast: vi.fn(),
  holder: { store: null as unknown },
}));

vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../lib/core/providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../lib/utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../lib/utils/chat-stream-utils')>('../../lib/utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
}));
vi.mock('../../lib/core/usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../lib/core/usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../lib/core/sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../lib/core/skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../../lib/core/metadata/metadata-client', async () => ({
  ...await vi.importActual<typeof import('../../lib/core/metadata/metadata-client')>('../../lib/core/metadata/metadata-client'),
  getMetadataRevision: () => undefined,
  getCapabilityRuntime: () => null,
  resolveGenerationProfileRef: vi.fn(() => undefined),
  resolveCatalogModel: vi.fn(),
  getDeclaredReasoningLevels: vi.fn(() => []),
  getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => null),
}));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string) => (namespace ? `${namespace}.${key}` : key),
}));
vi.mock('../../lib/hooks/useTextSelectionAnchor', () => ({ useTextSelectionAnchor: () => null }));
vi.mock('../Toast', () => ({ showToast: (...args: unknown[]) => mocks.showToast(...args) }));
// MessageList subscribes to the store: the mock is wired straight to this case's real store.
vi.mock('../../providers/StoreProvider', async () => {
  const { useStore } = await import('zustand');
  return {
    getVanillaStore: () => mocks.holder.store,
    useAppStore: <T,>(selector: (state: AppStore) => T): T => useStore(mocks.holder.store as StoreApi<AppStore>, selector),
  };
});
vi.mock('./MessageBubble', () => ({
  MessageBubble: ({ message }: { message: { text: string } }) => <div>{message.text}</div>,
}));

import { ContextContractFixture } from '@oriveo/core/context/__tests__/fixture';
import { detectDirective } from '@oriveo/core/context/directive-detector';
import { resetDBConnection } from '../../lib/infra/storage/idb';
import { getActiveUIDSync } from '../../lib/infra/storage/partition';
import { getAllMemoryCandidateRows } from '../../lib/infra/storage/memory-candidate-store';
import { createMemoryCandidateRepository } from '../../lib/core/memory/memory-candidate-repository';
import { createMemoryItemRepository } from '../../lib/core/memory/memory-item-repository';
import { createAppStore, type AppStore } from '../../lib/core/store/app-store';
import { sendMessage } from '../../lib/core/chat/operations';
import { useAppStore } from '../../providers/StoreProvider';
import {
  __resetDirectiveSuggestionForTest,
  getPendingDirectiveSuggestion,
} from '../../lib/core/chat/conversation-instructions/directive-suggestion';
import {
  __resetMemorySuggestionForTest,
  beginMemorySuggestion,
  getPendingMemorySuggestion,
  showMemoryOffHint,
} from '../../lib/core/chat/conversation-instructions/memory-suggestion';
import {
  __resetProposeMemoryDegradedForTest,
  markProposeMemoryDegraded,
} from '../../lib/core/chat/propose-memory-runtime';
import { MessageList } from './MessageList';

interface IntentCase { id: string; text: string }
const intentCases = ContextContractFixture.load<{ cases: IntentCase[] }>('memory-intent.v1.json').cases;
function caseText(id: string): string {
  const found = intentCases.find((c) => c.id === id);
  if (!found) throw new Error(`memory-intent case ${id} missing`);
  return found.text;
}

const REMEMBER = '\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54';
const BAR = 'memory-suggestion-bar';
const DIRECTIVE_BAR = 'directive-suggestion-bar';
const NO_MESSAGES: ChatMessage[] = [];

const provider = {
  id: 'p-1', kind: 'openAI', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-test', apiKeyPreview: '••test',
} as unknown as Provider;
const model = {
  id: 'gpt-4', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: 'standard',
} as AIModel;

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', providerKind: 'openAI', modelID: 'gpt-4', previewText: '',
    estimatedCost: 0, isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', ...overrides,
  } as Conversation;
}

function ChatHarness({ conversationId }: { conversationId: string }) {
  const messages = useAppStore((s) => s.conversations.find((c) => c.id === conversationId)?.messages ?? NO_MESSAGES);
  return <MessageList messages={messages} providers={[provider]} isStreaming={false} conversationId={conversationId} />;
}

function setup(conv: Conversation = conversation()) {
  const store = createAppStore({ providers: [provider], conversations: [conv] });
  mocks.holder.store = store;
  const uid = getActiveUIDSync();
  const items = createMemoryItemRepository({ store, uid, deviceId: 'device-test', sync: () => null });
  const candidates = createMemoryCandidateRepository({ uid, items });
  render(<ChatHarness conversationId={conv.id} />);
  const send = (text: string) => act(async () => {
    await sendMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
      text,
      prevMessages: store.getState().conversations.find((c) => c.id === conv.id)!.messages,
      conversation: conv, provider, model, reasoningMode: 'automatic',
    }).done;
    // Background generation publishes the suggestion bar only after the answer ends: waiting for the publish also stays inside the same act, otherwise MessageList's update emits an act() warning.
    await settleGenerate();
  });
  const lastUserMessage = () => {
    const users = store.getState().conversations.find((c) => c.id === conv.id)!.messages.filter((m) => m.role === 'user');
    return users[users.length - 1];
  };
  const lastAssistantMessage = () => {
    const replies = store.getState().conversations.find((c) => c.id === conv.id)!.messages.filter((m) => m.role === 'assistant');
    return replies[replies.length - 1];
  };
  return { store, items, candidates, send, lastUserMessage, lastAssistantMessage };
}

/** Background generation has no handle: wait for the repository row to land, then give one macrotask for the result to publish. */
async function settleGenerate() {
  await new Promise((resolve) => setTimeout(resolve, 50));
}

async function clearAllDatabases() {
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

beforeEach(async () => {
  resetDBConnection();
  await clearAllDatabases();
  localStorage.clear();
  __resetDirectiveSuggestionForTest();
  __resetMemorySuggestionForTest();
  __resetProposeMemoryDegradedForTest();
  // Fallback path: v1 memory routing still produces a candidate (on the tool path the candidate comes from propose_memory, see the next card).
  markProposeMemoryDegraded('p-1', 'gpt-4');
  Element.prototype.scrollTo = vi.fn() as never;
  Element.prototype.scrollIntoView = vi.fn();
  mocks.sendStream.mockReset();
  mocks.readStream.mockReset();
  mocks.showToast.mockReset();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hi' }]);
  mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
  mocks.readStream.mockResolvedValue({ fullText: 'ok', reasoningText: '', usage: undefined, imageAttachments: [], toolCalls: [] });
});

afterEach(() => {
  cleanup();
});

describe('memory suggestion bar', () => {
  it('memory_bar_shown_after_candidate_generated', async () => {
    const { candidates, send, lastUserMessage, lastAssistantMessage } = setup();
    await send(REMEMBER);

    const bar = await screen.findByTestId(BAR);
    const [pending] = await candidates.pending();
    expect(pending).toMatchObject({ status: 'pending', source: { messageIds: [lastUserMessage().id] } });
    expect(getPendingMemorySuggestion()).toEqual({
      status: 'candidate',
      conversationId: 'conv-1',
      messageId: lastUserMessage().id,
      assistantMessageId: lastAssistantMessage().id,
      candidate: pending,
    });
    // Prompt sentence + candidate body, button order [Ignore][Edit][Save]
    expect(within(bar).getByText('pages.chat.memorySuggestion.prompt')).toBeTruthy();
    expect(within(bar).getByText(pending.content)).toBeTruthy();
    expect(within(bar).getAllByRole('button').map((b) => b.textContent)).toEqual([
      'pages.chat.memorySuggestion.ignore', 'pages.chat.memorySuggestion.edit', 'pages.chat.memorySuggestion.save',
    ]);
    // The bar hangs after that turn's assistant answer (the candidate's source is still the user message)
    expect(bar.previousElementSibling?.textContent).toContain('ok');
    expect(bar.previousElementSibling?.textContent).not.toContain(REMEMBER);
    expect(screen.getAllByTestId(BAR)).toHaveLength(1);
    expect(screen.queryByTestId(DIRECTIVE_BAR)).toBeNull();
  });

  it('global_directive_routes_to_memory_bar', async () => {
    const text = caseText('zh_implicit_04_golden');
    const { candidates, send } = setup();
    await send(text);

    const bar = await screen.findByTestId(BAR);
    const [pending] = await candidates.pending();
    expect(within(bar).getByText(pending.content)).toBeTruthy();
    expect(getPendingDirectiveSuggestion()).toBeNull();
    expect(screen.queryByTestId(DIRECTIVE_BAR)).toBeNull();
  });

  it('conversation_directive_keeps_instruction_bar', async () => {
    // The fallback lexical bar only honors suggestionLanguages (propose-v3), so use the in-gate zh-Hans golden sentence
    const text = caseText('zh_implicit_03_golden');
    const { candidates, send, lastUserMessage } = setup();
    await send(text);

    const detection = detectDirective(text);
    if (!detection.isDirective) throw new Error('fixture is not a directive');
    expect(getPendingDirectiveSuggestion()).toEqual({
      conversationId: 'conv-1', messageId: lastUserMessage().id, sentence: detection.span.trim() || text.trim(),
    });
    expect(await screen.findByTestId(DIRECTIVE_BAR)).toBeTruthy();
    expect(screen.queryByTestId(BAR)).toBeNull();
    expect(getPendingMemorySuggestion()).toBeNull();
    expect(await candidates.pending()).toEqual([]);
  });

  it('secret_message_shows_no_bar', async () => {
    const { candidates, send } = setup();
    await send(caseText('mixed_sensitive_02'));

    expect(screen.queryByTestId(BAR)).toBeNull();
    expect(screen.queryByTestId(DIRECTIVE_BAR)).toBeNull();
    expect(getPendingMemorySuggestion()).toBeNull();
    expect(getPendingDirectiveSuggestion()).toBeNull();
    expect(await candidates.pending()).toEqual([]);
  });

  it('memory_off_shows_hint_without_candidate', async () => {
    const { candidates, send, lastUserMessage, lastAssistantMessage } = setup(conversation({ useMemory: false }));
    await send(REMEMBER);

    const bar = await screen.findByTestId(BAR);
    expect(bar.textContent).toBe('pages.chat.memorySuggestion.memoryOff');
    expect(within(bar).queryAllByRole('button')).toHaveLength(0);
    expect(getPendingMemorySuggestion()).toEqual({
      status: 'memoryOff', conversationId: 'conv-1', messageId: lastUserMessage().id, assistantMessageId: lastAssistantMessage().id,
    });
    expect(screen.queryByTestId(DIRECTIVE_BAR)).toBeNull();
    expect(await candidates.pending()).toEqual([]);
  });

  it('next_send_clears_bar_keeps_pending', async () => {
    const { candidates, send } = setup();
    await send(REMEMBER);
    await screen.findByTestId(BAR);
    const before = await candidates.pending();
    expect(before).toHaveLength(1);

    await send('What is the weather like?');
    await waitFor(() => expect(screen.queryByTestId(BAR)).toBeNull());
    expect(getPendingMemorySuggestion()).toBeNull();
    // The bar disappearing does not count as ignoring: the candidate is still pending
    expect(await candidates.pending()).toEqual(before);
  });

  it('no_candidate_becomes_active_without_accept', async () => {
    const { items, candidates, send } = setup();
    await send(REMEMBER);
    await screen.findByTestId(BAR);

    const [pending] = await candidates.pending();
    expect(pending.status).toBe('pending');
    expect((await items.list()).filter((m) => m.content === pending.content)).toEqual([]);
  });

  it('save_creates_item_and_undo_deletes_it', async () => {
    const { items, candidates, send, lastUserMessage } = setup();
    await send(REMEMBER);
    const bar = await screen.findByTestId(BAR);
    const [pending] = await candidates.pending();

    fireEvent.click(within(bar).getByText('pages.chat.memorySuggestion.save'));
    expect(screen.queryByTestId(BAR)).toBeNull();
    expect(getPendingMemorySuggestion()).toBeNull();
    await waitFor(() => expect(mocks.showToast).toHaveBeenCalledTimes(1));
    const [message, duration, undo, , undoLabel] = mocks.showToast.mock.calls[0] as [string, number, () => void, string, string];
    expect([message, duration, undoLabel]).toEqual(['pages.chat.memorySuggestion.saved', 5000, 'common.undo']);

    // The item repository creates the item from the candidate as-is: the source points to the user message that produced the candidate; scope / confidence are unchanged
    const saved = (await items.list()).filter((m) => m.content === pending.content);
    expect(saved).toHaveLength(1);
    expect(saved[0]).toMatchObject({
      kind: pending.proposedKind,
      scope: pending.scope,
      confidence: pending.confidence,
      source: { type: 'conversation', conversationId: 'conv-1', messageIds: [lastUserMessage().id] },
    });
    expect(await candidates.pending()).toEqual([]);

    // Undo = the item repository deletes the just-created item normally
    act(() => undo());
    await waitFor(async () => expect((await items.list()).filter((m) => m.id === saved[0].id)).toEqual([]));
  });

  it('edit_saves_edited_content', async () => {
    const { items, candidates, send, lastUserMessage } = setup();
    await send(REMEMBER);
    const [pending] = await candidates.pending();

    // Cancel keeps the bar
    fireEvent.click(within(await screen.findByTestId(BAR)).getByText('pages.chat.memorySuggestion.edit'));
    fireEvent.click(screen.getByText('common.cancel'));
    expect(screen.getByTestId(BAR)).toBeTruthy();
    expect(screen.queryByRole('textbox')).toBeNull();

    fireEvent.click(within(screen.getByTestId(BAR)).getByText('pages.chat.memorySuggestion.edit'));
    // Create state, body prefilled with the candidate, group preselected by proposedKind
    expect(screen.getByText('pages.memory.editorTitleNew')).toBeTruthy();
    const textbox = screen.getByRole('textbox') as HTMLTextAreaElement;
    expect(textbox.value).toBe(pending.content);
    expect(pending.proposedKind).toBe('preference');
    expect(screen.getByRole('radio', { name: 'pages.memory.groupPreferences' }).getAttribute('aria-checked')).toBe('true');

    const edited = '\u56de\u7b54\u5c3d\u91cf\u7b80\u6d01，\u5148\u7ed9\u7ed3\u8bba';
    fireEvent.change(textbox, { target: { value: edited } });
    fireEvent.click(screen.getByRole('radio', { name: 'pages.memory.groupInstructions' }));
    await act(async () => {
      fireEvent.click(screen.getByText('pages.memory.save'));
    });

    await waitFor(() => expect(mocks.showToast).toHaveBeenCalledTimes(1));
    expect(screen.queryByTestId(BAR)).toBeNull();
    expect(mocks.showToast.mock.calls[0][0]).toBe('pages.chat.memorySuggestion.saved');
    const list = await items.list();
    expect(list.filter((m) => m.content === pending.content)).toEqual([]);
    const saved = list.filter((m) => m.content === edited);
    expect(saved).toHaveLength(1);
    expect(saved[0]).toMatchObject({
      kind: 'instruction',
      scope: pending.scope,
      confidence: 1,
      source: { type: 'conversation', conversationId: 'conv-1', messageIds: [lastUserMessage().id] },
    });
    expect(await candidates.pending()).toEqual([]);
  });

  it('ignore_rejects_candidate', async () => {
    const { items, candidates, send } = setup();
    await send(REMEMBER);
    const bar = await screen.findByTestId(BAR);
    const [pending] = await candidates.pending();

    fireEvent.click(within(bar).getByText('pages.chat.memorySuggestion.ignore'));
    expect(screen.queryByTestId(BAR)).toBeNull();
    expect(getPendingMemorySuggestion()).toBeNull();
    await waitFor(async () => {
      const rows = await getAllMemoryCandidateRows(getActiveUIDSync());
      expect(rows.map((r) => [r.id, r.candidate.status])).toEqual([[pending.id, 'rejected']]);
    });
    expect(await candidates.pending()).toEqual([]);
    expect((await items.list()).filter((m) => m.content === pending.content)).toEqual([]);
    expect(mocks.showToast).not.toHaveBeenCalled();
  });

  it('the bar hangs under the assistant answer', async () => {
    const user: ChatMessage = { id: 'u-1', role: 'user', text: REMEMBER, createdAt: '2026-10-15T00:00:00.000Z' } as ChatMessage;
    const reply: ChatMessage = {
      id: 'a-1', role: 'assistant', text: 'partial answer', state: 'generating', createdAt: '2026-10-15T00:00:01.000Z',
    } as ChatMessage;
    const { store } = setup(conversation({ messages: [user, reply] }));
    act(() => showMemoryOffHint(beginMemorySuggestion('conv-1', 'u-1', 'a-1')));

    // Not shown while streaming
    expect(getPendingMemorySuggestion()?.assistantMessageId).toBe('a-1');
    expect(screen.queryByTestId(BAR)).toBeNull();

    act(() => {
      store.setState((s) => ({
        conversations: s.conversations.map((c) => (c.id === 'conv-1'
          ? { ...c, messages: [user, { ...reply, text: 'final answer', state: 'delivered' as const }] }
          : c)),
      }));
    });
    const bar = await screen.findByTestId(BAR);
    expect(bar.previousElementSibling?.textContent).toContain('final answer');
    expect(screen.getAllByTestId(BAR)).toHaveLength(1);
  });
});
