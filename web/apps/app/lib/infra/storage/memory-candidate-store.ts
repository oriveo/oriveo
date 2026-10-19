import type { MemoryCandidateRecord, MemoryCandidateStatus } from '@oriveo/core/context/memory-intent';
import { getPartitionDB } from './idb';

/*
 * Local storage for memory candidates (idb v14): one row per candidate id, overwrite on write.
 * Held only in this machine's current partition database: not backed up; removed with the partition when the account is deleted, kept on a normal sign-out, and not carried over on guest sign-in.
 * Which rows to keep (pending / unexpired rejected) is decided by the candidate repository's sweep; this file only reads and writes.
 */

export interface MemoryCandidateRow {
  /** Equals candidate.id (the keyPath). */
  id: string;
  /** Equals candidate.status, so rows can be filtered without unpacking the whole candidate. */
  status: MemoryCandidateStatus;
  candidate: MemoryCandidateRecord;
}

/** Every candidate row in the partition. */
export async function getAllMemoryCandidateRows(expectedUID?: string): Promise<MemoryCandidateRow[]> {
  const db = await getPartitionDB(expectedUID);
  return db.getAll('memoryCandidates');
}

export async function getMemoryCandidateRow(id: string, expectedUID?: string): Promise<MemoryCandidateRow | undefined> {
  const db = await getPartitionDB(expectedUID);
  return db.get('memoryCandidates', id);
}

/** Write several rows in a single transaction (overwrite by id). */
export async function putMemoryCandidateRows(rows: readonly MemoryCandidateRow[], expectedUID?: string): Promise<void> {
  if (rows.length === 0) return;
  const db = await getPartitionDB(expectedUID);
  const tx = db.transaction('memoryCandidates', 'readwrite');
  await Promise.all([...rows.map((row) => tx.store.put(row)), tx.done]);
}

/** Delete several rows in a single transaction; ids that do not exist are ignored. */
export async function deleteMemoryCandidateRows(ids: readonly string[], expectedUID?: string): Promise<void> {
  if (ids.length === 0) return;
  const db = await getPartitionDB(expectedUID);
  const tx = db.transaction('memoryCandidates', 'readwrite');
  await Promise.all([...ids.map((id) => tx.store.delete(id)), tx.done]);
}
