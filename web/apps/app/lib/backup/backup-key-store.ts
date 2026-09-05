/**
 * Automatic backup key storage.
 *
 * Design points:
 * - AES-256-GCM, `extractable: false`
 * - Kept in its own IndexedDB database `oriveo-merge-archive-keys`, decoupled from the main partition DB so a partition rebuild cannot delete it
 * - Namespaced by uid: account B cannot use account A's key
 * - IDB stores a CryptoKey natively (structured clone), so no wrapKey / raw export is needed
 * - On unwrap failure or a deleted key a new one is generated and old ciphertext is lost (the key is the data)
 */

const KEY_DB_NAME = 'oriveo-merge-archive-keys';
const KEY_DB_VERSION = 1;
const KEY_STORE_NAME = 'keys';
const KEY_META_STORE_NAME = 'key_info';

interface StoredKeyInfo {
  uid: string;
  createdAt: number;
  algorithm: 'AES-GCM';
  version: number;
}

function openKeyDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(KEY_DB_NAME, KEY_DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(KEY_STORE_NAME)) {
        db.createObjectStore(KEY_STORE_NAME);
      }
      if (!db.objectStoreNames.contains(KEY_META_STORE_NAME)) {
        db.createObjectStore(KEY_META_STORE_NAME, { keyPath: 'uid' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('open_key_db_failed'));
  });
}

function promisifyRequest<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('idb_request_failed'));
  });
}

/**
 * Gets or creates the automatic backup key for a uid. The first call generates and persists it; later calls return the stored CryptoKey.
 */
export async function getOrCreateAutomaticBackupKey(uid: string): Promise<CryptoKey> {
  if (!uid) {
    throw new Error('getOrCreateAutomaticBackupKey: uid is required');
  }

  const db = await openKeyDB();
  try {
    const readTx = db.transaction([KEY_STORE_NAME], 'readonly');
    const existing = await promisifyRequest(readTx.objectStore(KEY_STORE_NAME).get(uid));
    if (existing instanceof CryptoKey) {
      return existing;
    }

    const key = await crypto.subtle.generateKey(
      { name: 'AES-GCM', length: 256 },
      false, // extractable: false, so XSS cannot export the raw bytes
      ['encrypt', 'decrypt'],
    );

    const writeTx = db.transaction([KEY_STORE_NAME, KEY_META_STORE_NAME], 'readwrite');
    await promisifyRequest(writeTx.objectStore(KEY_STORE_NAME).put(key, uid));
    const info: StoredKeyInfo = {
      uid,
      createdAt: Date.now(),
      algorithm: 'AES-GCM',
      version: 1,
    };
    await promisifyRequest(writeTx.objectStore(KEY_META_STORE_NAME).put(info));
    await new Promise<void>((resolve, reject) => {
      writeTx.oncomplete = () => resolve();
      writeTx.onabort = () => reject(writeTx.error ?? new Error('tx_abort'));
      writeTx.onerror = () => reject(writeTx.error ?? new Error('tx_error'));
    });

    return key;
  } finally {
    db.close();
  }
}

/** Account-switch cleanup: removes the key and metadata for a uid */
export async function deleteAutomaticBackupKey(uid: string): Promise<void> {
  const db = await openKeyDB();
  try {
    const tx = db.transaction([KEY_STORE_NAME, KEY_META_STORE_NAME], 'readwrite');
    await promisifyRequest(tx.objectStore(KEY_STORE_NAME).delete(uid));
    await promisifyRequest(tx.objectStore(KEY_META_STORE_NAME).delete(uid));
    await new Promise<void>((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onabort = () => reject(tx.error ?? new Error('tx_abort'));
      tx.onerror = () => reject(tx.error ?? new Error('tx_error'));
    });
  } finally {
    db.close();
  }
}

/** Reads the key metadata without returning the CryptoKey itself; diagnostics and tests only */
export async function getAutomaticBackupKeyInfo(uid: string): Promise<StoredKeyInfo | null> {
  const db = await openKeyDB();
  try {
    const tx = db.transaction([KEY_META_STORE_NAME], 'readonly');
    const info = await promisifyRequest(tx.objectStore(KEY_META_STORE_NAME).get(uid));
    return (info as StoredKeyInfo | undefined) ?? null;
  } finally {
    db.close();
  }
}

export type { StoredKeyInfo };
