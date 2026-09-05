import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import { openDB } from 'idb';
import { migrateToPartitionedStorage } from '../migration';
import { getActiveUID, getDBName, getImageDBName } from '../partition';

const MIGRATED_KEY = 'oriveo.storage.partitioned';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

/** Create a legacy oriveo DB and write test data into it */
async function createLegacyDB(options?: {
  conversations?: Array<{ id: string; title: string }>;
  providers?: Array<{ id: string; kind: string }>;
  session?: Array<{ key: string; value: unknown }>;
}) {
  const db = await openDB('oriveo', 1, {
    upgrade(database) {
      const cs = database.createObjectStore('conversations', { keyPath: 'id' });
      cs.createIndex('by-updated', 'updatedAt');
      database.createObjectStore('providers', { keyPath: 'id' });
      database.createObjectStore('session');
    },
  });

  if (options?.conversations) {
    for (const c of options.conversations) {
      await db.put('conversations', { ...c, updatedAt: new Date().toISOString(), messages: [] });
    }
  }
  if (options?.providers) {
    for (const p of options.providers) {
      await db.put('providers', p);
    }
  }
  if (options?.session) {
    for (const s of options.session) {
      await db.put('session', s.value, s.key);
    }
  }

  db.close();
}

/** Create a legacy oriveo-images DB and write test data into it */
async function createLegacyImageDB(images: Array<{ id: string; data: string }>) {
  const db = await openDB('oriveo-images', 1, {
    upgrade(database) {
      database.createObjectStore('images', { keyPath: 'id' });
    },
  });

  for (const img of images) {
    await db.put('images', { id: img.id, data: img.data, thumbnail: 'thumb', mimeType: 'image/png' });
  }

  db.close();
}

describe('migration.ts', () => {
  beforeEach(async () => {
    await clearAllDatabases();
    localStorage.clear();
  });

  // ── First install, no legacy data ───────────────────────

  describe('fresh install (no legacy data)', () => {
    it('should set activeUID to "guest" and mark as migrated', async () => {
      await migrateToPartitionedStorage();

      expect(await getActiveUID()).toBe('guest');
      expect(localStorage.getItem(MIGRATED_KEY)).toBe('true');
    });

    it('should skip on second call', async () => {
      await migrateToPartitionedStorage();
      // Modify activeUID to detect if migration runs again
      const { setActiveUID } = await import('../partition');
      await setActiveUID('modified');

      await migrateToPartitionedStorage();

      // If migration ran again it would reset to 'guest'
      expect(await getActiveUID()).toBe('modified');
    });
  });

  // ── Legacy data present ──────────────────────────────────

  describe('legacy data migration', () => {
    it('should migrate conversations to oriveo--guest', async () => {
      await createLegacyDB({
        conversations: [
          { id: 'c1', title: 'Chat 1' },
          { id: 'c2', title: 'Chat 2' },
        ],
      });

      await migrateToPartitionedStorage();

      const newDB = await openDB(getDBName('guest'));
      const convs = await newDB.getAll('conversations');
      newDB.close();

      expect(convs).toHaveLength(2);
      expect(convs.map((c) => c.id).sort()).toEqual(['c1', 'c2']);
    });

    it('should migrate providers to oriveo--guest', async () => {
      await createLegacyDB({
        providers: [{ id: 'p1', kind: 'openAI' }],
      });

      await migrateToPartitionedStorage();

      const newDB = await openDB(getDBName('guest'));
      const providers = await newDB.getAll('providers');
      newDB.close();

      expect(providers).toHaveLength(1);
      expect(providers[0].id).toBe('p1');
    });

    it('should create migrated partition database at the current schema version', async () => {
      await createLegacyDB({
        providers: [{ id: 'p1', kind: 'openAI' }],
      });

      await migrateToPartitionedStorage();

      const newDB = await openDB(getDBName('guest'));
      const version = newDB.version;
      const hasFolders = newDB.objectStoreNames.contains('folders');
      const hasNotes = newDB.objectStoreNames.contains('notes');
      const hasNoteFolders = newDB.objectStoreNames.contains('noteFolders');
      newDB.close();

      // DB schema v10 ChatMessage QuoteContext v1 snapshot.
      expect(version).toBe(10);
      expect(hasFolders).toBe(true);
      expect(hasNotes).toBe(true);
      expect(hasNoteFolders).toBe(true);
    });

    it('should migrate session data to oriveo--guest', async () => {
      await createLegacyDB({
        session: [{ key: 'deviceKey', value: { jwk: 'test-key' } }],
      });

      await migrateToPartitionedStorage();

      const newDB = await openDB(getDBName('guest'));
      const val = await newDB.get('session', 'deviceKey');
      newDB.close();

      expect(val).toEqual({ jwk: 'test-key' });
    });

    it('should migrate images to oriveo-images--guest', async () => {
      await createLegacyDB({ conversations: [{ id: 'c1', title: 'test' }] });
      await createLegacyImageDB([{ id: 'img1', data: 'base64data' }]);

      await migrateToPartitionedStorage();

      const newImageDB = await openDB(getImageDBName('guest'));
      const images = await newImageDB.getAll('images');
      newImageDB.close();

      expect(images).toHaveLength(1);
      expect(images[0].id).toBe('img1');
    });

    it('should set activeUID to "guest" after migration', async () => {
      await createLegacyDB({ conversations: [{ id: 'c1', title: 'test' }] });

      await migrateToPartitionedStorage();

      expect(await getActiveUID()).toBe('guest');
    });

    it('should set localStorage migrated flag', async () => {
      await createLegacyDB({ conversations: [{ id: 'c1', title: 'test' }] });

      await migrateToPartitionedStorage();

      expect(localStorage.getItem(MIGRATED_KEY)).toBe('true');
    });
  });

  // ── Idempotency ───────────────────────────────────────

  describe('idempotency', () => {
    it('should not re-migrate after flag is set', async () => {
      await createLegacyDB({
        conversations: [{ id: 'c1', title: 'Original' }],
      });
      await migrateToPartitionedStorage();

      // Modify the migrated data
      const newDB = await openDB(getDBName('guest'));
      await newDB.put('conversations', {
        id: 'c1',
        title: 'Modified',
        updatedAt: new Date().toISOString(),
        messages: [],
      });
      newDB.close();

      // Create new legacy data
      const oldDB = await openDB('oriveo');
      if (oldDB.objectStoreNames.contains('conversations')) {
        await oldDB.put('conversations', {
          id: 'c1',
          title: 'Should Not Overwrite',
          updatedAt: new Date().toISOString(),
          messages: [],
        });
      }
      oldDB.close();

      // Run migration again — should skip
      await migrateToPartitionedStorage();

      const checkDB = await openDB(getDBName('guest'));
      const conv = await checkDB.get('conversations', 'c1');
      checkDB.close();

      expect(conv?.title).toBe('Modified');
    });
  });

  // ── Error tolerance ─────────────────────────────────────

  describe('error tolerance', () => {
    it('should not crash when legacy DB has no conversations store', async () => {
      // Create a minimal legacy DB without conversations store
      const db = await openDB('oriveo', 1, {
        upgrade(database) {
          database.createObjectStore('providers', { keyPath: 'id' });
        },
      });
      await db.put('providers', { id: 'p1', kind: 'openAI' });
      db.close();

      // Should not throw
      await expect(migrateToPartitionedStorage()).resolves.not.toThrow();
      expect(localStorage.getItem(MIGRATED_KEY)).toBe('true');
    });

    it('should not crash when legacy DB has no providers store', async () => {
      const db = await openDB('oriveo', 1, {
        upgrade(database) {
          const cs = database.createObjectStore('conversations', { keyPath: 'id' });
          cs.createIndex('by-updated', 'updatedAt');
        },
      });
      await db.put('conversations', { id: 'c1', title: 'test', updatedAt: new Date().toISOString(), messages: [] });
      db.close();

      await expect(migrateToPartitionedStorage()).resolves.not.toThrow();
      expect(localStorage.getItem(MIGRATED_KEY)).toBe('true');
    });
  });
});
