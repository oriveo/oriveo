import 'fake-indexeddb/auto';
import { openDB } from 'idb';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  getAllConversations,
  getConversationById,
  searchConversations,
  putConversation,
  deleteConversation,
  getAllProviders,
  putProvider,
  putProviderIfCurrent,
  deleteProvider,
  deleteProviderAndEnqueuePendingDeletion,
  putProviderAndCancelPendingDeletion,
  putProviderAndCancelPendingDeletionIfCurrent,
  getPendingProviderDeletions,
  clearPendingProviderDeletions,
  replaceAllInOneTx,
  putConversationPreservingHydratedMessages,
  stripInlineAttachmentPayloads,
  writeConversationWithQuotaFallback,
  getSessionValue,
  setSessionValue,
  resetDBConnection,
  getAllFolders,
  putFolder,
  deleteFolder,
} from '../idb';
import { getActiveUIDSync, setActiveUID } from '../partition';
import { resetImageDBConnection } from '../image-store';
import type { ChatMessage, Conversation, Provider } from '@oriveo/shared';

const partitionSyncGate = vi.hoisted(() => ({
  switchAtCall: -1,
  calls: 0,
  otherUID: 'user-B',
}));

vi.mock('../partition', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../partition')>();
  return {
    ...actual,
    getActiveUIDSync: () => {
      const callIndex = partitionSyncGate.calls;
      partitionSyncGate.calls += 1;
      if (partitionSyncGate.switchAtCall >= 0 && callIndex >= partitionSyncGate.switchAtCall) {
        return partitionSyncGate.otherUID;
      }
      return actual.getActiveUIDSync();
    },
  };
});

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'p1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••••test',
    ...overrides,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('idb.ts', () => {
  beforeEach(async () => {
    partitionSyncGate.switchAtCall = -1;
    partitionSyncGate.calls = 0;
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  // ── 2.1 Partition isolation ─────────────────────────────────────

  describe('partition isolation', () => {
    it('should not see guest data from user-A partition', async () => {
      // Write as guest
      await putConversation(makeConversation({ id: 'guest-conv' }));

      // Switch to user-A
      resetDBConnection();
      await setActiveUID('user-A');

      const convs = await getAllConversations();
      expect(convs.find((c) => c.id === 'guest-conv')).toBeUndefined();
    });

    it('should not see user-A data from guest partition', async () => {
      // Write as user-A
      resetDBConnection();
      await setActiveUID('user-A');
      await putProvider(makeProvider({ id: 'user-A-provider' }));

      // Switch back to guest
      resetDBConnection();
      await setActiveUID('guest');

      const providers = await getAllProviders();
      expect(providers.find((p) => p.id === 'user-A-provider')).toBeUndefined();
    });

    it('should isolate data between guest and user-A completely', async () => {
      // Guest writes
      await putConversation(makeConversation({ id: 'guest-conv', title: 'Guest Chat' }));

      // User-A writes
      resetDBConnection();
      await setActiveUID('user-A');
      await putConversation(makeConversation({ id: 'userA-conv', title: 'User A Chat' }));

      // Verify user-A only sees their own
      const userAConvs = await getAllConversations();
      expect(userAConvs).toHaveLength(1);
      expect(userAConvs[0].id).toBe('userA-conv');

      // Verify guest only sees their own
      resetDBConnection();
      await setActiveUID('guest');
      const guestConvs = await getAllConversations();
      expect(guestConvs).toHaveLength(1);
      expect(guestConvs[0].id).toBe('guest-conv');
    });
  });

  // ── 2.2 resetDBConnection ────────────────────────────

  describe('resetDBConnection', () => {
    it('should allow reading from new partition after reset + uid switch', async () => {
      await putConversation(makeConversation({ id: 'guest-c1' }));

      // Switch to user-A
      resetDBConnection();
      await setActiveUID('user-A');
      await putConversation(makeConversation({ id: 'userA-c1' }));

      const convs = await getAllConversations();
      expect(convs).toHaveLength(1);
      expect(convs[0].id).toBe('userA-c1');
    });

    it('should not throw on consecutive resets', () => {
      expect(() => {
        resetDBConnection();
        resetDBConnection();
        resetDBConnection();
      }).not.toThrow();
    });
  });

  // ── 2.3 CRUD operations ────────────────────────────────────

  describe('Conversation CRUD', () => {
    it('retries quota failures without inline attachment payloads', async () => {
      const conversation = makeConversation({
        id: 'quota-fallback',
        messages: [{
          id: 'm1', role: 'user', text: 'summarize', state: 'delivered',
          attachments: [{
            id: 'a1', kind: 'file', fileName: 'large.pdf', mimeType: 'application/pdf',
            base64Data: 'extracted text', downloadBase64Data: 'large binary',
            originalBase64Data: 'original binary', thumbnailBase64: 'thumbnail',
            storageRef: 'users/u/files/a1', originalSizeBytes: 10_000_000,
          }],
        }] as Conversation['messages'],
      });
      const writes: Conversation[] = [];
      const write = vi.fn(async (value: Conversation) => {
        writes.push(value);
        if (writes.length === 1) throw new DOMException('QuotaExceededError', 'QuotaExceededError');
      });

      await writeConversationWithQuotaFallback(conversation, write);

      expect(write).toHaveBeenCalledTimes(2);
      expect(writes[1].messages[0].attachments?.[0]).toEqual({
        id: 'a1', kind: 'file', fileName: 'large.pdf', mimeType: 'application/pdf',
        storageRef: 'users/u/files/a1', originalSizeBytes: 10_000_000,
      });
      expect(conversation.messages[0].attachments?.[0].base64Data).toBe('extracted text');
    });

    it('does not hide non-quota IndexedDB failures', async () => {
      const failure = new Error('transaction aborted');
      const write = vi.fn(async () => { throw failure; });

      await expect(writeConversationWithQuotaFallback(makeConversation(), write)).rejects.toBe(failure);
      expect(write).toHaveBeenCalledTimes(1);
    });

    it('returns the same conversation when no inline payload needs stripping', () => {
      const conversation = makeConversation();
      expect(stripInlineAttachmentPayloads(conversation)).toBe(conversation);
    });

    it('should put and get conversation', async () => {
      const conv = makeConversation({ id: 'c1', title: 'Test' });
      await putConversation(conv);

      const all = await getAllConversations();
      expect(all).toHaveLength(1);
      expect(all[0].id).toBe('c1');
      expect(all[0].title).toBe('Test');
    });

    it('round-trips QuoteContext v1 and drops only a dirty quote on read/write boundaries', async () => {
      const baseMessage: ChatMessage = {
        id: 'message-1', role: 'user', text: 'Continue', providerKind: 'openAI',
        providerName: 'OpenAI', modelName: 'GPT-4', estimatedCost: 0,
        state: 'delivered', createdAt: '2026-08-04T00:00:00.000Z',
      };
      const validQuote = {
        schemaVersion: 1 as const,
        sourceMessageId: 'source-1',
        sourceRole: 'assistant' as const,
        contentKind: 'prose' as const,
        leadingText: 'before', selectedText: 'selected', trailingText: 'after',
        contextTruncated: false,
      };
      await putConversation(makeConversation({
        id: 'valid-quote', messages: [{ ...baseMessage, quoteContext: validQuote }],
      }));
      expect((await getConversationById('valid-quote'))?.messages[0].quoteContext).toEqual(validQuote);

      await putConversation(makeConversation({
        id: 'dirty-quote',
        messages: [{ ...baseMessage, id: 'message-2', quoteContext: { ...validQuote, schemaVersion: 99 } as never }],
      }));
      const dirty = await getConversationById('dirty-quote');
      expect(dirty?.messages[0].text).toBe('Continue');
      expect(dirty?.messages[0].quoteContext).toBeUndefined();
    });

    it('should overwrite conversation with same ID', async () => {
      await putConversation(makeConversation({ id: 'c1', title: 'First' }));
      await putConversation(makeConversation({ id: 'c1', title: 'Second' }));

      const all = await getAllConversations();
      expect(all).toHaveLength(1);
      expect(all[0].title).toBe('Second');
    });

    it('should delete conversation', async () => {
      await putConversation(makeConversation({ id: 'c1' }));
      await deleteConversation('c1');

      const all = await getAllConversations();
      expect(all).toHaveLength(0);
    });

    it('should return conversations in updatedAt descending order', async () => {
      await putConversation(makeConversation({
        id: 'older',
        updatedAt: '2026-03-29T09:00:00.000Z',
      }));
      await putConversation(makeConversation({
        id: 'newer',
        updatedAt: '2026-03-29T11:00:00.000Z',
      }));

      const all = await getAllConversations();
      expect(all.map((conversation) => conversation.id)).toEqual(['newer', 'older']);
    });

    it('should get conversation by id', async () => {
      await putConversation(makeConversation({ id: 'c-lookup', title: 'Lookup' }));

      const conversation = await getConversationById('c-lookup');
      expect(conversation?.title).toBe('Lookup');
    });

    it('should preserve full messages when writing a hydrated summary', async () => {
      await putConversation(makeConversation({
        id: 'c-summary',
        folderID: undefined,
        messages: [
          { id: 'm1', role: 'user', text: 'hi', state: 'delivered' },
          { id: 'm2', role: 'assistant', text: 'hello', state: 'delivered' },
        ] as Conversation['messages'],
      }));

      await putConversationPreservingHydratedMessages(makeConversation({
        id: 'c-summary',
        folderID: 'folder-1',
        messages: [],
        remoteMessageCount: 2,
      }));

      const conversation = await getConversationById('c-summary');
      expect(conversation?.folderID).toBe('folder-1');
      expect(conversation?.messages.map((message) => message.id)).toEqual(['m1', 'm2']);
    });

    it('should preserve Managed message metadata embedded in conversations', async () => {
      await putConversation(makeConversation({
        id: 'managed-conv',
        providerID: 'catalog-provider',
        providerKind: 'openAI',
        messages: [
          {
            id: 'm-managed',
            role: 'assistant',
            text: 'partial',
            state: 'generating',
            providerKind: 'openAI',
            providerMode: 'managed',
            managedRequestId: 'mreq_123',
            lastSseSequence: 12,
          },
        ] as Conversation['messages'],
      }));

      const conversation = await getConversationById('managed-conv');

      expect(conversation?.messages[0]).toMatchObject({
        providerMode: 'managed',
        managedRequestId: 'mreq_123',
        lastSseSequence: 12,
      });
    });

    it('should preserve messages from a legacy lowercase uuid record', async () => {
      const lowercaseID = '4fa52360-2103-433a-8f4f-40e38faafc82';
      const uppercaseID = '4FA52360-2103-433A-8F4F-40E38FAAFC82';
      await putConversation(makeConversation({
        id: lowercaseID,
        messages: [
          { id: 'm1', role: 'user', text: 'hi', state: 'delivered' },
        ] as Conversation['messages'],
      }));

      await putConversationPreservingHydratedMessages(makeConversation({
        id: uppercaseID,
        title: 'Updated Title',
        messages: [],
        remoteMessageCount: 1,
      }));

      const conversation = await getConversationById(uppercaseID);
      expect(conversation?.id).toBe(uppercaseID);
      expect(conversation?.title).toBe('Updated Title');
      expect(conversation?.messages.map((message) => message.id)).toEqual(['m1']);
    });

    it('expected UID changes after the IDB read: returns false without writing user-B', async () => {
      const id = 'partition-read-race';
      resetDBConnection();
      await setActiveUID('user-A');
      await putConversation(makeConversation({
        id,
        title: 'A original',
        messages: [
          { id: 'm1', role: 'user', text: 'hi', state: 'delivered' },
        ] as Conversation['messages'],
      }));

      // call 0: after the DB is bound; call 1: after the existing conversation read returns.
      partitionSyncGate.calls = 0;
      partitionSyncGate.switchAtCall = 1;
      const persisted = await putConversationPreservingHydratedMessages(makeConversation({
        id,
        title: 'must not persist',
        messages: [],
        remoteMessageCount: 1,
      }), 'user-A');
      expect(persisted).toBe(false);

      partitionSyncGate.switchAtCall = -1;
      resetDBConnection();
      await setActiveUID('user-B');
      expect(await getConversationById(id)).toBeUndefined();

      resetDBConnection();
      await setActiveUID('user-A');
      expect((await getConversationById(id))?.title).toBe('A original');
    });

    it('expected UID changes after the IDB write: reports false and never writes user-B', async () => {
      const id = 'partition-write-race';
      resetDBConnection();
      await setActiveUID('user-A');
      await putConversation(makeConversation({
        id,
        title: 'A original',
        messages: [
          { id: 'm1', role: 'user', text: 'hi', state: 'delivered' },
        ] as Conversation['messages'],
      }));

      // call 0: after the DB is bound; call 1: after the direct read; call 2: after the
      // normalized-match stage; call 3: after the write. The call 2 recheck runs unconditionally
      // even when the direct read already hit.
      partitionSyncGate.calls = 0;
      partitionSyncGate.switchAtCall = 3;
      const persisted = await putConversationPreservingHydratedMessages(makeConversation({
        id,
        title: 'A updated before switch',
        messages: [],
        remoteMessageCount: 1,
      }), 'user-A');
      expect(persisted).toBe(false);

      partitionSyncGate.switchAtCall = -1;
      resetDBConnection();
      await setActiveUID('user-B');
      expect(await getConversationById(id)).toBeUndefined();

      resetDBConnection();
      await setActiveUID('user-A');
      expect((await getConversationById(id))?.title).toBe('A updated before switch');
    });

    it('should search conversations by title and message text', async () => {
      await putConversation(makeConversation({
        id: 'by-title',
        title: 'Travel Plan',
      }));
      await putConversation(makeConversation({
        id: 'by-message',
        messages: [{ id: 'm1', role: 'assistant', text: 'contains keyword', state: 'done' } as Conversation['messages'][number]],
      }));

      const titleResults = await searchConversations('travel');
      const messageResults = await searchConversations('keyword');

      expect(titleResults.map((conversation) => conversation.id)).toContain('by-title');
      expect(messageResults.map((conversation) => conversation.id)).toContain('by-message');
    });
  });

  describe('Provider CRUD', () => {
    it('should put and get provider', async () => {
      await putProvider(makeProvider({ id: 'p1' }));

      const all = await getAllProviders();
      expect(all).toHaveLength(1);
      expect(all[0].id).toBe('p1');
    });

    it('aborts a cancellable create whose commit point has expired on a real IDB, leaving no provider row', async () => {
      let guardReads = 0;
      const committed = await putProviderIfCurrent(
        makeProvider({ id: 'stale-provider' }),
        'guest',
        () => {
          guardReads += 1;
          return guardReads < 3;
        },
      );

      expect(committed).toBe(false);
      expect(await getAllProviders()).toEqual([]);
    });

    it('compensates by deleting the old partition provider when the UID changes in the narrow window around IDB complete', async () => {
      const creationUID = getActiveUIDSync();
      partitionSyncGate.calls = 0;
      // The fourth guard sits after tx.done, simulating a UID change between the final commit check and complete.
      partitionSyncGate.switchAtCall = 3;
      const committed = await putProviderIfCurrent(
        makeProvider({ id: 'uid-switched-provider' }),
        creationUID,
        () => getActiveUIDSync() === creationUID,
      );
      partitionSyncGate.switchAtCall = -1;
      partitionSyncGate.calls = 0;

      expect(committed).toBe(false);
      expect(await getAllProviders(creationUID)).toEqual([]);
    });

    it('should delete provider', async () => {
      await putProvider(makeProvider({ id: 'p1' }));
      await deleteProvider('p1');

      const all = await getAllProviders();
      expect(all).toHaveLength(0);
    });

    it('hard deletes the provider and persists a pending tombstone in the same transaction on user delete', async () => {
      await putProvider(makeProvider({ id: 'p-pending' }));

      await deleteProviderAndEnqueuePendingDeletion('p-pending', 'guest');

      expect(await getAllProviders()).toHaveLength(0);
      expect((await getPendingProviderDeletions('guest')).map((row) => row.providerId))
        .toEqual(['p-pending']);
    });

    it('does not enqueue an ordinary local delete, preserving backup replaceAll and migration semantics', async () => {
      await putProvider(makeProvider({ id: 'p-local-only' }));

      await deleteProvider('p-local-only');

      expect(await getPendingProviderDeletions()).toEqual([]);
    });

    it('isolates pending provider deletions per UID partition', async () => {
      await putProvider(makeProvider({ id: 'guest-provider' }));
      await deleteProviderAndEnqueuePendingDeletion('guest-provider', 'guest');

      resetDBConnection();
      await setActiveUID('user-A');
      expect(await getPendingProviderDeletions('user-A')).toEqual([]);

      resetDBConnection();
      await setActiveUID('guest');
      expect((await getPendingProviderDeletions('guest')).map((row) => row.providerId))
        .toEqual(['guest-provider']);
    });

    it('atomically writes back the provider and cancels the old pending tombstone on a deterministic ID re-add', async () => {
      await putProvider(makeProvider({ id: 'deterministic-provider' }));
      await deleteProviderAndEnqueuePendingDeletion('deterministic-provider', 'guest');

      const restored = makeProvider({ id: 'deterministic-provider', customName: 'Restored' });
      await putProviderAndCancelPendingDeletion(restored, 'guest');

      expect((await getAllProviders()).map((provider) => provider.customName)).toEqual(['Restored']);
      expect(await getPendingProviderDeletions('guest')).toEqual([]);
    });

    it('rolls back the provider and the pending cancellation in one transaction when a cancellable re-add expires', async () => {
      const provider = makeProvider({ id: 'stale-restored-provider' });
      await putProvider(provider);
      await deleteProviderAndEnqueuePendingDeletion(provider.id, 'guest');
      const before = await getPendingProviderDeletions('guest');
      let guardReads = 0;

      const committed = await putProviderAndCancelPendingDeletionIfCurrent(
        provider,
        'guest',
        () => {
          guardReads += 1;
          return guardReads < 3;
        },
      );

      expect(committed).toBe(false);
      expect(await getAllProviders()).toEqual([]);
      expect(await getPendingProviderDeletions('guest')).toEqual(before);
    });

    it('leaves no new row in the old partition when the UID changes in the narrow window around complete on a sync provider transaction', async () => {
      const creationUID = getActiveUIDSync();
      partitionSyncGate.calls = 0;
      partitionSyncGate.switchAtCall = 3;
      const committed = await putProviderAndCancelPendingDeletionIfCurrent(
        makeProvider({ id: 'uid-switched-synced-provider' }),
        creationUID,
        () => getActiveUIDSync() === creationUID,
      );
      partitionSyncGate.switchAtCall = -1;
      partitionSyncGate.calls = 0;

      expect(committed).toBe(false);
      expect(await getAllProviders(creationUID)).toEqual([]);
    });

    it('does not let a late D1 ack clear the D2 delete generation created after a re-add', async () => {
      const provider = makeProvider({ id: 'generation-provider' });
      await putProvider(provider);
      await deleteProviderAndEnqueuePendingDeletion(provider.id, 'guest');
      const [d1] = await getPendingProviderDeletions('guest');

      await putProviderAndCancelPendingDeletion(provider, 'guest');
      await deleteProviderAndEnqueuePendingDeletion(provider.id, 'guest');
      const [d2] = await getPendingProviderDeletions('guest');

      expect(d2.operationId).not.toBe(d1.operationId);
      await expect(clearPendingProviderDeletions([d1], 'guest')).resolves.toEqual([]);
      expect(await getPendingProviderDeletions('guest')).toEqual([d2]);

      await expect(clearPendingProviderDeletions([d2], 'guest'))
        .resolves.toEqual([provider.id]);
      expect(await getPendingProviderDeletions('guest')).toEqual([]);
    });

    it('commits the replaceAll provider restore and the cancellation of its old pending in the same IDB transaction', async () => {
      const restored = makeProvider({ id: 'restored-provider', customName: 'Backup' });
      await putProvider(restored);
      await deleteProviderAndEnqueuePendingDeletion(restored.id, 'guest');

      await replaceAllInOneTx({
        conversations: [],
        providers: [restored],
        folders: [],
        notes: [],
        noteFolders: [],
      });

      expect((await getAllProviders()).map((provider) => provider.id)).toEqual([restored.id]);
      expect(await getPendingProviderDeletions('guest')).toEqual([]);
    });

    it('refuses to write into the current new partition when replaceAll expectedUID does not match', async () => {
      resetDBConnection();
      await setActiveUID('user-B');
      const current = makeProvider({ id: 'user-b-provider' });
      await putProvider(current, 'user-B');

      await expect(replaceAllInOneTx({
        conversations: [],
        providers: [makeProvider({ id: 'user-a-backup-provider' })],
        folders: [],
        notes: [],
        noteFolders: [],
      }, 'user-A')).rejects.toThrow('Active storage partition changed from user-A to user-B');

      expect((await getAllProviders()).map((provider) => provider.id)).toEqual([current.id]);
    });

    it('fills in operationId when upgrading a v8 pending provider row', async () => {
      const legacy = await openDB('oriveo--guest', 8, {
        upgrade(database) {
          database.createObjectStore('pendingProviderDeletions', { keyPath: 'providerId' }).put({
            providerId: 'legacy-provider',
            enqueuedAt: 1,
          });
        },
      });
      legacy.close();

      const [migrated] = await getPendingProviderDeletions('guest');

      expect(migrated.providerId).toBe('legacy-provider');
      expect(migrated.operationId).toEqual(expect.any(String));
      expect(migrated.operationId.length).toBeGreaterThan(0);
    });

    it('should open existing v2 partition databases without downgrading', async () => {
      const existing = await openDB('oriveo--guest', 2, {
        upgrade(database) {
          const conversations = database.createObjectStore('conversations', { keyPath: 'id' });
          conversations.createIndex('by-updated', 'updatedAt');
          database.createObjectStore('providers', { keyPath: 'id' });
          database.createObjectStore('session');
          const folders = database.createObjectStore('folders', { keyPath: 'id' });
          folders.createIndex('by-sortOrder', 'sortOrder');
        },
      });
      existing.close();

      await putProvider(makeProvider({ id: 'p-v2' }));

      const providers = await getAllProviders();
      expect(providers.map((provider) => provider.id)).toContain('p-v2');
    });
  });

  describe('Session KV', () => {
    it('should set and get session value', async () => {
      await setSessionValue('testKey', { foo: 'bar' });
      const val = await getSessionValue('testKey');
      expect(val).toEqual({ foo: 'bar' });
    });

    it('should return undefined for nonexistent key', async () => {
      const val = await getSessionValue('nonexistent');
      expect(val).toBeUndefined();
    });

    it('expectedUID prevents a delayed session write from landing in the new account', async () => {
      await setActiveUID('user-A');
      resetDBConnection();
      await setSessionValue('testKey', 'user-a');

      await setActiveUID('user-B');
      resetDBConnection();
      await setSessionValue('testKey', 'user-b');

      await expect(setSessionValue('testKey', 'stale-user-a', 'user-A'))
        .rejects.toThrow('Active storage partition changed from user-A to user-B');
      await expect(getSessionValue('testKey')).resolves.toBe('user-b');
    });
  });

  // ── 20.1.5 Backward compatibility ────────────────────────────────────

  describe('TC-20.1.5 backward compatibility', () => {
    it('should initialize folders as empty array for fresh database', async () => {
      const folders = await getAllFolders();
      expect(folders).toEqual([]);
    });

    it('should support folder CRUD after fresh init', async () => {
      const folder = {
        id: 'f1',
        name: 'Work',
        sortOrder: 1000,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      };
      await putFolder(folder);

      const all = await getAllFolders();
      expect(all).toHaveLength(1);
      expect(all[0].id).toBe('f1');
      expect(all[0].name).toBe('Work');
    });

    it('should handle conversation without folderID', async () => {
      const conv = makeConversation({ id: 'legacy-conv' });
      // folderID is not set
      expect(conv.folderID).toBeUndefined();

      await putConversation(conv);
      const all = await getAllConversations();
      expect(all[0].folderID).toBeUndefined();
    });
  });
});
