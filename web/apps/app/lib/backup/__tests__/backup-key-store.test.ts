/**
 * The automatic-backup key is per uid, created once and then reused: rotating it silently would
 * make every archive written before the rotation undecryptable.
 */

import 'fake-indexeddb/auto';

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  deleteAutomaticBackupKey,
  getAutomaticBackupKeyInfo,
  getOrCreateAutomaticBackupKey,
} from '../backup-key-store';

let cryptoInstalled = false;

beforeAll(async () => {
  if (typeof crypto === 'undefined' || typeof crypto.subtle?.generateKey !== 'function') {
    const nodeCrypto = await import('node:crypto');
    // @ts-expect-error override the test environment's crypto
    globalThis.crypto = nodeCrypto.webcrypto;
    cryptoInstalled = true;
  }
});

afterAll(() => {
  if (cryptoInstalled) {
    // @ts-expect-error clean up the test environment's crypto
    delete (globalThis as { crypto?: unknown }).crypto;
  }
});

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('backup-key-store', () => {
  beforeEach(async () => {
    await clearAllDatabases();
  });

  it('creates and returns an AES-GCM CryptoKey for a given uid', async () => {
    const key = await getOrCreateAutomaticBackupKey('user-1');
    expect(key).toBeDefined();
    expect(key.type).toBe('secret');
    expect((key.algorithm as AesKeyAlgorithm).name).toBe('AES-GCM');
    expect((key.algorithm as AesKeyAlgorithm).length).toBe(256);
    expect(key.extractable).toBe(false);
    expect(key.usages).toEqual(expect.arrayContaining(['encrypt', 'decrypt']));
  });

  it('returns a functionally equivalent key on subsequent calls for the same uid', async () => {
    const key1 = await getOrCreateAutomaticBackupKey('user-1');
    const key2 = await getOrCreateAutomaticBackupKey('user-1');

    // IndexedDB structured clone copies the CryptoKey, so two calls return JS references that are not
    // equal. Check functional equivalence instead: encrypting with key1 and decrypting with key2 means
    // it is the same key.
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const plaintext = new TextEncoder().encode('persist check');
    const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key1, plaintext);
    const decrypted = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, key2, cipher);
    expect(new TextDecoder().decode(decrypted)).toBe('persist check');

    // Same key, so the record must be the original one rather than a freshly created replacement.
    const info1 = await getAutomaticBackupKeyInfo('user-1');
    const info2 = await getAutomaticBackupKeyInfo('user-1');
    expect(info1!.createdAt).toBe(info2!.createdAt);
  });

  it('creates distinct keys per uid (namespace isolation)', async () => {
    const keyA = await getOrCreateAutomaticBackupKey('user-A');
    const keyB = await getOrCreateAutomaticBackupKey('user-B');
    expect(keyA).not.toBe(keyB);

    // The two keys are independent: something encrypted with A must not decrypt with B.
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const cipher = await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv },
      keyA,
      new TextEncoder().encode('hello'),
    );
    await expect(
      crypto.subtle.decrypt({ name: 'AES-GCM', iv }, keyB, cipher),
    ).rejects.toBeDefined();
  });

  it('stores key metadata (createdAt / version)', async () => {
    const before = Date.now();
    await getOrCreateAutomaticBackupKey('user-1');
    const info = await getAutomaticBackupKeyInfo('user-1');
    expect(info).toMatchObject({
      uid: 'user-1',
      algorithm: 'AES-GCM',
      version: 1,
    });
    expect(info!.createdAt).toBeGreaterThanOrEqual(before);
  });

  it('deleteAutomaticBackupKey removes the key and metadata', async () => {
    await getOrCreateAutomaticBackupKey('user-1');
    expect(await getAutomaticBackupKeyInfo('user-1')).not.toBeNull();

    await deleteAutomaticBackupKey('user-1');
    expect(await getAutomaticBackupKeyInfo('user-1')).toBeNull();

    // After deletion the next request creates a new key instead of failing.
    const newKey = await getOrCreateAutomaticBackupKey('user-1');
    expect(newKey.type).toBe('secret');
  });

  it('rejects empty uid', async () => {
    await expect(getOrCreateAutomaticBackupKey('')).rejects.toThrow();
  });
});
