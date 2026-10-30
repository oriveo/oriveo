import { openDB } from './idb-open';
import type { MemoryItem } from '@oriveo/core/context/memory-items';
import { getPartitionDB } from './idb';
import { getDBName } from './partition';

/*
 * Local storage for memory items (idb v13): one row per item id, overwrite on write.
 * syncState marks rows written locally and not yet confirmed remotely. Rows are isolated per partition and never hard-deleted here: deleting = a tombstone row.
 */

export type MemoryItemSyncState = 'synced' | 'pending';

export interface MemoryItemRow {
  /** Equals item.id (the keyPath). */
  id: string;
  item: MemoryItem;
  syncState: MemoryItemSyncState;
}

/** Every row in the partition, tombstones included. */
export async function getAllMemoryItemRows(expectedUID?: string): Promise<MemoryItemRow[]> {
  const db = await getPartitionDB(expectedUID);
  return db.getAll('memoryItems');
}

export async function getMemoryItemRow(id: string, expectedUID?: string): Promise<MemoryItemRow | undefined> {
  const db = await getPartitionDB(expectedUID);
  return db.get('memoryItems', id);
}

/** Write several rows in a single transaction (overwrite by id). */
export async function putMemoryItemRows(rows: readonly MemoryItemRow[], expectedUID?: string): Promise<void> {
  if (rows.length === 0) return;
  const db = await getPartitionDB(expectedUID);
  const tx = db.transaction('memoryItems', 'readwrite');
  await Promise.all([...rows.map((row) => tx.store.put(row)), tx.done]);
}

/**
 * Accept a memory candidate: writing the item row and deleting the candidate row share one transaction; if either fails everything rolls back (no item left behind, the candidate stays).
 */
export async function putMemoryItemRowsConsumingCandidates(
  rows: readonly MemoryItemRow[],
  candidateIds: readonly string[],
  expectedUID?: string,
): Promise<void> {
  const db = await getPartitionDB(expectedUID);
  const tx = db.transaction(['memoryItems', 'memoryCandidates'], 'readwrite');
  const requests: Promise<unknown>[] = [];
  try {
    const itemStore = tx.objectStore('memoryItems');
    const candidateStore = tx.objectStore('memoryCandidates');
    for (const row of rows) requests.push(itemStore.put(row));
    for (const id of candidateIds) requests.push(candidateStore.delete(id));
  } catch (error) {
    // If a synchronous throw happens, requests already issued are voided together with the transaction: absorb their rejections first, then roll back.
    void Promise.allSettled([...requests, tx.done]);
    try {
      tx.abort();
    } catch {
      // The transaction has already ended (auto-rolled back).
    }
    throw error;
  }
  await Promise.all([...requests, tx.done]);
}

/**
 * Guest -> account data move: copy the guest partition's non-tombstone items into the current (account) partition under their original ids, with syncState pending.
 * Rows whose id already exists in the account partition are not overwritten. Returns the number of rows copied in.
 */
export async function copyGuestMemoryItemRows(expectedUID?: string): Promise<number> {
  const guestName = getDBName('guest');
  const databases = await indexedDB.databases();
  if (!databases.some((database) => database.name === guestName)) return 0;
  const guestDB = await openDB(guestName);
  let guestRows: MemoryItemRow[];
  try {
    if (!guestDB.objectStoreNames.contains('memoryItems')) return 0;
    guestRows = await guestDB.getAll('memoryItems') as MemoryItemRow[];
  } finally {
    guestDB.close();
  }
  const existing = new Set((await getAllMemoryItemRows(expectedUID)).map((row) => row.id));
  const rows = guestRows
    .filter((row) => row.item.status !== 'deleted' && !existing.has(row.id))
    .map((row): MemoryItemRow => ({ id: row.id, item: row.item, syncState: 'pending' }));
  await putMemoryItemRows(rows, expectedUID);
  return rows.length;
}
