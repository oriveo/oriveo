import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import {
  getActiveUID,
  getActiveUIDSync,
  setActiveUID,
  getDBName,
  getImageDBName,
  hasPartitionData,
  metaDBExists,
  legacyDBExists,
} from '../partition';
import { openDB } from 'idb';

/** Delete every IDB database (fake-indexeddb reset) */
async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('partition.ts', () => {
  beforeEach(async () => {
    await clearAllDatabases();
  });

  // ── 1.1 getActiveUID ──────────────────────────────────

  describe('getActiveUID', () => {
    it('should return "guest" when meta DB has no data', async () => {
      const uid = await getActiveUID();
      expect(uid).toBe('guest');
    });

    it('should return "guest" after setActiveUID("guest")', async () => {
      await setActiveUID('guest');
      const uid = await getActiveUID();
      expect(uid).toBe('guest');
    });

    it('should return the uid after setActiveUID("uid-abc")', async () => {
      await setActiveUID('uid-abc');
      const uid = await getActiveUID();
      expect(uid).toBe('uid-abc');
    });
  });

  // ── 1.2 setActiveUID ─────────────────────────────────

  describe('setActiveUID', () => {
    it('should persist "guest"', async () => {
      await setActiveUID('guest');
      expect(await getActiveUID()).toBe('guest');
    });

    it('should persist a user uid', async () => {
      await setActiveUID('uid-abc');
      expect(await getActiveUID()).toBe('uid-abc');
    });

    it('should return the last value after consecutive sets', async () => {
      await setActiveUID('uid-1');
      await setActiveUID('uid-2');
      await setActiveUID('uid-3');
      expect(await getActiveUID()).toBe('uid-3');
    });
  });

  // ── 1.2b getActiveUIDSync mirror ───────────────────

  describe('getActiveUIDSync', () => {
    it('updates the synchronous mirror immediately after setActiveUID, with no await on IDB', async () => {
      await setActiveUID('uid-sync');
      expect(getActiveUIDSync()).toBe('uid-sync');
    });

    it('keeps the synchronous mirror aligned with the truth after getActiveUID reads IDB', async () => {
      await setActiveUID('uid-mirror');
      // Read the truth straight from IDB; the mirror should match
      expect(await getActiveUID()).toBe('uid-mirror');
      expect(getActiveUIDSync()).toBe('uid-mirror');
    });
  });

  // ── 1.3 getDBName (pure function) ────────────────────

  describe('getDBName', () => {
    it('should return "oriveo--guest" for "guest"', () => {
      expect(getDBName('guest')).toBe('oriveo--guest');
    });

    it('should return "oriveo--abc123" for "abc123"', () => {
      expect(getDBName('abc123')).toBe('oriveo--abc123');
    });
  });

  // ── 1.4 getImageDBName (pure function) ────────────────

  describe('getImageDBName', () => {
    it('should return "oriveo-images--guest" for "guest"', () => {
      expect(getImageDBName('guest')).toBe('oriveo-images--guest');
    });

    it('should return "oriveo-images--abc123" for "abc123"', () => {
      expect(getImageDBName('abc123')).toBe('oriveo-images--abc123');
    });
  });

  // ── 1.5 hasPartitionData ──────────────────────────────

  describe('hasPartitionData', () => {
    it('should return false when partition DB does not exist', async () => {
      expect(await hasPartitionData('nonexistent')).toBe(false);
    });

    it('should return false when DB exists but has no data', async () => {
      // Create the DB with stores but no data
      const dbName = getDBName('empty-user');
      const db = await openDB(dbName, 1, {
        upgrade(database) {
          database.createObjectStore('conversations', { keyPath: 'id' });
          database.createObjectStore('providers', { keyPath: 'id' });
        },
      });
      db.close();

      expect(await hasPartitionData('empty-user')).toBe(false);
    });

    it('should return true when partition has conversations', async () => {
      const dbName = getDBName('has-conv');
      const db = await openDB(dbName, 1, {
        upgrade(database) {
          database.createObjectStore('conversations', { keyPath: 'id' });
          database.createObjectStore('providers', { keyPath: 'id' });
        },
      });
      await db.put('conversations', { id: 'c1', title: 'test' });
      db.close();

      expect(await hasPartitionData('has-conv')).toBe(true);
    });

    it('should return true when partition has providers only', async () => {
      const dbName = getDBName('has-prov');
      const db = await openDB(dbName, 1, {
        upgrade(database) {
          database.createObjectStore('conversations', { keyPath: 'id' });
          database.createObjectStore('providers', { keyPath: 'id' });
        },
      });
      await db.put('providers', { id: 'p1', kind: 'openAI' });
      db.close();

      expect(await hasPartitionData('has-prov')).toBe(true);
    });

    it('should return true when partition has both conversations and providers', async () => {
      const dbName = getDBName('has-both');
      const db = await openDB(dbName, 1, {
        upgrade(database) {
          database.createObjectStore('conversations', { keyPath: 'id' });
          database.createObjectStore('providers', { keyPath: 'id' });
        },
      });
      await db.put('conversations', { id: 'c1', title: 'test' });
      await db.put('providers', { id: 'p1', kind: 'openAI' });
      db.close();

      expect(await hasPartitionData('has-both')).toBe(true);
    });
  });

  // ── 1.6 metaDBExists / legacyDBExists ────────────────

  describe('metaDBExists & legacyDBExists', () => {
    it('should both return false on fresh install', async () => {
      expect(await metaDBExists()).toBe(false);
      expect(await legacyDBExists()).toBe(false);
    });

    it('should detect legacy DB', async () => {
      const db = await openDB('oriveo', 1, {
        upgrade(database) {
          database.createObjectStore('conversations', { keyPath: 'id' });
        },
      });
      db.close();

      expect(await legacyDBExists()).toBe(true);
      expect(await metaDBExists()).toBe(false);
    });

    it('should detect meta DB after setActiveUID', async () => {
      await setActiveUID('guest');

      expect(await metaDBExists()).toBe(true);
    });
  });
});
