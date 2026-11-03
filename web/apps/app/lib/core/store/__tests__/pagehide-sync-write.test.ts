import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { createAppStore } from '../app-store';
import { subscribeConversations } from '../persistence-subscribers';
import {
  putConversation,
  getConversationById,
  resetDBConnection,
} from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';
import type { ChatMessage, Conversation } from '@oriveo/shared';

// Real fake-indexeddb, no idb mock: leaving the page must issue the IndexedDB put inside the
// pagehide call stack, because the browser may tear the page down before any await resumes.

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: 'm1',
    role: 'assistant',
    content: 'partial',
    state: 'done',
    ...overrides,
  } as ChatMessage;
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'T',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function readwriteConversationTransactions(spy: { mock: { calls: unknown[][] } }): number {
  return spy.mock.calls.filter(([stores, mode]) => {
    const names = Array.isArray(stores) ? stores : [stores];
    return mode === 'readwrite' && names.includes('conversations');
  }).length;
}

describe('pagehide flushes the pending conversation write synchronously', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });
  afterEach(() => {
    vi.restoreAllMocks();
    resetDBConnection();
  });

  it('pagehide_issues_put_synchronously', async () => {
    const seeded = makeConversation({ id: 'c1', messages: [makeMessage({ content: 'partial' })] });
    // Opens the partition database, so a cached connection exists before the page is left.
    await putConversation(seeded);
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready', conversations: [seeded] });
    const unsub = subscribeConversations(store);

    store.setState({
      conversations: [{ ...seeded, messages: [makeMessage({ content: 'final reply' })] }],
    });
    const transaction = vi.spyOn(IDBDatabase.prototype, 'transaction');
    window.dispatchEvent(new Event('pagehide'));

    // No await between the dispatch and this assertion: the put must already be queued.
    expect(readwriteConversationTransactions(transaction)).toBe(1);
    unsub();
    transaction.mockRestore();

    const stored = await getConversationById('c1');
    expect(stored?.messages.map((m) => (m as unknown as { content: string }).content)).toEqual(['final reply']);
  });

  it('pagehide_commits_put_in_same_call_stack', async () => {
    const seeded = makeConversation({ id: 'c3', messages: [makeMessage({ content: 'partial' })] });
    await putConversation(seeded);
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready', conversations: [seeded] });
    const unsub = subscribeConversations(store);

    store.setState({
      conversations: [{ ...seeded, messages: [makeMessage({ content: 'final reply' })] }],
    });
    // Auto-commit waits for the put's success event to reach the page; a page torn down before that
    // never commits, so the transaction is aborted. An explicit commit() is sent with the put.
    const commit = vi.spyOn(IDBTransaction.prototype, 'commit');
    window.dispatchEvent(new Event('pagehide'));

    expect(commit).toHaveBeenCalledTimes(1);
    unsub();
    commit.mockRestore();

    const stored = await getConversationById('c3');
    expect(stored?.messages.map((m) => (m as unknown as { content: string }).content)).toEqual(['final reply']);
  });

  it('summary_only_conversation_keeps_async_path', async () => {
    const seeded = makeConversation({
      id: 'c2',
      title: 'old title',
      messages: [makeMessage({ id: 'm-kept', content: 'stored body' })],
      remoteMessageCount: 1,
    });
    await putConversation(seeded);
    const summary = { ...seeded, messages: [] };
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready', conversations: [summary] });
    const unsub = subscribeConversations(store);

    store.setState({ conversations: [{ ...summary, title: 'new title' }] });
    const transaction = vi.spyOn(IDBDatabase.prototype, 'transaction');
    window.dispatchEvent(new Event('pagehide'));

    expect(readwriteConversationTransactions(transaction)).toBe(0);
    unsub();
    transaction.mockRestore();

    await vi.waitFor(async () => {
      const stored = await getConversationById('c2');
      expect(stored?.title).toBe('new title');
    });
    const stored = await getConversationById('c2');
    expect(stored?.messages.map((m) => m.id)).toEqual(['m-kept']);
  });
});
