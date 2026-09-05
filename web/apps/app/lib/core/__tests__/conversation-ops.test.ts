import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';
import {
  cleanupConflictCopies,
  cloneConversationFromConflictCopy,
  deleteConversation,
  deleteConversations,
  pinNoteToConversation,
  updateConversationTitle,
  updateConversationModel,
} from '../conversation-ops';

const mockSyncAdapter = {
  didDeleteConversations: vi.fn(),
  didUpdateConversationTitle: vi.fn(),
  didUpdateConversationModel: vi.fn(),
  didUpdateConversationPinnedNotes: vi.fn(),
};

// Deletion does not call the adapter directly: the intent is queued in IDB and replayed by the flusher, so nothing is lost while the adapter is null.
const mockFlushPendingDeletions = vi.fn(async () => {});
const mockDeleteLocalConversationContinuation = vi.fn();

vi.mock('../sync-port', () => ({
  getSyncAdapter: vi.fn(() => mockSyncAdapter),
  flushPendingConversationDeletions: (...args: unknown[]) =>
    (mockFlushPendingDeletions as (...a: unknown[]) => Promise<void>)(...args),
}));
vi.mock('../chat/continuation-lifecycle', () => ({
  deleteLocalConversationContinuation: (...args: unknown[]) => mockDeleteLocalConversationContinuation(...args),
}));

const makeConv = (id: string): Conversation => ({
  id, title: `Conv ${id}`, hasCustomTitle: false,
  providerID: 'p1', providerKind: 'openAI', modelID: 'm1',
  previewText: '', estimatedCost: 0, isDraft: false,
  messages: [], draftText: '',
  updatedAt: '', createdAt: '',
});

describe('conversation-ops', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    store.getState().addConversation(makeConv('c1'));
    store.getState().addConversation(makeConv('c2'));
    vi.clearAllMocks();
  });

  it('deleteConversation queues the delete intent for replay alongside store.removeConversation', () => {
    deleteConversation(store, 'c1');
    expect(store.getState().conversations.find((c) => c.id === 'c1')).toBeUndefined();
    expect(mockFlushPendingDeletions).toHaveBeenCalledWith(['c1']);
    expect(mockDeleteLocalConversationContinuation).toHaveBeenCalledWith('c1');
  });

  it('deleteConversations deletes in bulk and enqueues one replay', () => {
    deleteConversations(store, ['c1', 'c2']);
    expect(store.getState().conversations).toHaveLength(0);
    expect(mockFlushPendingDeletions).toHaveBeenCalledWith(['c1', 'c2']);
  });

  it('updateConversationTitle — store + sync.didUpdateConversationTitle', () => {
    updateConversationTitle(store, 'c1', '  New Title  ');
    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    expect(conv.title).toBe('New Title');
    expect(conv.hasCustomTitle).toBe(true);
    expect(mockSyncAdapter.didUpdateConversationTitle).toHaveBeenCalledWith('c1', 'New Title');
  });

  it('updateConversationModel updates the store and calls sync.didUpdateConversationModel with providerKind and relayKind', () => {
    const provider: Provider = {
      id: 'p2', kind: 'anthropic', status: { kind: 'connected' },
      models: [], catalogModels: [], apiKey: 'sk-x', apiKeyPreview: '••••x',
    };
    store.getState().addProvider(provider);

    updateConversationModel(store, 'c1', 'claude-3', 'p2');
    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    expect(conv.modelID).toBe('claude-3');
    expect(conv.providerID).toBe('p2');
    expect(conv.providerKind).toBe('anthropic');
    expect(conv.relayKind).toBeUndefined();
    expect(mockSyncAdapter.didUpdateConversationModel).toHaveBeenCalledWith('c1', 'claude-3', 'p2', 'anthropic', null);
  });

  it('updateConversationModel writes both providerKind and relayKind for a Relay provider', () => {
    const relayProvider: Provider = {
      id: 'r1', kind: 'relay', status: { kind: 'connected' },
      models: [], catalogModels: [], apiKey: 'sk-r', apiKeyPreview: '••••r',
      relayKind: 'anthropic_compatible',
    };
    store.getState().addProvider(relayProvider);

    updateConversationModel(store, 'c1', 'claude-bridge', 'r1');
    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    expect(conv.providerKind).toBe('relay');
    expect(conv.relayKind).toBe('anthropic_compatible');
    expect(mockSyncAdapter.didUpdateConversationModel).toHaveBeenCalledWith('c1', 'claude-bridge', 'r1', 'relay', 'anthropic_compatible');
  });

  it('updateConversationModel clears a stale relayKind when switching from Relay to a non-Relay provider', () => {
    // Point c1 at a Relay provider first.
    store.getState().updateConversation('c1', { providerKind: 'relay', relayKind: 'anthropic_compatible' });

    const officialProvider: Provider = {
      id: 'p2', kind: 'openAI', status: { kind: 'connected' },
      models: [], catalogModels: [], apiKey: 'sk-x', apiKeyPreview: '••••x',
    };
    store.getState().addProvider(officialProvider);

    updateConversationModel(store, 'c1', 'gpt-4', 'p2');
    const conv = store.getState().conversations.find((c) => c.id === 'c1')!;
    expect(conv.providerKind).toBe('openAI');
    expect(conv.relayKind).toBeUndefined();
    expect(mockSyncAdapter.didUpdateConversationModel).toHaveBeenCalledWith('c1', 'gpt-4', 'p2', 'openAI', null);
  });

  it('updateConversationModel fails fast when the provider is missing, since dirty data must not be stored', () => {
    expect(() => updateConversationModel(store, 'c1', 'gpt-4', 'p-missing')).toThrow(/provider not found/);
    expect(mockSyncAdapter.didUpdateConversationModel).not.toHaveBeenCalled();
  });

  it('pinNoteToConversation keeps the three newest notes and dedupes by normalized id', () => {
    const a = '11111111-1111-4111-8111-111111111111';
    const b = '22222222-2222-4222-8222-222222222222';
    const c = '33333333-3333-4333-8333-333333333333';
    const d = '44444444-4444-4444-8444-444444444444';
    store.getState().updateConversation('c1', { pinnedNoteIds: [a.toLowerCase(), b, c] });

    const changed = pinNoteToConversation(store, 'c1', d.toLowerCase());

    expect(changed).toBe(true);
    expect(store.getState().conversations.find((conv) => conv.id === 'c1')?.pinnedNoteIds).toEqual([
      b,
      c,
      d,
    ]);
    expect(mockSyncAdapter.didUpdateConversationPinnedNotes).toHaveBeenCalledWith('c1', [b, c, d]);

    expect(pinNoteToConversation(store, 'c1', c.toLowerCase())).toBe(false);
    expect(mockSyncAdapter.didUpdateConversationPinnedNotes).toHaveBeenCalledTimes(1);
  });

  it('cloneConversationFromConflictCopy assigns a new id, strips the conflict prefix and clears the copy marker', () => {
    const conflict: Conversation = {
      ...makeConv('orig-1'),
      id: 'copy-1',
      title: '🔀 Conflict sample',
      isConflictCopy: true,
      conflictOriginId: 'orig-1',
      messages: [],
    };
    store.getState().addConversation(conflict);

    const newId = cloneConversationFromConflictCopy(store, conflict);
    expect(newId).not.toBe('copy-1');

    const cloned = store.getState().conversations.find((c) => c.id === newId)!;
    expect(cloned.title).toBe('Conflict sample');
    expect(cloned.isConflictCopy).toBe(false);
    expect(cloned.conflictOriginId).toBeUndefined();
    expect(cloned.isDraft).toBe(false);
  });

  it('cloneConversationFromConflictCopy clears attachments.storageRef to avoid dangling references', () => {
    // Regression test against the existing cleanup path: once a conflict copy has been cloned into a new
    // conversation, deleting the copy runs deleteConversationAttachments and removes the Cloud Storage
    // object. If the clone shared the original storageRef, its attachments would dangle. The clone must
    // deep-copy messages and clear storageRef so attachment-sync uploads an independent cloud object on
    // the new conversation's first send.
    const conflict: Conversation = {
      ...makeConv('orig-1'),
      id: 'copy-shared',
      title: '🔀 Has attachments',
      isConflictCopy: true,
      conflictOriginId: 'orig-1',
      messages: [
        {
          id: 'm1',
          role: 'user',
          content: 'with attachment',
          createdAt: new Date().toISOString(),
          attachments: [{
            id: 'a1',
            kind: 'image',
            name: 'pic.jpg',
            sizeBytes: 1024,
            dataURI: 'data:image/jpeg;base64,xxx',
            storageRef: 'users/uid/attachments/a1.jpg',
          }],
        } as Conversation['messages'][number],
      ],
    };
    store.getState().addConversation(conflict);

    const newId = cloneConversationFromConflictCopy(store, conflict);
    const cloned = store.getState().conversations.find((c) => c.id === newId)!;

    // The clone gets its own messages array (deep copy), and a fresh attachments array too.
    expect(cloned.messages).not.toBe(conflict.messages);
    expect(cloned.messages[0]).not.toBe(conflict.messages[0]);
    expect(cloned.messages[0].attachments).not.toBe(conflict.messages[0].attachments);
    // storageRef must be cleared to avoid a dangling reference.
    expect(cloned.messages[0].attachments?.[0].storageRef).toBeUndefined();
    // The original conflict copy keeps its storageRef.
    const original = store.getState().conversations.find((c) => c.id === 'copy-shared')!;
    expect(original.messages[0].attachments?.[0].storageRef).toBe('users/uid/attachments/a1.jpg');
    // Local attachment data is kept so the UI does not lose the image.
    expect(cloned.messages[0].attachments?.[0].dataURI).toBe('data:image/jpeg;base64,xxx');
  });

  it('cleanupConflictCopies deletes every isConflictCopy conversation and syncs', () => {
    store.getState().addConversation({ ...makeConv('copy-1'), isConflictCopy: true });
    store.getState().addConversation({ ...makeConv('copy-2'), isConflictCopy: true });
    const removed = cleanupConflictCopies(store);
    expect(removed).toBe(2);
    expect(
      store.getState().conversations.some((c) => c.isConflictCopy === true),
    ).toBe(false);
    expect(mockFlushPendingDeletions).toHaveBeenCalledTimes(1);
    const [syncedIds] = mockFlushPendingDeletions.mock.calls[0] as unknown as [string[]];
    expect(syncedIds.sort()).toEqual(['copy-1', 'copy-2']);
  });
});
