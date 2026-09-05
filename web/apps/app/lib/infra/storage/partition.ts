import { openDB } from 'idb';

const META_DB = 'oriveo-meta';
// v1: meta store (activeUID)
// v2: blobs store -- cache for large objects such as the metadata catalog snapshot.
//     This data used to be written wholesale to localStorage; a single /api/metadata
//     response measures 3.3MB in production, which eats 66% of Chrome's 5MB quota and
//     squeezes out the sync mutation broadcast key (a QuotaExceededError that then
//     trips an assertion inside the SDK).
//     The IDB quota scales with disk (gigabytes), which is the only correct home for it.
const META_VERSION = 2;

// Synchronously readable mirror of the current activeUID.
// preferences.ts is a synchronous API over localStorage and cannot await getActiveUID()
// to read the real value out of IDB, so this module-level mirror is kept in step:
// getActiveUID/setActiveUID update it on every IDB read and write, and preferences reads
// it through getActiveUIDSync() to build per-UID preference keys.
// Defaults to 'guest'; bootstrap and sign-out both call setActiveUID to correct it before
// hydrating or reading preferences.
let currentActiveUID = 'guest';

/**
 * Opens the global, unpartitioned meta DB.
 *
 * The `meta` and `blobs` stores share one database and one version number, so the
 * upgrade must be defined in this single entry point: two separate openDB calls would
 * block each other on a concurrent open because their upgrades disagree.
 * blob-cache.ts reuses this function rather than opening its own.
 */
export async function openMetaDB() {
  return openDB(META_DB, META_VERSION, {
    upgrade(db) {
      if (!db.objectStoreNames.contains('meta')) {
        db.createObjectStore('meta');
      }
      if (!db.objectStoreNames.contains('blobs')) {
        db.createObjectStore('blobs');
      }
    },
  });
}

async function getMetaDB() {
  return openMetaDB();
}

/**   ID */
export async function getActiveUID(): Promise<string> {
  const db = await getMetaDB();
  try {
    const uid = await db.get('meta', 'activeUID');
    const resolved = (uid as string) ?? 'guest';
    currentActiveUID = resolved; //   IDB  
    return resolved;
  } finally {
    db.close();
  }
}

/**
 * Reads the active user id synchronously, without touching IDB.
 * Used by synchronous APIs such as preferences.ts to build per-UID keys; the value is
 * maintained by getActiveUID and setActiveUID.
 */
export function getActiveUIDSync(): string {
  return currentActiveUID;
}

/**   ID */
export async function setActiveUID(uid: string): Promise<void> {
  const db = await getMetaDB();
  try {
    await db.put('meta', uid, 'activeUID');
    currentActiveUID = uid; //  
  } finally {
    db.close();
  }
}

/** Name of the user's main IDB database. */
export function getDBName(uid: string): string {
  return `oriveo--${uid}`;
}

/** Name of the user's ImageStore IDB database. */
export function getImageDBName(uid: string): string {
  return `oriveo-images--${uid}`;
}

/** Reports whether a user partition holds any data, without creating a database that does not exist. */
export async function hasPartitionData(uid: string): Promise<boolean> {
  const dbName = getDBName(uid);

  // Check that the database exists first, so openDB does not create an empty one and skip the later upgrade.
  const databases = await indexedDB.databases();
  if (!databases.some((d) => d.name === dbName)) return false;

  let db;
  try {
    db = await openDB(dbName);
    // The database may exist without the stores, if it was created by mistake.
    if (!db.objectStoreNames.contains('conversations') && !db.objectStoreNames.contains('providers')) {
      return false;
    }
    const count = db.objectStoreNames.contains('conversations') ? await db.count('conversations') : 0;
    const providerCount = db.objectStoreNames.contains('providers') ? await db.count('providers') : 0;
    return count > 0 || providerCount > 0;
  } catch {
    return false;
  } finally {
    db?.close();
  }
}

/** Deletes one profile partition's data along with its image database. */
export async function deletePartitionData(uid: string): Promise<void> {
  const dbNames = [getDBName(uid), getImageDBName(uid)];

  await Promise.all(dbNames.map((dbName) => new Promise<void>((resolve) => {
    const request = indexedDB.deleteDatabase(dbName);
    request.onsuccess = () => resolve();
    request.onerror = () => resolve();
    request.onblocked = () => resolve();
  })));
}

/** Reports whether oriveo-meta already exists, which decides whether a migration is needed. */
export async function metaDBExists(): Promise<boolean> {
  const databases = await indexedDB.databases();
  return databases.some((db) => db.name === META_DB);
}

/** Whether the pre-partition database still exists (used by the migration). */
export async function legacyDBExists(): Promise<boolean> {
  const databases = await indexedDB.databases();
  return databases.some((db) => db.name === 'oriveo');
}

/** Copies every image from the guest image IDB into the target user's image IDB. */
export async function copyGuestImages(targetUID: string): Promise<void> {
  const guestDBName = getImageDBName('guest');
  const targetDBName = getImageDBName(targetUID);

  // Check whether the guest image database exists.
  const databases = await indexedDB.databases();
  if (!databases.some((d) => d.name === guestDBName)) return;

  let guestDB;
  let targetDB;
  try {
    guestDB = await openDB(guestDBName);
    if (!guestDB.objectStoreNames.contains('images')) return;

    const allImages = await guestDB.getAll('images');
    if (allImages.length === 0) return;

    targetDB = await openDB(targetDBName, 1, {
      upgrade(db) {
        if (!db.objectStoreNames.contains('images')) {
          db.createObjectStore('images', { keyPath: 'id' });
        }
      },
    });

    const tx = targetDB.transaction('images', 'readwrite');
    for (const img of allImages) {
      //   iOS copyGuestImages  
      const existing = await tx.store.getKey(img.id);
      if (existing === undefined) {
        await tx.store.put(img);
      }
    }
    await tx.done;
  } catch {
    // A failed image copy must not block the rest.
  } finally {
    guestDB?.close();
    targetDB?.close();
  }
}
