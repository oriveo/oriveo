import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import { getActiveUID, getImageDBName } from './partition';

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
    };
  };
}

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
  dbPromise = openDB<ImageStoreSchema>(dbName, 1, {
    upgrade(db) {
      if (!db.objectStoreNames.contains('images')) {
        db.createObjectStore('images', { keyPath: 'id' });
      }
    },
  });
  return dbPromise;
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

/** Save the original image and its thumbnail */
export async function saveImage(
  id: string,
  data: Blob,
  thumbnail: Blob | null | undefined,
  mimeType: string,
  expectedUID?: string,
) {
  const db = await getDB(expectedUID);
  await db.put('images', { id, data, ...(thumbnail ? { thumbnail } : {}), mimeType });
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

/** Delete an image */
export async function deleteImage(id: string, expectedUID?: string) {
  const db = await getDB(expectedUID);
  await db.delete('images', id);
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
