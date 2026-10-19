/**
 * Suggestions inbox page (except the toggle): lists pending, with save / edit / ignore.
 * Both the candidate repository and the item repository use the real implementation (fake-indexeddb), only the item sync engine is disconnected; assertions read what the repository actually holds.
 */
import 'fake-indexeddb/auto';
import type { ReactNode } from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { MemoryCandidateRecord } from '@oriveo/core/context/memory-intent';
import type { ChatMessage, Conversation } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  showToast: vi.fn(),
  holder: { store: null as unknown },
}));

vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('next-intl', () => ({
  useTranslations: (namespace?: string) => (key: string) => (namespace ? `${namespace}.${key}` : key),
}));
vi.mock('../../../components/Toast', () => ({ showToast: (...args: unknown[]) => mocks.showToast(...args) }));
vi.mock('../../../providers/StoreProvider', async () => {
  const { useStore } = await import('zustand');
  return {
    getVanillaStore: () => mocks.holder.store,
    useAppStore: <T,>(selector: (state: AppStore) => T): T => useStore(mocks.holder.store as StoreApi<AppStore>, selector),
  };
});
vi.mock('../../../lib/core/bootstrap', () => ({ getOrCreateStableWebDeviceId: () => 'device-test' }));
// Real item repository, with only sync disconnected.
vi.mock('../../../lib/core/memory/memory-item-repository', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../lib/core/memory/memory-item-repository')>();
  return {
    ...actual,
    createMemoryItemRepository: (options: Parameters<typeof actual.createMemoryItemRepository>[0]) =>
      actual.createMemoryItemRepository({ ...options, sync: () => null }),
  };
});
vi.mock('@oriveo/ui', () => ({
  BackButton: ({ label, onClick }: { label: string; onClick?: () => void }) => (
    <button type="button" aria-label={label} onClick={onClick} />
  ),
  Button: ({ children, onClick, disabled }: { children: ReactNode; onClick?: () => void; disabled?: boolean }) => (
    <button type="button" onClick={onClick} disabled={disabled}>
      {children}
    </button>
  ),
  Dialog: ({ open, children }: { open: boolean; onClose?: () => void; children: ReactNode }) => (
    open ? <div role="dialog">{children}</div> : null
  ),
}));

import { resetDBConnection } from '../../../lib/infra/storage/idb';
import { getActiveUIDSync } from '../../../lib/infra/storage/partition';
import { getAllMemoryCandidateRows } from '../../../lib/infra/storage/memory-candidate-store';
import { createMemoryCandidateRepository } from '../../../lib/core/memory/memory-candidate-repository';
import { createMemoryItemRepository } from '../../../lib/core/memory/memory-item-repository';
import { createAppStore, type AppStore } from '../../../lib/core/store/app-store';
import { offerDirectiveSuggestion } from '../../../lib/core/chat/conversation-instructions/directive-suggestion';
import { MemoryInboxPage } from './MemoryInboxPage';

const S = 'pages.chat.memorySuggestion';
const PREFERENCE_TEXT = '\u8bb0\u4f4f\u6211\u504f\u597d\u7b80\u6d01\u56de\u7b54';
const OTHER_TEXT = '\u8bb0\u4f4f\u6211\u4f4f\u5728\u4e0a\u6d77';
const IMPLICIT_TEXT = 'In all chats, always answer in Spanish.';
const EXPLICIT_TEXT = 'Remember that I prefer metric units.';
const SWITCH_NAME = 'pages.memory.inboxAutoSuggest';

function conversation(): Conversation {
  return {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: 'p-1', providerKind: 'openAI', modelID: 'gpt-4', previewText: '',
    estimatedCost: 0, isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z',
  } as unknown as Conversation;
}

function userMessage(id: string, text: string): ChatMessage {
  return { id, role: 'user', text, createdAt: '2026-10-15T00:00:00.000Z' } as unknown as ChatMessage;
}

function setup() {
  const store = createAppStore({ conversations: [conversation()] });
  mocks.holder.store = store;
  const uid = getActiveUIDSync();
  const items = createMemoryItemRepository({ store, uid, deviceId: 'device-test' });
  const candidates = createMemoryCandidateRepository({ uid, items });
  let seq = 0;
  // Go through the real generate to land candidates; times are staggered backwards, and pending() sorts by createdAtMs descending.
  const generate = async (text: string): Promise<MemoryCandidateRecord> => {
    seq += 1;
    const created = await candidates.generate({
      text, messageId: `m-${seq}`, conversationId: 'conv-1', folderId: null, useMemory: true, nowMs: Date.now() - 10_000 + seq,
    });
    if (!created) throw new Error(`no candidate for ${text}`);
    return created;
  };
  return { store, items, candidates, generate };
}

function rowOf(content: string): HTMLElement {
  const row = screen.getByText(content).closest('li');
  if (!row) throw new Error(`no row for ${content}`);
  return row as HTMLElement;
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
  mocks.showToast.mockReset();
});

afterEach(() => {
  cleanup();
});

describe('memory inbox page', () => {
  it('inbox_lists_pending_newest_first', async () => {
    const { candidates, generate } = setup();
    const older = await generate(PREFERENCE_TEXT);
    const newer = await generate(OTHER_TEXT);
    render(<MemoryInboxPage />);

    await screen.findByText(newer.content);
    const pending = await candidates.pending();
    expect(pending.map((c) => c.id)).toEqual([newer.id, older.id]);
    expect(screen.getAllByTestId('memory-inbox-content').map((el) => el.textContent)).toEqual(pending.map((c) => c.content));
    // Body + group name, button order [Ignore][Edit][Save]
    expect(older.proposedKind).toBe('preference');
    expect(within(rowOf(older.content)).getByText('pages.memory.groupPreferences')).toBeTruthy();
    expect(within(rowOf(older.content)).getAllByRole('button').map((b) => b.textContent)).toEqual([`${S}.ignore`, `${S}.edit`, `${S}.save`]);
    expect(screen.getByText('pages.memory.inboxTitle')).toBeTruthy();
    expect(screen.getByText('pages.memory.inboxFootnote')).toBeTruthy();
    expect(screen.queryByText('pages.memory.inboxEmpty')).toBeNull();
  });

  it('inbox_save_creates_item_and_undo_deletes_it', async () => {
    const { items, candidates, generate } = setup();
    const target = await generate(PREFERENCE_TEXT);
    render(<MemoryInboxPage />);

    await screen.findByText(target.content);
    fireEvent.click(within(rowOf(target.content)).getByText(`${S}.save`));
    expect(screen.queryByText(target.content)).toBeNull();
    await waitFor(() => expect(mocks.showToast).toHaveBeenCalledTimes(1));
    const [message, duration, undo, , undoLabel] = mocks.showToast.mock.calls[0] as [string, number, () => void, string, string];
    expect([message, duration, undoLabel]).toEqual([`${S}.saved`, 5000, 'common.undo']);

    // The item is created exactly as the candidate: source / scope / confidence are unchanged
    const saved = (await items.list()).filter((m) => m.content === target.content);
    expect(saved).toHaveLength(1);
    expect(saved[0]).toMatchObject({
      kind: target.proposedKind,
      status: 'active',
      scope: target.scope,
      confidence: target.confidence,
      source: { type: 'conversation', conversationId: 'conv-1', messageIds: target.source.messageIds },
    });
    expect(await candidates.pending()).toEqual([]);
    expect(screen.getByText('pages.memory.inboxEmpty')).toBeTruthy();

    // Undo = the item repository deletes the just-created item normally
    act(() => undo());
    await waitFor(async () => expect((await items.list()).filter((m) => m.id === saved[0].id)).toEqual([]));
  });

  it('inbox_edit_saves_edited_content', async () => {
    const { items, candidates, generate } = setup();
    const target = await generate(PREFERENCE_TEXT);
    render(<MemoryInboxPage />);
    await screen.findByText(target.content);

    // Cancel: the row is still there and nothing is written to the repository
    fireEvent.click(within(rowOf(target.content)).getByText(`${S}.edit`));
    fireEvent.click(screen.getByText('common.cancel'));
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(rowOf(target.content)).toBeTruthy();

    fireEvent.click(within(rowOf(target.content)).getByText(`${S}.edit`));
    // New state, body pre-filled from the candidate, group preselected by proposedKind
    const dialog = screen.getByRole('dialog');
    expect(within(dialog).getByText('pages.memory.editorTitleNew')).toBeTruthy();
    const textbox = within(dialog).getByRole('textbox') as HTMLTextAreaElement;
    expect(textbox.value).toBe(target.content);
    expect(within(dialog).getByRole('radio', { name: 'pages.memory.groupPreferences' }).getAttribute('aria-checked')).toBe('true');

    const edited = '\u56de\u7b54\u5c3d\u91cf\u7b80\u6d01，\u5148\u7ed9\u7ed3\u8bba';
    fireEvent.change(textbox, { target: { value: edited } });
    fireEvent.click(within(dialog).getByRole('radio', { name: 'pages.memory.groupInstructions' }));
    fireEvent.click(within(dialog).getByText('pages.memory.save'));

    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.queryByText(target.content)).toBeNull();
    await waitFor(() => expect(mocks.showToast).toHaveBeenCalledTimes(1));
    expect(mocks.showToast.mock.calls[0][0]).toBe(`${S}.saved`);
    const list = await items.list();
    expect(list.filter((m) => m.content === target.content)).toEqual([]);
    const saved = list.filter((m) => m.content === edited);
    expect(saved).toHaveLength(1);
    expect(saved[0]).toMatchObject({
      kind: 'instruction',
      scope: target.scope,
      confidence: 1,
      source: { type: 'conversation', conversationId: 'conv-1', messageIds: target.source.messageIds },
    });
    expect(await candidates.pending()).toEqual([]);
  });

  it('inbox_ignore_rejects_candidate', async () => {
    const { items, candidates, generate } = setup();
    const target = await generate(PREFERENCE_TEXT);
    const kept = await generate(OTHER_TEXT);
    render(<MemoryInboxPage />);
    await screen.findByText(target.content);

    fireEvent.click(within(rowOf(target.content)).getByText(`${S}.ignore`));
    expect(screen.queryByText(target.content)).toBeNull();
    expect(screen.getByText(kept.content)).toBeTruthy();
    await waitFor(async () => {
      const rows = await getAllMemoryCandidateRows(getActiveUIDSync());
      expect(rows.find((r) => r.id === target.id)?.candidate.status).toBe('rejected');
    });
    expect((await candidates.pending()).map((c) => c.id)).toEqual([kept.id]);
    expect((await items.list()).filter((m) => m.content === target.content)).toEqual([]);
    expect(mocks.showToast).not.toHaveBeenCalled();
  });

  it('inbox_empty_shows_empty_state', async () => {
    const { candidates } = setup();
    render(<MemoryInboxPage />);

    expect(await screen.findByText('pages.memory.inboxEmpty')).toBeTruthy();
    expect(await candidates.pending()).toEqual([]);
    expect(screen.queryAllByTestId('memory-inbox-row')).toHaveLength(0);
    expect(screen.getByText('pages.memory.inboxFootnote')).toBeTruthy();
  });

  it('auto_suggest_defaults_on_and_persists', async () => {
    const { candidates, generate } = setup();
    const target = await generate(PREFERENCE_TEXT);
    const first = render(<MemoryInboxPage />);
    await screen.findByText(target.content);

    // On by default; the toggle sits above the list, with a description
    const toggle = screen.getByRole('switch', { name: SWITCH_NAME }) as HTMLInputElement;
    expect(toggle.checked).toBe(true);
    expect(candidates.autoSuggestEnabled()).toBe(true);
    expect(screen.getByText('pages.memory.inboxAutoSuggestFootnote')).toBeTruthy();
    expect(toggle.compareDocumentPosition(screen.getByText(target.content)) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    fireEvent.click(toggle);
    expect(toggle.checked).toBe(false);
    expect(candidates.autoSuggestEnabled()).toBe(false);
    // Turning it off does not delete existing pending, and the list is unchanged
    expect(screen.getByText(target.content)).toBeTruthy();
    expect((await candidates.pending()).map((c) => c.id)).toEqual([target.id]);
    first.unmount();

    // Still off after re-rendering
    render(<MemoryInboxPage />);
    await screen.findByText(target.content);
    expect((screen.getByRole('switch', { name: SWITCH_NAME }) as HTMLInputElement).checked).toBe(false);
  });

  it('auto_suggest_off_skips_implicit_keeps_explicit', async () => {
    const { store, candidates } = setup();
    render(<MemoryInboxPage />);
    await screen.findByText('pages.memory.inboxEmpty');
    fireEvent.click(screen.getByRole('switch', { name: SWITCH_NAME }));
    expect(candidates.autoSuggestEnabled()).toBe(false);

    // Go through the send entry: implicit sentences produce no candidate, an explicit "remember" works as usual
    offerDirectiveSuggestion(store, 'conv-1', userMessage('m-implicit', IMPLICIT_TEXT), 'a-implicit', 'fallback');
    offerDirectiveSuggestion(store, 'conv-1', userMessage('m-explicit', EXPLICIT_TEXT), 'a-explicit', 'fallback');
    // Two send entries each run one round of IDB reads and writes, which can exceed the default 1 s of waitFor when the machine is fully loaded
    await waitFor(async () => expect(await candidates.pending()).toHaveLength(1), { timeout: 5000 });
    const [explicit] = await candidates.pending();
    expect(explicit).toMatchObject({ status: 'pending', content: 'I prefer metric units.', source: { messageIds: ['m-explicit'] } });
    const rows = await getAllMemoryCandidateRows(getActiveUIDSync());
    expect(rows.map((r) => r.id)).toEqual([explicit.id]);
  });

  it('no_candidate_becomes_active_without_accept', async () => {
    const { items, candidates, generate } = setup();
    const target = await generate(PREFERENCE_TEXT);
    const view = render(<MemoryInboxPage />);
    await screen.findByText(target.content);
    view.unmount();

    // Neither entering nor leaving the page accepts: the candidate is still pending, and the item table does not have it
    const [pending] = await candidates.pending();
    expect(pending).toMatchObject({ id: target.id, status: 'pending' });
    expect((await items.list()).filter((m) => m.content === target.content)).toEqual([]);
  });
});
