import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Transcript separator row: MessageList inserts a separator row after coversTo and before the next message;
 * it is recomputed after the store changes (subscribeCheckpointChanges). Rows are persisted through the real ContextCompactionStore, and the display model goes through the production hook.
 */
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  appState: { conversations: [] as unknown[], streamingTexts: {} as Record<string, string> },
}));

vi.mock('next/navigation', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('next-intl', () => ({
  useLocale: () => 'en',
  useTranslations:
    (namespace?: string) =>
    (key: string, values?: Record<string, unknown>) =>
      `${namespace ?? ''}.${key}${values ? JSON.stringify(values) : ''}`,
}));
vi.mock('../../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => null,
  tryGetVanillaStore: () => null,
  useAppStore: (selector: (state: typeof mocks.appState) => unknown) => selector(mocks.appState),
}));
vi.mock('../../../../hooks/useTextSelectionAnchor', () => ({ useTextSelectionAnchor: () => null }));
vi.mock('../../../../../components/Toast', () => ({ showToast: vi.fn() }));
vi.mock('../../../../../components/notes/note-toast', () => ({ showSavedNoteToast: vi.fn() }));
vi.mock('../../../sync-port', () => ({ getSyncAdapter: () => null }));
vi.mock('../../../../../components/chat/MessageListItem', () => ({
  MessageListItem: ({ message }: { message: { id: string; text: string } }) => (
    <div data-testid="message-item" data-message-id={message.id}>
      {message.text}
    </div>
  ),
}));

import { ContextCheckpoint } from '@oriveo/core/context/checkpoint';
import { MessageList } from '../../../../../components/chat/MessageList';
import { resetDBConnection } from '../../../../infra/storage/idb';
import { setActiveUID } from '../../../../infra/storage/partition';
import type { ContextCheckpointRow } from '../../../../infra/storage/context-checkpoint-store';
import { ContextCompactionStore } from '../context-compaction-store';

const CONV = 'conv-separator';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function history(count: number): ChatMessage[] {
  return Array.from({ length: count }, (_, i) => ({
    id: `m-${i}`,
    role: i % 2 === 0 ? 'user' : 'assistant',
    text: `${i % 2 === 0 ? 'question' : 'answer'} ${i} ${'x'.repeat(200)}`,
    state: 'delivered',
    createdAt: new Date(1_700_000_000_000 + i * 1000).toISOString(),
  })) as unknown as ChatMessage[];
}

function rowCovering(messages: ChatMessage[], coversToIndex: number): ContextCheckpointRow {
  const covered = messages.slice(0, coversToIndex + 1);
  return {
    conversationId: CONV,
    checkpointId: 'cp-1',
    kind: 'summary',
    coversFrom: covered[0].id,
    coversTo: covered[coversToIndex].id,
    coversDigest: ContextCheckpoint.coversDigest(covered.map((m) => ({ id: m.id, text: m.text ?? '' }))),
    messagesCovered: covered.length,
    userMessageIds: covered.filter((m) => m.role === 'user').map((m) => m.id),
    text: 'CONTEXT CHECKPOINT\n## Goal\ng',
    summary: '## Goal\ng',
    language: 'en',
    model: 'gpt-x',
    packerVersion: '1',
    createdAt: 1_700_000_000_000,
    cost: null,
  };
}

function renderList(messages: ChatMessage[], onOpen = vi.fn()) {
  mocks.appState.conversations = [{ id: CONV, messages, providerID: 'p-1', modelID: 'gpt-x' }];
  return render(
    <MessageList
      messages={messages}
      providers={[]}
      isStreaming={false}
      conversationId={CONV}
      onOpenCompactionDetail={onOpen}
    />,
  );
}

beforeEach(async () => {
  localStorage.clear();
  resetDBConnection();
  await clearAllDatabases();
  await setActiveUID('guest');
  Element.prototype.scrollTo = vi.fn() as never;
  Element.prototype.scrollIntoView = vi.fn();
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver;
});

afterEach(() => {
  mocks.appState.conversations = [];
  localStorage.clear();
});

describe('transcript compaction separator', () => {
  it('transcript_separator_anchor', async () => {
    const messages = history(8);
    const row = rowCovering(messages, 3);
    await ContextCompactionStore.put(row);
    const onOpen = vi.fn();
    renderList(messages, onOpen);

    const separator = await screen.findByTestId('compaction-separator');
    expect(separator.tagName).toBe('BUTTON');
    expect((separator.previousElementSibling as HTMLElement).dataset.messageId).toBe('m-3');
    expect((separator.nextElementSibling as HTMLElement).dataset.messageId).toBe('m-4');
    // Messages above the separator row render as usual
    expect(screen.getAllByTestId('message-item')).toHaveLength(8);
    expect(separator.getAttribute('aria-label')).toContain('pages.chat.contextCompaction.summaryLine1');
    expect(separator.getAttribute('aria-label')).toContain('pages.chat.contextCompaction.summaryLine2');
    expect(separator.textContent).toContain('"count":4');
    expect(separator.textContent).toContain('"model":"gpt-x"');

    fireEvent.click(separator);
    expect(onOpen).toHaveBeenCalledWith(expect.objectContaining({ checkpointId: 'cp-1', coversTo: 'm-3' }));
  });

  it('transcript_separator_refreshes_on_change', async () => {
    const messages = history(8);
    renderList(messages);
    // No row: nothing is drawn
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    expect(screen.queryByTestId('compaction-separator')).toBeNull();

    await act(async () => {
      await ContextCompactionStore.put(rowCovering(messages, 5));
    });
    const separator = await screen.findByTestId('compaction-separator');
    expect((separator.previousElementSibling as HTMLElement).dataset.messageId).toBe('m-5');

    await act(async () => {
      await ContextCompactionStore.deleteAll(CONV);
    });
    await waitFor(() => expect(screen.queryByTestId('compaction-separator')).toBeNull());
  });
});
