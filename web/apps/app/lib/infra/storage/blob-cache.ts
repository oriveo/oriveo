/**
 * Large object cache (IndexedDB, not partitioned).
 *
 * **Placement rule**: any structured cache larger than a few tens of KB belongs here and must not go
 * into localStorage. In Chrome localStorage is a hard 5MB quota per origin, counted in UTF-16 code
 * units, and it is **shared across the whole site**. A single `/api/metadata` payload measured
 * 3.3MB in production and took 66% of the quota, which then tripped `QuotaExceededError` for
 * other keys on the same origin.
 * The IDB quota is a fraction of the disk (gigabytes) and stores structured clones instead of
 * strings, which also saves a JSON.stringify/parse round trip on the main thread.
 *
 * Global and not partitioned by UID: only **public data** such as the model catalog goes here, never
 * anything private to a user. Private data goes through the per-UID partitioned databases in `idb.ts`.
 */

import { openMetaDB } from './partition';

const STORE = 'blobs';

/** Cache entry envelope: the value plus its write time, with the TTL judged by the caller. */
export interface BlobCacheEntry<T> {
  value: T;
  timestamp: number;
}

/**
 * Read one large object cache entry.
 *
 * When IDB is unavailable (private mode, site data disabled, a version conflict) this returns null
 * rather than throwing, and the caller treats it as a cache miss and refetches over the network.
 */
export async function readBlob<T>(key: string): Promise<BlobCacheEntry<T> | null> {
  let db;
  try {
    db = await openMetaDB();
    const entry = await db.get(STORE, key);
    if (!entry || typeof entry !== 'object') return null;
    const candidate = entry as BlobCacheEntry<T>;
    if (typeof candidate.timestamp !== 'number') return null;
    return candidate;
  } catch {
    return null;
  } finally {
    db?.close();
  }
}

/**
 * Write one large object cache entry.
 *
 * @returns whether the write succeeded. Failures do not throw, since the cache is best effort and a failed write only costs one extra network round trip.
 */
export async function writeBlob<T>(key: string, value: T): Promise<boolean> {
  let db;
  try {
    db = await openMetaDB();
    const entry: BlobCacheEntry<T> = { value, timestamp: Date.now() };
    await db.put(STORE, entry, key);
    return true;
  } catch {
    return false;
  } finally {
    db?.close();
  }
}

/** Delete one cache entry; failures are silent. */
export async function deleteBlob(key: string): Promise<void> {
  let db;
  try {
    db = await openMetaDB();
    await db.delete(STORE, key);
  } catch {
    /* Failing to delete a cache entry does not affect correctness */
  } finally {
    db?.close();
  }
}

/**
 * Delete every key matching the prefix that is not in the retain set (generational cleanup for a
 * bucketed cache). Failures are silent, and the number of keys actually deleted is returned for diagnostics.
 */
export async function pruneBlobs(prefix: string, keep: readonly string[]): Promise<number> {
  let db;
  try {
    db = await openMetaDB();
    const keys = await db.getAllKeys(STORE);
    const keepSet = new Set(keep);
    const doomed = keys.filter(
      (key): key is string =>
        typeof key === 'string' && key.startsWith(prefix) && !keepSet.has(key),
    );
    if (doomed.length === 0) return 0;
    const tx = db.transaction(STORE, 'readwrite');
    await Promise.all([...doomed.map((key) => tx.store.delete(key)), tx.done]);
    return doomed.length;
  } catch {
    return 0;
  } finally {
    db?.close();
  }
}
