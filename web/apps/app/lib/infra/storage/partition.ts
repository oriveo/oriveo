import { type IDBPDatabase } from 'idb';
import { openDB } from './idb-open';
import { openWithStaleSchemaRecovery, reportIDBUpgradeBlocked, reportPartitionDeleteIncomplete } from './idb-lifecycle';

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
  let opened: IDBPDatabase | null = null;
  const openPromise = openWithStaleSchemaRecovery(() => openDB(META_DB, META_VERSION, {
    upgrade(db) {
      if (!db.objectStoreNames.contains('meta')) {
        db.createObjectStore('meta');
      }
      if (!db.objectStoreNames.contains('blobs')) {
        db.createObjectStore('blobs');
      }
    },
    blocked: (currentVersion, blockedVersion) =>
      reportIDBUpgradeBlocked(META_DB, currentVersion, blockedVersion),
    // Every caller of this function closes the connection in finally, so it is short-lived
    // anyway. But one hanging await is enough for another tab's open() to never settle when it
    // bumps META_VERSION. The cost of making way is that the hanging read or write throws
    // InvalidStateError (every caller swallows that and treats it as "nothing cached"), which
    // beats both tabs being stuck.
    blocking: () => opened?.close(),
  }));
  opened = await openPromise;
  return opened;
}

async function getMetaDB() {
  return openMetaDB();
}

/** Reads the active user id from IDB; an unset value means the guest partition. */
export async function getActiveUID(): Promise<string> {
  const db = await getMetaDB();
  try {
    const uid = await db.get('meta', 'activeUID');
    const resolved = (uid as string) ?? 'guest';
    currentActiveUID = resolved; // keeps getActiveUIDSync usable from synchronous callers
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

/** Switches the active partition and updates the synchronous mirror in the same step. */
export async function setActiveUID(uid: string): Promise<void> {
  const db = await getMetaDB();
  try {
    await db.put('meta', uid, 'activeUID');
    currentActiveUID = uid; // keeps getActiveUIDSync usable from synchronous callers
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

/** Name of the remote MCP IDB database (server records, device-local state and MCP credentials; see core/mcp/mcp-idb.ts). */
export function getMcpDBName(uid: string): string {
  return `oriveo-mcp--${uid}`;
}

/** Name of the external search service IDB database (service list and search keys; see lib/search/search-service-store.ts). */
export function getSearchDBName(uid: string): string {
  return `oriveo-search--${uid}`;
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

// Long enough for other tabs to close on versionchange, short enough not to hang sign-out.
const PARTITION_DELETE_WAIT_MS = 5000;

/**
 * Waits for the real outcome of one delete. `blocked` is not an outcome: the request stays queued
 * and only runs once the last connection closes, so resolving there reports data that still exists.
 */
function deleteDatabaseSettled(dbName: string): Promise<void> {
  return new Promise<void>((resolve) => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const settle = (outcome?: 'error' | 'timeout') => {
      clearTimeout(timer);
      if (outcome) reportPartitionDeleteIncomplete(dbName, outcome);
      resolve();
    };
    try {
      const request = indexedDB.deleteDatabase(dbName);
      request.onsuccess = () => settle();
      request.onerror = () => settle('error');
      timer = setTimeout(() => settle('timeout'), PARTITION_DELETE_WAIT_MS);
    } catch {
      // Storage access can be denied outright; sign-out still has to finish.
      settle('error');
    }
  });
}

/**
 * Deletes the data, image, MCP and external search databases of a user partition. The MCP and search
 * databases hold that account's credentials. Open connections close themselves on versionchange
 * (the `blocking` callback of each store); this waits for them, then reports what did not finish.
 */
export async function deletePartitionData(uid: string): Promise<void> {
  const dbNames = [getDBName(uid), getImageDBName(uid), getMcpDBName(uid), getSearchDBName(uid)];
  await Promise.all(dbNames.map(deleteDatabaseSettled));
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
      // Only fill gaps: an id the target partition already holds is left as it is, so copying
      // twice cannot overwrite an image the signed-in user has since replaced.
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
