import 'fake-indexeddb/auto';

import { beforeEach, describe, expect, it } from 'vitest';
import { openDB } from 'idb';
import type { Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../../../core/store/app-store';
import { hydrateStore } from '../../../core/store/persistence';
import {
  getActiveUID,
  getDBName,
  hasPartitionData,
  setActiveUID,
} from '../partition';
import { resetDBConnection } from '../idb';
import { resetImageDBConnection } from '../image-store';

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'C1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'P1',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'P1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••••test',
    ...overrides,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

async function seedPartition(uid: string, data: { providers?: Provider[]; conversations?: Conversation[] }) {
  const dbName = getDBName(uid);
  const db = await openDB(dbName, 1, {
    upgrade(database) {
      if (!database.objectStoreNames.contains('conversations')) {
        const cs = database.createObjectStore('conversations', { keyPath: 'id' });
        cs.createIndex('by-updated', 'updatedAt');
      }
      if (!database.objectStoreNames.contains('providers')) {
        database.createObjectStore('providers', { keyPath: 'id' });
      }
      if (!database.objectStoreNames.contains('session')) {
        database.createObjectStore('session');
      }
      if (!database.objectStoreNames.contains('folders')) {
        const fs = database.createObjectStore('folders', { keyPath: 'id' });
        fs.createIndex('by-sortOrder', 'sortOrder');
      }
    },
  });
  for (const provider of data.providers ?? []) await db.put('providers', provider);
  for (const conversation of data.conversations ?? []) await db.put('conversations', conversation);
  db.close();
}

describe('partition switching logic', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('hydrates guest data when guest partition is active', async () => {
    await seedPartition('guest', {
      providers: [makeProvider({ id: 'GP1' })],
      conversations: [makeConversation({ id: 'GC1', providerID: 'GP1' })],
    });

    const store = createAppStore();
    await hydrateStore(store);

    expect(await getActiveUID()).toBe('guest');
    expect(store.getState().providers.map((provider) => provider.id)).toEqual(['GP1']);
    expect(store.getState().conversations.map((conversation) => conversation.id)).toEqual(['GC1']);
  });

  it('guest and authenticated partitions stay isolated', async () => {
    await seedPartition('guest', {
      providers: [makeProvider({ id: 'GP1' })],
      conversations: [makeConversation({ id: 'GC1', providerID: 'GP1' })],
    });
    await seedPartition('user-A', {
      providers: [makeProvider({ id: 'UP1' })],
      conversations: [makeConversation({ id: 'UC1', providerID: 'UP1' })],
    });

    expect(await hasPartitionData('guest')).toBe(true);
    expect(await hasPartitionData('user-A')).toBe(true);

    const guestStore = createAppStore();
    await hydrateStore(guestStore);
    expect(guestStore.getState().conversations.map((conversation) => conversation.id)).toEqual(['GC1']);

    await setActiveUID('user-A');
    resetDBConnection();

    const userStore = createAppStore();
    await hydrateStore(userStore);
    expect(await getActiveUID()).toBe('user-A');
    expect(userStore.getState().conversations.map((conversation) => conversation.id)).toEqual(['UC1']);
    expect(userStore.getState().providers.map((provider) => provider.id)).toEqual(['UP1']);
  });
});
