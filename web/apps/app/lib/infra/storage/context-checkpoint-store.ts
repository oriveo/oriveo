import { getPartitionDB } from './idb';

/*
 * Local storage for context checkpoints (idb v12): primary key (conversationId, checkpointId), overwrite on write;
 * each conversation keeps only the newest CONTEXT_CHECKPOINT_KEEP_LIMIT entries (by createdAt, pruned in the same transaction).
 * idb.deleteConversation deletes them together when a conversation is deleted.
 */

export const CONTEXT_CHECKPOINT_KEEP_LIMIT = 8;

export type ContextCheckpointKind = 'summary' | 'fallback';

export interface ContextCheckpointRow {
  conversationId: string;
  checkpointId: string;
  kind: ContextCheckpointKind;
  coversFrom: string;
  coversTo: string;
  coversDigest: string;
  messagesCovered: number;
  userMessageIds: string[];
  /** The full checkpoint text. */
  text: string;
  summary: string | null;
  language: string | null;
  model: string;
  packerVersion: string;
  /** Millisecond timestamp. */
  createdAt: number;
  cost: number | null;
}

/** Write one checkpoint and trim the conversation to the newest CONTEXT_CHECKPOINT_KEEP_LIMIT entries (by createdAt). */
export async function putContextCheckpoint(row: ContextCheckpointRow, expectedUID?: string): Promise<void> {
  const db = await getPartitionDB(expectedUID);
  const tx = db.transaction('contextCheckpoints', 'readwrite');
  await tx.store.put(row);
  const entries = await tx.store.index('by-conversation').getAll(row.conversationId);
  const overflow = entries.length - CONTEXT_CHECKPOINT_KEEP_LIMIT;
  if (overflow > 0) {
    const oldest = sortByCreatedAt(entries).slice(0, overflow);
    await Promise.all(oldest.map((entry) => tx.store.delete([entry.conversationId, entry.checkpointId])));
  }
  await tx.done;
}

/** The checkpoints of a conversation, oldest to newest. */
export async function listContextCheckpoints(conversationId: string): Promise<ContextCheckpointRow[]> {
  const db = await getPartitionDB();
  const entries = await db.getAllFromIndex('contextCheckpoints', 'by-conversation', conversationId);
  return sortByCreatedAt(entries);
}

/** Every checkpoint in the table (for backup export). */
export async function getAllContextCheckpoints(): Promise<ContextCheckpointRow[]> {
  const db = await getPartitionDB();
  return db.getAll('contextCheckpoints');
}

/** Delete several checkpoints by primary key (single transaction). */
export async function deleteContextCheckpoints(conversationId: string, checkpointIds: readonly string[]): Promise<void> {
  if (checkpointIds.length === 0) return;
  const db = await getPartitionDB();
  const tx = db.transaction('contextCheckpoints', 'readwrite');
  await Promise.all([
    ...checkpointIds.map((checkpointId) => tx.store.delete([conversationId, checkpointId])),
    tx.done,
  ]);
}

/** Delete all checkpoints of a conversation (single transaction); returns the deleted checkpointIds. */
export async function deleteAllContextCheckpoints(conversationId: string): Promise<string[]> {
  const db = await getPartitionDB();
  const tx = db.transaction('contextCheckpoints', 'readwrite');
  const entries = await tx.store.index('by-conversation').getAll(conversationId);
  const ids = entries.map((entry) => entry.checkpointId);
  await Promise.all([...ids.map((checkpointId) => tx.store.delete([conversationId, checkpointId])), tx.done]);
  return ids;
}

function sortByCreatedAt(entries: ContextCheckpointRow[]): ContextCheckpointRow[] {
  return [...entries].sort((a, b) => a.createdAt - b.createdAt);
}
