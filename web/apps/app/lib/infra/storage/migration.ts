import { openDB, type IDBPDatabase } from 'idb';
import { setActiveUID, getDBName, getImageDBName, legacyDBExists } from './partition';
import { safeLocalStorage } from './web-storage';

const MIGRATED_KEY = 'oriveo.storage.partitioned';
// Has to match idb.ts:DB_VERSION: the one-time migration from the unpartitioned database must
// create the current schema version directly, or openPartitionDB later triggers a v2 to v3
// upgrade against stores that already exist, wasting an upgrade cycle.
const PARTITION_DB_VERSION = 10;

/**
 * Migrates data from the old IDB layout into the partitioned one, once, on first launch.
 * Old DB "oriveo" becomes "oriveo--guest" or "oriveo--{uid}".
 *
 * This is step 1 of `bootstrapApp`, so throwing here breaks the entire startup sequence and
 * steps 2 to 6 are skipped. Every localStorage access here therefore has to go through
 * {@link safeLocalStorage}: when the browser blocks site data, the `window.localStorage` getter
 * itself throws SecurityError, and a bare `localStorage.getItem` once killed the whole app on
 * that line. Failing to write the marker only means the next launch reruns an idempotent
 * migration, which costs far less than failing to start.
 */
export async function migrateToPartitionedStorage(): Promise<void> {
  if (safeLocalStorage.getItem(MIGRATED_KEY) === 'true') return;

  const hasLegacy = await legacyDBExists();
  if (!hasLegacy) {
    // No old data (fresh install), so just initialize the metadata
    await setActiveUID('guest');
    safeLocalStorage.setItem(MIGRATED_KEY, 'true');
    return;
  }

  // Target partition: migrate into guest first, and the auth observer handles the switch afterwards
  const targetUID = 'guest';

  // Only mark as migrated once both the main data and the images have moved successfully
  await migrateMainData(targetUID);
  await migrateImageData(targetUID);

  await setActiveUID(targetUID);
  safeLocalStorage.setItem(MIGRATED_KEY, 'true');
}

/** Migrate the conversations, providers and session stores */
async function migrateMainData(targetUID: string): Promise<void> {
  const oldDB = await openDB('oriveo');
  const newDB = await openPartitionDB(targetUID);

  try {
    await migrateStore(oldDB, newDB, 'conversations');
    await migrateStore(oldDB, newDB, 'providers');
    await migrateSessionStore(oldDB, newDB);
  } finally {
    newDB.close();
    oldDB.close();
  }
}

/** Write in bulk inside one IDB transaction instead of awaiting in a loop */
async function migrateStore(
  oldDB: IDBPDatabase,
  newDB: IDBPDatabase,
  storeName: 'conversations' | 'providers',
): Promise<void> {
  if (!oldDB.objectStoreNames.contains(storeName)) return;

  const items = await oldDB.getAll(storeName);
  if (items.length === 0) return;

  const tx = newDB.transaction(storeName, 'readwrite');
  items.forEach((item) => tx.store.put(item));
  await tx.done;
}

/** The session store uses out-of-line keys and needs special handling */
async function migrateSessionStore(
  oldDB: IDBPDatabase,
  newDB: IDBPDatabase,
): Promise<void> {
  if (!oldDB.objectStoreNames.contains('session')) return;

  // Read every key-value pair from the old database first
  const oldTx = oldDB.transaction('session', 'readonly');
  const keys = await oldTx.objectStore('session').getAllKeys();
  await oldTx.done;

  if (keys.length === 0) return;

  const entries: { key: IDBValidKey; value: unknown }[] = [];
  for (const key of keys) {
    const value = await oldDB.get('session', key);
    if (value !== undefined) entries.push({ key, value });
  }

  // Bulk write into the new database (no awaits on the other database inside the transaction, which would auto-commit it)
  const newTx = newDB.transaction('session', 'readwrite');
  entries.forEach(({ key, value }) => newTx.store.put(value, key));
  await newTx.done;
}

/** Migrate the image store */
async function migrateImageData(targetUID: string): Promise<void> {
  const hasOldImages = (await indexedDB.databases()).some((db) => db.name === 'oriveo-images');
  if (!hasOldImages) return;

  const oldImageDB = await openDB('oriveo-images');
  const newImageDB = await openDB(getImageDBName(targetUID), 1, {
    upgrade(db) {
      if (!db.objectStoreNames.contains('images')) {
        db.createObjectStore('images', { keyPath: 'id' });
      }
    },
  });

  try {
    if (oldImageDB.objectStoreNames.contains('images')) {
      const images = await oldImageDB.getAll('images');
      if (images.length > 0) {
        const tx = newImageDB.transaction('images', 'readwrite');
        images.forEach((img) => tx.store.put(img));
        await tx.done;
      }
    }
  } finally {
    newImageDB.close();
    oldImageDB.close();
  }
}

/** Create the partitioned database */
async function openPartitionDB(uid: string): Promise<IDBPDatabase> {
  return openDB(getDBName(uid), PARTITION_DB_VERSION, {
    upgrade(db) {
      if (!db.objectStoreNames.contains('conversations')) {
        const cs = db.createObjectStore('conversations', { keyPath: 'id' });
        cs.createIndex('by-updated', 'updatedAt');
      }
      if (!db.objectStoreNames.contains('providers')) {
        db.createObjectStore('providers', { keyPath: 'id' });
      }
      if (!db.objectStoreNames.contains('session')) {
        db.createObjectStore('session');
      }
      if (!db.objectStoreNames.contains('folders')) {
        const fs = db.createObjectStore('folders', { keyPath: 'id' });
        fs.createIndex('by-sortOrder', 'sortOrder');
      }
      if (!db.objectStoreNames.contains('notes')) {
        const ns = db.createObjectStore('notes', { keyPath: 'id' });
        ns.createIndex('by-updated', 'updatedAt');
      }
      if (!db.objectStoreNames.contains('noteFolders')) {
        const nfs = db.createObjectStore('noteFolders', { keyPath: 'id' });
        nfs.createIndex('by-sortOrder', 'sortOrder');
      }
      if (!db.objectStoreNames.contains('pendingConversationDeletions')) {
        db.createObjectStore('pendingConversationDeletions', { keyPath: 'conversationId' });
      }
      if (!db.objectStoreNames.contains('pendingProviderDeletions')) {
        db.createObjectStore('pendingProviderDeletions', { keyPath: 'providerId' });
      }
    },
  });
}
