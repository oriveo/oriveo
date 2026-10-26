import 'fake-indexeddb/auto';
import { openDB } from 'idb';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DB_VERSION, getAllConversations, putConversation, resetDBConnection } from '../idb';
import { getDBName, setActiveUID } from '../partition';
import { resetImageDBConnection } from '../image-store';
import { IDB_STALE_SCHEMA_RELOAD_KEY, setStaleSchemaHostForTests } from '../idb-lifecycle';
import type { Conversation } from '@oriveo/shared';

// After a newer bundle in another tab upgrades the database, an old-bundle tab can only reopen at its old version: VersionError.

function makeConversation(id: string): Conversation {
  return {
    id,
    title: 'Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    providerKind: 'openAI',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
  };
}

async function clearAllDatabases() {
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

/** A newer bundle in another tab upgrades the partition database (this tab's blocking makes way). */
async function upgradeFromNewerBundle() {
  const newer = await openDB(getDBName('guest'), DB_VERSION + 1);
  newer.close();
}

function settledWithin<T>(promise: Promise<T>, ms: number): Promise<'pending' | { value?: T; error?: unknown }> {
  return Promise.race([
    promise.then((value) => ({ value }), (error) => ({ error })),
    new Promise<'pending'>((resolve) => setTimeout(() => resolve('pending'), ms)),
  ]);
}

describe('a stale bundle opening an upgraded partition database', () => {
  let storage: Map<string, string>;
  let reload: ReturnType<typeof vi.fn<() => void>>;

  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
    storage = new Map();
    reload = vi.fn<() => void>();
    setStaleSchemaHostForTests(() => ({
      storage: {
        getItem: (key) => storage.get(key) ?? null,
        setItem: (key, value) => { storage.set(key, value); return true; },
      },
      reload,
    }));
  });

  afterEach(() => {
    setStaleSchemaHostForTests(null);
  });

  it('reloads onto the new bundle the first time in a session, leaving the read pending instead of throwing VersionError', async () => {
    await putConversation(makeConversation('c1'));
    await upgradeFromNewerBundle();

    const outcome = await settledWithin(getAllConversations(), 50);

    expect(outcome).toBe('pending');
    expect(reload).toHaveBeenCalledTimes(1);
    expect(storage.get(IDB_STALE_SCHEMA_RELOAD_KEY)).toBe('1');
  });

  it('throws VersionError as usual once the session has already reloaded, and does not cache the failure', async () => {
    await putConversation(makeConversation('c1'));
    await upgradeFromNewerBundle();
    storage.set(IDB_STALE_SCHEMA_RELOAD_KEY, '1');

    await expect(getAllConversations()).rejects.toMatchObject({ name: 'VersionError' });
    expect(reload).not.toHaveBeenCalled();

    // Once the database is openable by this bundle again, the next read reopens it instead of reusing the rejected promise.
    await clearAllDatabases();
    await setActiveUID('guest');
    await expect(getAllConversations()).resolves.toEqual([]);
    // The gate is set-only: another database opening successfully must not clear it, or a repeat after reload would loop.
    expect(storage.get(IDB_STALE_SCHEMA_RELOAD_KEY)).toBe('1');
    expect(reload).not.toHaveBeenCalled();
  });
});
