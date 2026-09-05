import { openDB, deleteDB, type DBSchema, type IDBPDatabase } from 'idb';
import type { Conversation, Provider, Folder, Note, NoteFolder } from '@oriveo/shared';
import { sanitizeMessageQuoteContext } from '@oriveo/shared';
import { getActiveUID, getActiveUIDSync, getDBName } from './partition';
import { normalizeUUID } from '../../utils/id-utils';

/* ── DB Schema ───────────────────────────────────────── */

interface OriveoDBSchema extends DBSchema {
  conversations: {
    key: string;
    value: Conversation;
    indexes: { 'by-updated': string };
  };
  providers: {
    key: string;
    value: Provider;
  };
  session: {
    key: string;
    value: unknown;
  };
  folders: {
    key: string;
    value: Folder;
    indexes: { 'by-sortOrder': number };
  };
  notes: {
    key: string;
    value: Note;
    indexes: { 'by-updated': string };
  };
  noteFolders: {
    key: string;
    value: NoteFolder;
    indexes: { 'by-sortOrder': number };
  };
  pendingConversationDeletions: {
    key: string;
    value: { conversationId: string; enqueuedAt: number };
  };
  pendingProviderDeletions: {
    key: string;
    value: PendingProviderDeletion;
  };
}

export interface PendingProviderDeletion {
  providerId: string;
  operationId: string;
  enqueuedAt: number;
}

function makeProviderDeletionOperationID(): string {
  return globalThis.crypto?.randomUUID?.()
    ?? `${Date.now()}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
}

// Browser IndexedDB versions must only move forward.
// - v2: folder store.
// - v3: ChatMessage gains citations (capability spec v2 / web search references).
//   Messages are embedded in conversations.messages and the field is optional, so old rows
//   read back as undefined; no data migration, the version bump only records the schema step.
// - v4: cost accounting precision - ChatMessage gains cachedInputTokens / cacheCreation5mTokens
//   / cacheCreation1hTokens / costSource. All optional; old messages are backfilled with
//   costSource='unknown' to tell "never tracked" apart from "explicitly a local estimate".
//   The other three are simply undefined when missing.
// - v5: notes - adds the notes / noteFolders stores (top level, no subcollections).
//   Brand new stores with no history to backfill; upgrade creates them idempotently.
// - v6: ChatMessage gains providerMode / managedRequestId / lastSseSequence. Embedded in
//   conversations.messages and optional, so old rows read back as undefined.
// - v7: queue of conversation deletions still owed a remote tombstone. Local deletes are hard
//   deletes, so if no synchronisation backend is installed or the batch commit fails, the intent
//   is lost forever: reconcile only walks locally present conversations and can never see
//   "deleted here, still alive remotely".
// - v8: the same queue for provider deletions. The hard delete and the enqueue must share one
//   IDB transaction so a page closing mid-way cannot complete only one side; the queue is
//   cleared once the server acks.
// - v9: pending provider rows gain operationId, so an ack only clears its own delete
//   generation and a late ack for D1 cannot clear D2 after a re-add.
// - v10: ChatMessage gains a QuoteContext v1 snapshot. Optional, no backfill; the read/write
//   boundary drops a malformed quote without discarding the message.
export const DB_VERSION = 10;

// Active database name and connection promise (reset when the partition changes).
let currentDBName: string | null = null;
let dbPromise: Promise<IDBPDatabase<OriveoDBSchema>> | null = null;

async function openPartitionDB(dbName: string) {
  // Detect an empty DB (no stores) accidentally created by hasPartitionData: delete and
  // recreate it, otherwise opening at the same version never runs upgrade.
  try {
    const probe = await openDB(dbName);
    if (probe.objectStoreNames.length === 0) {
      probe.close();
      await deleteDB(dbName);
    } else {
      probe.close();
    }
  } catch { /* No such DB, which is normal */ }

  return openDB<OriveoDBSchema>(dbName, DB_VERSION, {
    upgrade(db, oldVersion, _newVersion, tx) {
      // v0 -> v4: create every store on first run.
      if (!db.objectStoreNames.contains('conversations')) {
        const convStore = db.createObjectStore('conversations', { keyPath: 'id' });
        convStore.createIndex('by-updated', 'updatedAt');
      }
      if (!db.objectStoreNames.contains('providers')) {
        db.createObjectStore('providers', { keyPath: 'id' });
      }
      if (!db.objectStoreNames.contains('session')) {
        db.createObjectStore('session');
      }
      if (!db.objectStoreNames.contains('folders')) {
        const folderStore = db.createObjectStore('folders', { keyPath: 'id' });
        folderStore.createIndex('by-sortOrder', 'sortOrder');
      }
      // v4 -> v5: notes. Brand new stores, nothing to backfill.
      if (!db.objectStoreNames.contains('notes')) {
        const noteStore = db.createObjectStore('notes', { keyPath: 'id' });
        noteStore.createIndex('by-updated', 'updatedAt');
      }
      if (!db.objectStoreNames.contains('noteFolders')) {
        const noteFolderStore = db.createObjectStore('noteFolders', { keyPath: 'id' });
        noteFolderStore.createIndex('by-sortOrder', 'sortOrder');
      }
      // v6 -> v7: conversation deletion queue. Brand new store, nothing to backfill.
      if (!db.objectStoreNames.contains('pendingConversationDeletions')) {
        db.createObjectStore('pendingConversationDeletions', { keyPath: 'conversationId' });
      }
      // v7 -> v8: provider deletion queue. Brand new store, nothing to backfill.
      if (!db.objectStoreNames.contains('pendingProviderDeletions')) {
        db.createObjectStore('pendingProviderDeletions', { keyPath: 'providerId' });
      }
      if (oldVersion >= 8 && oldVersion < 9) {
        void (async () => {
          for await (const cursor of tx.objectStore('pendingProviderDeletions').iterate()) {
            const row = cursor.value as PendingProviderDeletion;
            if (!row.operationId) {
              await cursor.update({ ...row, operationId: makeProviderDeletionOperationID() });
            }
          }
        })();
      }
      // v2 -> v3: ChatMessage gains citations. The field is optional, so old messages read
      // back as undefined and no rewrite pass is needed.
      if (oldVersion < 3) {
        // Nothing to backfill; the branch is kept for future schema steps.
      }
      // v3 -> v4: cost accounting precision - backfill costSource='unknown' so an old message
      // whose cost source was never tracked stays distinguishable from a new one that is
      // explicitly localEstimate or upstream. The other three fields are undefined when
      // missing, so only this one enum needs a pass over old messages.
      if (oldVersion < 4) {
        // The idb package exposes cursors as async iterables, so awaiting the cursor chain
        // inside an upgrade hook is safe: the transaction stays active while it advances.
        void (async () => {
          for await (const cursor of tx.objectStore('conversations').iterate()) {
            const conv = cursor.value;
            if (!conv?.messages || !Array.isArray(conv.messages)) continue;
            let mutated = false;
            for (const msg of conv.messages) {
              // Old messages carry no costSource; backfill 'unknown' to keep them distinguishable.
              if (msg && typeof msg === 'object' && (msg as { costSource?: string }).costSource === undefined) {
                (msg as { costSource?: string }).costSource = 'unknown';
                mutated = true;
              }
            }
            if (mutated) await cursor.update(conv);
          }
        })().catch(() => {
          // A failed backfill must not block the schema upgrade; new messages carry costSource anyway.
        });
      }
    },
  });
}

async function getDB(expectedUID?: string) {
  const uid = await getActiveUID();
  if (expectedUID !== undefined && uid !== expectedUID) {
    throw new Error(`Active storage partition changed from ${expectedUID} to ${uid}`);
  }
  const dbName = getDBName(uid);

  if (dbPromise && currentDBName === dbName) {
    return dbPromise;
  }

  // Partition switch: close the old connection and open the new one
  if (dbPromise && currentDBName !== dbName) {
    try {
      const oldDb = await dbPromise;
      oldDb.close();
    } catch { /* Ignore a failed close */ }
  }

  currentDBName = dbName;
  dbPromise = openPartitionDB(dbName);
  return dbPromise;
}

/** Force the DB connection to reset when the partition changes (sign in / sign out). */
export function resetDBConnection() {
  if (dbPromise) {
    dbPromise.then((db) => db.close()).catch(() => {});
  }
  dbPromise = null;
  currentDBName = null;
}

/* ── Conversations ───────────────────────────────────── */

function sanitizeConversationQuoteContexts(conversation: Conversation): Conversation {
  let changed = false;
  const messages = conversation.messages.map((message) => {
    const sanitized = sanitizeMessageQuoteContext(message);
    if (sanitized !== message) changed = true;
    return sanitized;
  });
  return changed ? { ...conversation, messages } : conversation;
}

function isQuotaExceededError(error: unknown): boolean {
  let current: unknown = error;
  for (let depth = 0; depth < 4 && current; depth += 1) {
    if (typeof current === 'object') {
      const candidate = current as { name?: unknown; message?: unknown; cause?: unknown };
      if (candidate.name === 'QuotaExceededError'
        || (typeof candidate.message === 'string' && candidate.message.includes('QuotaExceededError'))) {
        return true;
      }
      current = candidate.cause;
      continue;
    }
    if (typeof current === 'string' && current.includes('QuotaExceededError')) return true;
    break;
  }
  return false;
}

/**
 * Emergency persistence form used only after IndexedDB rejects the full conversation for quota.
 * The live store keeps the payloads, so pending cloud uploads can still complete and backfill a
 * storageRef. The retry preserves the conversation and messages instead of losing the whole row.
 */
export function stripInlineAttachmentPayloads(conversation: Conversation): Conversation {
  let changed = false;
  const messages = conversation.messages.map((message) => {
    if (!message.attachments?.length) return message;
    let attachmentsChanged = false;
    const attachments = message.attachments.map((attachment) => {
      if (!attachment.base64Data
        && !attachment.downloadBase64Data
        && !attachment.originalBase64Data
        && !attachment.thumbnailBase64) return attachment;
      attachmentsChanged = true;
      const {
        base64Data: _base64Data,
        downloadBase64Data: _downloadBase64Data,
        originalBase64Data: _originalBase64Data,
        thumbnailBase64: _thumbnailBase64,
        ...metadata
      } = attachment;
      return metadata;
    });
    if (!attachmentsChanged) return message;
    changed = true;
    return { ...message, attachments };
  });
  return changed ? { ...conversation, messages } : conversation;
}

export async function writeConversationWithQuotaFallback(
  conversation: Conversation,
  write: (value: Conversation) => Promise<unknown>,
): Promise<void> {
  try {
    await write(conversation);
  } catch (error) {
    if (!isQuotaExceededError(error)) throw error;
    const lightweight = stripInlineAttachmentPayloads(conversation);
    if (lightweight === conversation) throw error;
    await write(lightweight);
  }
}

export async function getAllConversations(expectedUID?: string): Promise<Conversation[]> {
  const db = await getDB(expectedUID);
  const conversations = await db.getAllFromIndex('conversations', 'by-updated');
  return conversations.map(sanitizeConversationQuoteContexts).sort(
    (left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt),
  );
}

export async function getConversationById(
  id: string,
  expectedUID?: string,
): Promise<Conversation | undefined> {
  const db = await getDB(expectedUID);
  const direct = await db.get('conversations', id);
  if (expectedUID !== undefined && getActiveUIDSync() !== expectedUID) return undefined;
  if (direct) return sanitizeConversationQuoteContexts(direct);
  const normalized = normalizeUUID(id);
  if (normalized !== id) {
    const normalizedMatch = await db.get('conversations', normalized);
    if (expectedUID !== undefined && getActiveUIDSync() !== expectedUID) return undefined;
    if (normalizedMatch) return sanitizeConversationQuoteContexts(normalizedMatch);
  }
  const conversations = await db.getAll('conversations');
  if (expectedUID !== undefined && getActiveUIDSync() !== expectedUID) return undefined;
  const match = conversations.find((conversation) => normalizeUUID(conversation.id) === normalized);
  return match ? sanitizeConversationQuoteContexts(match) : undefined;
}

export async function searchConversations(query: string): Promise<Conversation[]> {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return [];

  const conversations = await getAllConversations();
  return conversations.filter((conversation) =>
    conversation.title.toLowerCase().includes(normalized) ||
    conversation.previewText.toLowerCase().includes(normalized) ||
    conversation.messages.some((message) => message.text.toLowerCase().includes(normalized)),
  );
}

export async function putConversation(conversation: Conversation): Promise<void> {
  const db = await getDB();
  await db.put('conversations', sanitizeConversationQuoteContexts(conversation));
}

export async function putConversationPreservingHydratedMessages(
  conversation: Conversation,
  expectedUID?: string,
): Promise<boolean> {
  const shouldPreserveHydratedMessages =
    conversation.messages.length === 0 &&
    (conversation.remoteMessageCount ?? 0) > 0;

  const partitionIsCurrent = () =>
    expectedUID === undefined || getActiveUIDSync() === expectedUID;
  const db = await getDB(expectedUID);
  if (!partitionIsCurrent()) return false;

  if (!shouldPreserveHydratedMessages) {
    await writeConversationWithQuotaFallback(
      sanitizeConversationQuoteContexts(conversation),
      (value) => db.put('conversations', value),
    );
    return partitionIsCurrent();
  }

  const direct = await db.get('conversations', conversation.id);
  if (!partitionIsCurrent()) return false;
  const normalized = normalizeUUID(conversation.id);
  const normalizedMatch = !direct && normalized !== conversation.id
    ? await db.get('conversations', normalized)
    : undefined;
  if (!partitionIsCurrent()) return false;
  let existing = direct ?? normalizedMatch;
  if (!existing) {
    const conversations = await db.getAll('conversations');
    if (!partitionIsCurrent()) return false;
    existing = conversations.find((item) => normalizeUUID(item.id) === normalized);
  }
  if (!existing || existing.messages.length === 0) {
    await writeConversationWithQuotaFallback(
      sanitizeConversationQuoteContexts(conversation),
      (value) => db.put('conversations', value),
    );
    return partitionIsCurrent();
  }

  await writeConversationWithQuotaFallback(
    sanitizeConversationQuoteContexts({
      ...conversation,
      messages: existing.messages,
      remoteMessageCount: Math.max(
        conversation.remoteMessageCount ?? 0,
        existing.remoteMessageCount ?? 0,
        existing.messages.length,
      ),
    }),
    (value) => db.put('conversations', value),
  );
  return partitionIsCurrent();
}

/**
 * Batch upsert conversations in a single transaction (5000 rows in a few hundred ms versus
 * ~15-25s with one transaction per row). Used to persist merge results.
 */
export async function putConversationsBatch(
  conversations: Conversation[],
  expectedUID?: string,
): Promise<void> {
  if (conversations.length === 0) return;
  const db = await getDB(expectedUID);
  const tx = db.transaction('conversations', 'readwrite');
  await Promise.all([
    ...conversations.map((c) => tx.store.put(sanitizeConversationQuoteContexts(c))),
    tx.done,
  ]);
}

export async function deleteConversation(id: string): Promise<void> {
  const db = await getDB();
  await db.delete('conversations', id);
}

/* ── Pending deletion queue ───────────────────────
 * Conversations are hard deleted locally, so the intent has to be recorded separately until the
 * server acks it; otherwise an adapter that is not ready yet, or a failed commit, loses the
 * delete with no way to compensate. The DB is already partitioned by uid, so no uid field.
 */

/** Re-enqueueing is idempotent: deleting the same id again only refreshes enqueuedAt. */
export async function enqueuePendingConversationDeletions(ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const db = await getDB();
  const tx = db.transaction('pendingConversationDeletions', 'readwrite');
  const enqueuedAt = Date.now();
  await Promise.all([
    ...ids.map((conversationId) => tx.store.put({ conversationId, enqueuedAt })),
    tx.done,
  ]);
}

/** Conversation ids still owed a remote tombstone, in enqueue order. */
export async function getPendingConversationDeletions(): Promise<string[]> {
  const db = await getDB();
  const rows = await db.getAll('pendingConversationDeletions');
  return rows.sort((a, b) => a.enqueuedAt - b.enqueuedAt).map((r) => r.conversationId);
}

/** Clear entries the server has acked; unacked ones stay for the next flush (tombstones are idempotent). */
export async function clearPendingConversationDeletions(ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const db = await getDB();
  const tx = db.transaction('pendingConversationDeletions', 'readwrite');
  await Promise.all([...ids.map((id) => tx.store.delete(id)), tx.done]);
}

/* ── Providers ───────────────────────────────────────── */

export async function getAllProviders(expectedUID?: string): Promise<Provider[]> {
  const db = await getDB(expectedUID);
  return db.getAll('providers');
}

export async function putProvider(provider: Provider, expectedUID?: string): Promise<void> {
  const db = await getDB(expectedUID);
  await db.put('providers', provider);
}

/**
 * Cancellable provider write for the create flow. The guard is re-checked just before the real
 * IDB transaction commits; if the connection attempt is stale the whole transaction aborts so no
 * ghost provider is left behind.
 */
export async function putProviderIfCurrent(
  provider: Provider,
  expectedUID: string | undefined,
  shouldCommit: () => boolean,
): Promise<boolean> {
  if (!shouldCommit()) return false;
  let db: IDBPDatabase<OriveoDBSchema>;
  try {
    db = await getDB(expectedUID);
  } catch (error) {
    if (expectedUID !== undefined && error instanceof Error
      && error.message.startsWith('Active storage partition changed from ')) return false;
    throw error;
  }
  if (!shouldCommit()) return false;
  const tx = db.transaction('providers', 'readwrite');
  await tx.store.put(provider);
  if (!shouldCommit()) {
    tx.abort();
    try {
      await tx.done;
    } catch {
      // AbortError is the expected outcome of a stale guard.
    }
    return false;
  }
  await tx.done;
  // The UID can change between the last guard and transaction completion, so compensate by
  // deleting from the partition the row was created in - the switch may already have closed
  // the old global connection.
  if (!shouldCommit()) {
    if (expectedUID !== undefined) await deleteProviderFromPartition(provider.id, expectedUID);
    else await db.delete('providers', provider.id);
    return false;
  }
  return true;
}

export async function deleteProvider(id: string, expectedUID?: string): Promise<void> {
  const db = await getDB(expectedUID);
  await db.delete('providers', id);
}

/** Rollback path for guarded creates: delete the row from a specific partition, ignoring the active UID. */
export async function deleteProviderFromPartition(id: string, uid: string): Promise<void> {
  const db = await openPartitionDB(getDBName(uid));
  try {
    await db.delete('providers', id);
  } finally {
    db.close();
  }
}

/**
 * User-initiated provider deletion: the local hard delete and the remote tombstone intent are
 * committed atomically.
 *
 * Local maintenance paths such as a replaceAll restore, partition cleanup or a provider id
 * migration must keep calling `deleteProvider` instead; otherwise replacing a local snapshot
 * would be read as the user deleting the provider in the cloud.
 */
export async function deleteProviderAndEnqueuePendingDeletion(
  id: string,
  expectedUID?: string,
): Promise<void> {
  const db = await getDB(expectedUID);
  const tx = db.transaction(['providers', 'pendingProviderDeletions'], 'readwrite');
  await Promise.all([
    tx.objectStore('providers').delete(id),
    tx.objectStore('pendingProviderDeletions').put({
      providerId: id,
      operationId: makeProviderDeletionOperationID(),
      enqueuedAt: Date.now(),
    }),
    tx.done,
  ]);
}

/**
 * Re-adding a provider that has a deterministic id: the active provider write and the
 * cancellation of the pending deletion commit atomically. The remote active write must be
 * issued after this transaction completes so the restore overwrites the old tombstone in
 * this client's write order.
 */
export async function putProviderAndCancelPendingDeletion(
  provider: Provider,
  expectedUID?: string,
): Promise<void> {
  const db = await getDB(expectedUID);
  const tx = db.transaction(['providers', 'pendingProviderDeletions'], 'readwrite');
  await Promise.all([
    tx.objectStore('providers').put(provider),
    tx.objectStore('pendingProviderDeletions').delete(provider.id),
    tx.done,
  ]);
}

/**
 * Cancellable variant of `putProviderAndCancelPendingDeletion`. The provider write and the
 * pending cancellation stay in one transaction; when the guard goes stale both abort together
 * so no partially committed state is observable.
 */
export async function putProviderAndCancelPendingDeletionIfCurrent(
  provider: Provider,
  expectedUID: string | undefined,
  shouldCommit: () => boolean,
): Promise<boolean> {
  if (!shouldCommit()) return false;
  let db: IDBPDatabase<OriveoDBSchema>;
  try {
    db = await getDB(expectedUID);
  } catch (error) {
    if (expectedUID !== undefined && error instanceof Error
      && error.message.startsWith('Active storage partition changed from ')) return false;
    throw error;
  }
  if (!shouldCommit()) return false;
  const tx = db.transaction(['providers', 'pendingProviderDeletions'], 'readwrite');
  await Promise.all([
    tx.objectStore('providers').put(provider),
    tx.objectStore('pendingProviderDeletions').delete(provider.id),
  ]);
  if (!shouldCommit()) {
    tx.abort();
    try {
      await tx.done;
    } catch {
      // AbortError is the expected outcome of a stale guard.
    }
    return false;
  }
  await tx.done;
  if (!shouldCommit()) {
    // The guarded path only ever writes new ids, so if the UID switches in the narrow window
    // before completion, deleting the newly written row restores the old partition's
    // observable state without touching a pre-existing provider.
    if (expectedUID !== undefined) await deleteProviderFromPartition(provider.id, expectedUID);
    else await db.delete('providers', provider.id);
    return false;
  }
  return true;
}

/** Provider deletion generations still owed a remote tombstone, in enqueue order. */
export async function getPendingProviderDeletions(
  expectedUID?: string,
): Promise<PendingProviderDeletion[]> {
  const db = await getDB(expectedUID);
  const rows = await db.getAll('pendingProviderDeletions');
  return rows.sort((a, b) => a.enqueuedAt - b.enqueuedAt);
}

/** Clear only the acks whose operationId still matches; returns the provider ids actually cleared. */
export async function clearPendingProviderDeletions(
  acked: Pick<PendingProviderDeletion, 'providerId' | 'operationId'>[],
  expectedUID?: string,
): Promise<string[]> {
  if (acked.length === 0) return [];
  const db = await getDB(expectedUID);
  const tx = db.transaction('pendingProviderDeletions', 'readwrite');
  const cleared: string[] = [];
  for (const expected of acked) {
    const current = await tx.store.get(expected.providerId);
    if (current?.operationId !== expected.operationId) continue;
    await tx.store.delete(expected.providerId);
    cleared.push(expected.providerId);
  }
  await tx.done;
  return cleared;
}

/* ── Folders ─────────────────────────────────────────── */

export async function getAllFolders(expectedUID?: string): Promise<Folder[]> {
  const db = await getDB(expectedUID);
  return db.getAll('folders');
}

export async function putFolder(folder: Folder): Promise<void> {
  const db = await getDB();
  await db.put('folders', folder);
}

export async function deleteFolder(id: string): Promise<void> {
  const db = await getDB();
  await db.delete('folders', id);
}

export async function clearAllFolders(): Promise<void> {
  const db = await getDB();
  await db.clear('folders');
}

/* ── Notes ───────────────────────────────────────────── */

/**
 * Every note in the partition, including soft-deleted ones (deletedAt != null).
 * Hydration splits them into notes / trashedNotes by deletedAt, so nothing is filtered here.
 * Sorted by updatedAt descending, like getAllConversations.
 */
export async function getAllNotes(expectedUID?: string): Promise<Note[]> {
  const db = await getDB(expectedUID);
  const notes = await db.getAllFromIndex('notes', 'by-updated');
  return notes.sort(
    (left, right) => Date.parse(right.updatedAt) - Date.parse(left.updatedAt),
  );
}

export async function getNoteById(id: string): Promise<Note | undefined> {
  const db = await getDB();
  const direct = await db.get('notes', id);
  if (direct) return direct;
  const normalized = normalizeUUID(id);
  if (normalized !== id) {
    const normalizedMatch = await db.get('notes', normalized);
    if (normalizedMatch) return normalizedMatch;
  }
  const notes = await db.getAll('notes');
  return notes.find((note) => normalizeUUID(note.id) === normalized);
}

export async function putNote(note: Note): Promise<void> {
  const db = await getDB();
  await db.put('notes', note);
}

/** Batch upsert notes in one transaction. Used by merge persist and the initial pull. */
export async function putNotesBatch(notes: Note[], expectedUID?: string): Promise<void> {
  if (notes.length === 0) return;
  const db = await getDB(expectedUID);
  const tx = db.transaction('notes', 'readwrite');
  await Promise.all([
    ...notes.map((n) => tx.store.put(n)),
    tx.done,
  ]);
}

/** Hard delete a single note from IDB (used when emptying the trash; removeNote soft deletes instead). */
export async function deleteNote(id: string): Promise<void> {
  const db = await getDB();
  await db.delete('notes', id);
}

export async function clearAllNotes(): Promise<void> {
  const db = await getDB();
  await db.clear('notes');
}

/* ── Note Folders ────────────────────────────────────── */

export async function getAllNoteFolders(expectedUID?: string): Promise<NoteFolder[]> {
  const db = await getDB(expectedUID);
  return db.getAll('noteFolders');
}

export async function putNoteFolder(folder: NoteFolder): Promise<void> {
  const db = await getDB();
  await db.put('noteFolders', folder);
}

/** Batch upsert noteFolders in one transaction. Used by merge persist and the initial pull. */
export async function putNoteFoldersBatch(folders: NoteFolder[], expectedUID?: string): Promise<void> {
  if (folders.length === 0) return;
  const db = await getDB(expectedUID);
  const tx = db.transaction('noteFolders', 'readwrite');
  await Promise.all([
    ...folders.map((f) => tx.store.put(f)),
    tx.done,
  ]);
}

export async function deleteNoteFolder(id: string): Promise<void> {
  const db = await getDB();
  await db.delete('noteFolders', id);
}

export async function clearAllNoteFolders(): Promise<void> {
  const db = await getDB();
  await db.clear('noteFolders');
}

/* ── Bulk clear (replace-mode import) ──────────────────────── */

export async function clearAllConversations(): Promise<void> {
  const db = await getDB();
  await db.clear('conversations');
}

export async function clearAllProviders(): Promise<void> {
  const db = await getDB();
  await db.clear('providers');
}

/* ── Backup import: one atomic transaction on the main DB ──────────────────
 * Conversations, providers, folders, notes and note folders are written in a single
 * transaction, so a failing put rolls the whole batch back instead of leaving a half-written
 * database behind a clear. The image store is a separate DB and cannot join this transaction,
 * so images are compensated separately (see backup-import.ts).
 */
const BACKUP_MAIN_STORES = [
  'conversations',
  'providers',
  'folders',
  'notes',
  'noteFolders',
] as const;

export interface MainDBPutSnapshot {
  conversations?: Conversation[];
  providers?: Provider[];
  folders?: Folder[];
  notes?: Note[];
  noteFolders?: NoteFolder[];
}

/** Put all five kinds of data into the main DB in one transaction (merge import, no clear); rolls back on failure. */
export async function mergeAllInOneTx(snapshot: MainDBPutSnapshot): Promise<void> {
  const db = await getDB();
  const tx = db.transaction(BACKUP_MAIN_STORES, 'readwrite');
  // ops is declared outside the try because the catch block needs it to swallow AbortError.
  const ops: Promise<unknown>[] = [];
  try {
    for (const conversation of snapshot.conversations ?? []) ops.push(tx.objectStore('conversations').put(conversation));
    for (const provider of snapshot.providers ?? []) ops.push(tx.objectStore('providers').put(provider));
    for (const folder of snapshot.folders ?? []) ops.push(tx.objectStore('folders').put(folder));
    for (const note of snapshot.notes ?? []) ops.push(tx.objectStore('notes').put(note));
    for (const noteFolder of snapshot.noteFolders ?? []) ops.push(tx.objectStore('noteFolders').put(noteFolder));
    ops.push(tx.done);
    await Promise.all(ops);
  } catch (err) {
    // put() throws synchronously on an invalid value instead of aborting, so only an explicit
    // abort rolls back the writes already issued. abort() rejects every queued op with
    // AbortError, so attach no-op catches first to avoid unhandled rejections. tx.done never
    // enters ops on the synchronous-throw path, so it needs its own handler.
    ops.forEach((p) => p.catch(() => {}));
    tx.done.catch(() => {});
    try { tx.abort(); } catch { /* The transaction may already have aborted itself on an async error */ }
    throw err;
  }
}

/** Clear the five stores and put a full snapshot in one transaction (replace import); rolls back on failure. */
export async function replaceAllInOneTx(
  snapshot: Required<MainDBPutSnapshot>,
  expectedUID?: string,
): Promise<void> {
  const db = await getDB(expectedUID);
  const tx = db.transaction([...BACKUP_MAIN_STORES, 'pendingProviderDeletions'], 'readwrite');
  // ops is declared outside the try because the catch block needs it to swallow AbortError.
  const ops: Promise<unknown>[] = [];
  try {
    for (const store of BACKUP_MAIN_STORES) ops.push(tx.objectStore(store).clear());
    for (const conversation of snapshot.conversations) ops.push(tx.objectStore('conversations').put(conversation));
    for (const provider of snapshot.providers) ops.push(tx.objectStore('providers').put(provider));
    for (const provider of snapshot.providers) {
      ops.push(tx.objectStore('pendingProviderDeletions').delete(provider.id));
    }
    for (const folder of snapshot.folders) ops.push(tx.objectStore('folders').put(folder));
    for (const note of snapshot.notes) ops.push(tx.objectStore('notes').put(note));
    for (const noteFolder of snapshot.noteFolders) ops.push(tx.objectStore('noteFolders').put(noteFolder));
    ops.push(tx.done);
    await Promise.all(ops);
  } catch (err) {
    // abort() rejects every queued op with AbortError, so attach no-op catches first to avoid
    // unhandled rejections. tx.done never enters ops on the synchronous-throw path, so it
    // needs its own handler.
    ops.forEach((p) => p.catch(() => {}));
    tx.done.catch(() => {});
    try { tx.abort(); } catch { /* The transaction may already have aborted itself on an async error */ }
    throw err;
  }
}

/* ── Session (generic KV) ────────────────────────────── */

export async function getSessionValue<T>(key: string, expectedUID?: string): Promise<T | undefined> {
  const db = await getDB(expectedUID);
  return db.get('session', key) as Promise<T | undefined>;
}

export async function setSessionValue(
  key: string,
  value: unknown,
  expectedUID?: string,
): Promise<void> {
  const db = await getDB(expectedUID);
  await db.put('session', value, key);
}

export async function deleteSessionValue(key: string, expectedUID?: string): Promise<void> {
  const db = await getDB(expectedUID);
  await db.delete('session', key);
}
