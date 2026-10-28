import { type DBSchema, type IDBPDatabase } from 'idb';
import { openDB } from './idb-open';
import { getActiveUID, getImageDBName } from './partition';
import { openWithStaleSchemaRecovery, reportIDBUpgradeBlocked } from './idb-lifecycle';

/* ── Schema ──────────────────────────────────────────── */

interface ImageStoreSchema extends DBSchema {
  images: {
    key: string;
    value: {
      id: string;
      data: Blob;
      // A thumbnail may be absent: when the browser cannot decode the image none can be
      // generated, and having none is better than passing the original off as one, which
      // would store two copies in IDB and add another to the backup bundle.
      thumbnail?: Blob;
      mimeType: string;
      // Save time (ms): the orphan sweep uses it for the 24 h grace period. A plain record field
      // with no index, so no IDB version bump is needed; older records lack it and the first
      // sweep stamps them.
      savedAt?: number;
    };
  };
}

export type StoredImageRecord = ImageStoreSchema['images']['value'];

let currentImageDBName: string | null = null;
let dbPromise: Promise<IDBPDatabase<ImageStoreSchema>> | null = null;

async function getDB(expectedUID?: string) {
  const uid = await getActiveUID();
  if (expectedUID !== undefined && uid !== expectedUID) {
    throw new Error(`Active image storage partition changed from ${expectedUID} to ${uid}`);
  }
  const dbName = getImageDBName(uid);

  if (dbPromise && currentImageDBName === dbName) {
    return dbPromise;
  }

  if (dbPromise && currentImageDBName !== dbName) {
    try {
      const oldDb = await dbPromise;
      oldDb.close();
    } catch { /* ignore */ }
  }

  currentImageDBName = dbName;
  let opened: IDBPDatabase<ImageStoreSchema> | null = null;
  const openPromise = openWithStaleSchemaRecovery(() => openDB<ImageStoreSchema>(dbName, 1, {
    upgrade(db) {
      if (!db.objectStoreNames.contains('images')) {
        db.createObjectStore('images', { keyPath: 'id' });
      }
    },
    blocked: (currentVersion, blockedVersion) =>
      reportIDBUpgradeBlocked(dbName, currentVersion, blockedVersion),
    // Another tab wants to upgrade the image database schema: without making way, its open()
    // never settles. The cache is cleared too (otherwise a closed connection stays cached and
    // every later transaction throws InvalidStateError). The next getDB() still reopens at this
    // bundle's version; if the other tab went higher that is a VersionError, which
    // openWithStaleSchemaRecovery handles by reloading onto the new bundle.
    blocking: () => {
      opened?.close();
      if (currentImageDBName === dbName) {
        dbPromise = null;
        currentImageDBName = null;
      }
    },
  }));
  dbPromise = openPromise;
  // Never keep a failed open in the cache, or every later read and write gets the same rejection.
  openPromise.catch(() => {
    if (dbPromise === openPromise) {
      dbPromise = null;
      currentImageDBName = null;
    }
  });
  opened = await openPromise;
  return opened;
}

/** Reset the connection when the partition changes */
export function resetImageDBConnection() {
  if (dbPromise) {
    dbPromise.then((db) => db.close()).catch(() => {});
  }
  dbPromise = null;
  currentImageDBName = null;
}

/* ── Storage ────────────────────────────────────────────── */

// Image ids saved during this run: extra protection for the launch orphan sweep beyond the savedAt
// grace period (an image just saved but not yet written to the conversation store must not be
// deleted as an orphan). Only grows, released with the page lifecycle.
const sessionSavedIds = new Set<string>();

/** Whether this id was saved during this run (used by the orphan sweep grace check). */
export function wasImageSavedThisSession(id: string): boolean {
  return sessionSavedIds.has(id);
}

/** Save the original image and its thumbnail */
export async function saveImage(
  id: string,
  data: Blob,
  thumbnail: Blob | null | undefined,
  mimeType: string,
  expectedUID?: string,
) {
  // Record before writing: leave no gap between the write committing and the record for the sweep to exploit.
  sessionSavedIds.add(id);
  const db = await getDB(expectedUID);
  await db.put('images', {
    id,
    data,
    ...(thumbnail ? { thumbnail } : {}),
    mimeType,
    savedAt: Date.now(),
  });
}

/* ── Reading ────────────────────────────────────────────── */

/** Read the original image Blob */
export async function loadImageData(id: string, expectedUID?: string): Promise<Blob | null> {
  const db = await getDB(expectedUID);
  const record = await db.get('images', id);
  return record?.data ?? null;
}

/** Read the original image as base64, for sending in an API request */
export async function loadImageBase64(id: string, expectedUID?: string): Promise<string | null> {
  const blob = await loadImageData(id, expectedUID);
  if (!blob) return null;
  return new Promise((resolve) => {
    const reader = new FileReader();
    reader.onloadend = () => {
      const base64 = (reader.result as string).split(',')[1];
      resolve(base64);
    };
    reader.onerror = () => resolve(null);
    reader.readAsDataURL(blob);
  });
}

/** Read the thumbnail Blob */
export async function loadThumbnailData(id: string): Promise<Blob | null> {
  const db = await getDB();
  const record = await db.get('images', id);
  return record?.thumbnail ?? null;
}

/* ── Deletion and checks ────────────────────────────────────── */

/** Delete one image (original + thumbnail); returns the bytes freed (read from Blob metadata only, 0 when unavailable), for cleanup logging. */
export async function deleteImage(id: string, expectedUID?: string): Promise<number> {
  const db = await getDB(expectedUID);
  const tx = db.transaction('images', 'readwrite');
  const record = await tx.store.get(id);
  await tx.store.delete(id);
  await tx.done;
  return recordBytes(record);
}

function blobBytes(value: unknown): number {
  const size = (value as { size?: unknown } | null | undefined)?.size;
  return typeof size === 'number' && Number.isFinite(size) ? size : 0;
}

function recordBytes(record: StoredImageRecord | undefined): number {
  return record ? blobBytes(record.data) + blobBytes(record.thumbnail) : 0;
}

/** All image ids in this partition's image store (keys only, no Blob reads). */
export async function listImageIds(expectedUID?: string): Promise<string[]> {
  const db = await getDB(expectedUID);
  return db.getAllKeys('images');
}

/** All records in this partition's image store (Blobs are only handles, bytes are not read into the JS heap); the orphan sweep reads savedAt and size from them. */
export async function listImageRecords(expectedUID?: string): Promise<StoredImageRecord[]> {
  const db = await getDB(expectedUID);
  return db.getAll('images');
}

/** Stamp the save time on an old record that lacks savedAt; writes nothing when the record is gone or already has savedAt. Writes the image store only. */
export async function stampImageSavedAt(id: string, savedAt: number, expectedUID?: string) {
  const db = await getDB(expectedUID);
  const tx = db.transaction('images', 'readwrite');
  const record = await tx.store.get(id);
  if (record && record.savedAt === undefined) await tx.store.put({ ...record, savedAt });
  await tx.done;
}

/**
 * Size of the original in raw bytes (not base64); 0 when it does not exist or cannot be read.
 *
 * Used by OutboundAttachmentBudget to estimate how much an image adds to the request body
 * before reading it out. IndexedDB hands back a Blob handle whose `.size` is metadata, so
 * reading it does not pull the image bytes into the JS heap - otherwise the budget check
 * would consume the very memory it is meant to save.
 * An unmeasurable size counts as 0: better to trim one image too few than to let the size
 * probe break the whole send.
 */
export async function imageSizeBytes(id: string): Promise<number> {
  try {
    const db = await getDB();
    const record = await db.get('images', id);
    return record?.data.size ?? 0;
  } catch {
    return 0;
  }
}

/** Check whether an image exists, by key only, without reading the whole Blob */
export async function imageExists(id: string, expectedUID?: string): Promise<boolean> {
  const db = await getDB(expectedUID);
  const key = await db.getKey('images', id);
  return key !== undefined;
}

/* ── Thumbnail generation ──────────────────────────────────────── */

/** Generate a thumbnail by scaling on a canvas, at 120px and JPEG quality 0.5 */
export async function generateThumbnail(
  imageBlob: Blob,
  maxSize = 120,
): Promise<Blob> {
  const bitmap = await createImageBitmap(imageBlob);
  const scale = Math.min(maxSize / Math.max(bitmap.width, bitmap.height), 1);
  const w = Math.round(bitmap.width * scale);
  const h = Math.round(bitmap.height * scale);

  const canvas = new OffscreenCanvas(w, h);
  const ctx = canvas.getContext('2d')!;
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close();

  return canvas.convertToBlob({ type: 'image/jpeg', quality: 0.5 });
}
