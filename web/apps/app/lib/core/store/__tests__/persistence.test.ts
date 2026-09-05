import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi, afterEach } from 'vitest';
import { createAppStore } from '../app-store';
import { hydrateStore, subscribeToChanges } from '../persistence';
import {
  putConversation,
  putProvider,
  getAllConversations,
  getConversationById,
  getAllProviders,
  resetDBConnection,
} from '../../../infra/storage/idb';
import { resetImageDBConnection } from '../../../infra/storage/image-store';
import { setActiveUID, getDBName } from '../../../infra/storage/partition';
import { openDB } from 'idb';
import type { Conversation, Provider } from '@oriveo/shared';
import type { ChatMessage } from '@oriveo/shared';
import { readCapabilityEvidenceIdentity } from '../../providers/capability-evidence-identity';

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'p1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••••test',
    ...overrides,
  };
}

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: 'msg1',
    role: 'assistant',
    content: 'Hello',
    state: 'done',
    ...overrides,
  } as ChatMessage;
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
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

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

/** Write data straight into a given partition. */
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
  for (const p of data.providers ?? []) await db.put('providers', p);
  for (const c of data.conversations ?? []) await db.put('conversations', c);
  db.close();
}

describe('persistence.ts', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
    localStorage.clear();
  });

  // -- hydrateStore --

  describe('hydrateStore', () => {
    it('should load providers and conversations from IDB', async () => {
      await seedPartition('guest', {
        providers: [makeProvider({ id: 'p1' }), makeProvider({ id: 'p2', kind: 'anthropic' })],
        conversations: [
          makeConversation({ id: 'c1', title: 'Chat 1' }),
          makeConversation({ id: 'c2', title: 'Chat 2' }),
        ],
      });

      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().providers).toHaveLength(2);
      expect(store.getState().conversations).toHaveLength(2);
    });

    it('generates the local opaque identity once when hydrating an existing provider, partitioned by uid', async () => {
      await seedPartition('guest', { providers: [makeProvider({ id: 'legacy-relay' })] });
      const guestStore = createAppStore();

      await hydrateStore(guestStore, 'guest');
      const first = readCapabilityEvidenceIdentity('guest', 'legacy-relay');
      await hydrateStore(guestStore, 'guest');
      const second = readCapabilityEvidenceIdentity('guest', 'legacy-relay');

      expect(first).not.toBeNull();
      expect(second).toEqual(first);
      expect(guestStore.getState().providers[0]).not.toHaveProperty('connectionGeneration');
      expect(guestStore.getState().providers[0]).not.toHaveProperty('credentialEpoch');
      expect(localStorage.getItem('oriveo.capability-evidence-identity.v1')).not.toContain('sk-test');

      await setActiveUID('user-b');
      await seedPartition('user-b', { providers: [makeProvider({ id: 'legacy-relay' })] });
      const userStore = createAppStore();
      await hydrateStore(userStore, 'user-b');
      const otherPartition = readCapabilityEvidenceIdentity('user-b', 'legacy-relay');

      expect(otherPartition?.connectionGeneration).not.toBe(first?.connectionGeneration);
      expect(otherPartition?.credentialEpoch).not.toBe(first?.credentialEpoch);
    });

    it('should hydrate conversations in updatedAt descending order', async () => {
      await seedPartition('guest', {
        conversations: [
          makeConversation({ id: 'older', updatedAt: '2026-03-29T09:00:00.000Z' }),
          makeConversation({ id: 'newer', updatedAt: '2026-03-29T11:00:00.000Z' }),
        ],
      });

      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().conversations.map((conversation) => conversation.id)).toEqual([
        'newer',
        'older',
      ]);
    });

    it('should mark onboarding complete when recovered data exists', async () => {
      await seedPartition('guest', {
        providers: [makeProvider({ id: 'p1' })],
      });

      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().hasCompletedOnboarding).toBe(true);
      // Preferences are partitioned by activeUID; the guest partition key is oriveo.guest.{key}.
      expect(localStorage.getItem('oriveo.guest.hasCompletedOnboarding')).toBe('true');
    });

    it('should keep default values when IDB is empty', async () => {
      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().providers).toHaveLength(0);
      expect(store.getState().conversations).toHaveLength(0);
    });

    it('should hydrate conversations as summaries and preserve remote message count', async () => {
      const stuckConv = makeConversation({
        id: 'c1',
        messages: [
          makeMessage({ id: 'msg1', state: 'done' }),
          makeMessage({ id: 'msg2', state: 'generating' }),
        ],
      });

      await seedPartition('guest', { conversations: [stuckConv] });

      const store = createAppStore();
      await hydrateStore(store);

      const conv = store.getState().conversations[0];
      expect(conv.messages).toEqual([]);
      expect(conv.remoteMessageCount).toBe(2);
    });

    it('backfills conversation.providerKind from the last assistant message for older data', async () => {
      // Older data: the conversation has no providerKind field, but the messages do.
      const legacyConv: Conversation = {
        ...makeConversation({ id: 'legacy-1' }),
        providerKind: undefined,
        messages: [
          {
            id: 'u1', role: 'user', text: 'hi',
            providerKind: 'openAI', providerName: 'OpenAI',
            modelName: 'gpt-4', estimatedCost: 0, state: 'delivered',
          },
          {
            id: 'a1', role: 'assistant', text: 'hello',
            providerKind: 'anthropic', providerName: 'Anthropic',
            modelName: 'claude-3', estimatedCost: 0, state: 'delivered',
          },
        ] as ChatMessage[],
      };

      await seedPartition('guest', { conversations: [legacyConv] });

      const store = createAppStore();
      await hydrateStore(store);

      const conv = store.getState().conversations.find((c) => c.id === 'legacy-1');
      expect(conv?.messages).toEqual([]);
      // The fallback reads providerKind from the last assistant message, so the list icon does not depend on providers.find().
      expect(conv?.providerKind).toBe('anthropic');
    });

    it('keeps an existing conversation.providerKind when converting to a summary', async () => {
      const newConv: Conversation = {
        ...makeConversation({ id: 'new-1' }),
        providerKind: 'gemini',
        messages: [
          {
            id: 'a1', role: 'assistant', text: 'hi',
            providerKind: 'openAI', providerName: 'OpenAI',
            modelName: 'gpt-4', estimatedCost: 0, state: 'delivered',
          },
        ] as ChatMessage[],
      };

      await seedPartition('guest', { conversations: [newConv] });

      const store = createAppStore();
      await hydrateStore(store);

      const conv = store.getState().conversations.find((c) => c.id === 'new-1');
      // An existing conversation.providerKind is not overwritten by the message fallback.
      expect(conv?.providerKind).toBe('gemini');
    });

    it('should recover persisted provider syncing state as connected', async () => {
      await seedPartition('guest', {
        providers: [
          makeProvider({
            id: 'p-syncing',
            status: { kind: 'syncing' },
            models: [{ id: 'gpt-4.1', name: 'GPT-4.1', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' }],
          }),
        ],
      });

      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().providers[0].status).toEqual({ kind: 'connected' });
    });

    it('should hydrate from the correct partition', async () => {
      await seedPartition('guest', {
        providers: [makeProvider({ id: 'guest-p' })],
      });
      await seedPartition('user-A', {
        providers: [makeProvider({ id: 'userA-p' })],
      });

      // Hydrate from guest partition
      const store1 = createAppStore();
      await hydrateStore(store1);
      expect(store1.getState().providers[0].id).toBe('guest-p');

      // Switch to user-A and hydrate
      resetDBConnection();
      await setActiveUID('user-A');
      const store2 = createAppStore();
      await hydrateStore(store2);
      expect(store2.getState().providers[0].id).toBe('userA-p');
    });
  });

  // -- subscribeToChanges --

  describe('subscribeToChanges', () => {
    it('should persist added provider to IDB', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().addProvider(makeProvider({ id: 'new-p1' }));

      // Wait for sync
      await new Promise((r) => setTimeout(r, 50));

      const idbProviders = await getAllProviders();
      expect(idbProviders.find((p) => p.id === 'new-p1')).toBeDefined();

      unsub();
    });

    it('should remove deleted provider from IDB', async () => {
      await seedPartition('guest', { providers: [makeProvider({ id: 'p1' })] });

      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().removeProvider('p1');

      await new Promise((r) => setTimeout(r, 50));

      const idbProviders = await getAllProviders();
      expect(idbProviders.find((p) => p.id === 'p1')).toBeUndefined();

      unsub();
    });

    it('should persist conversation after debounce', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().addConversation(makeConversation({ id: 'new-c1' }));

      // Wait for 500ms debounce + buffer
      await new Promise((r) => setTimeout(r, 600));

      const idbConvs = await getAllConversations();
      expect(idbConvs.find((c) => c.id === 'new-c1')).toBeDefined();

      unsub();
    });

    it('should not overwrite full IDB messages when a hydrated summary receives metadata updates', async () => {
      const fullConversation = makeConversation({
        id: 'c1',
        messages: [
          makeMessage({ id: 'u1', role: 'user', text: 'hi', state: 'delivered' }),
          makeMessage({ id: 'a1', role: 'assistant', text: 'hello', state: 'delivered' }),
        ],
      });
      await seedPartition('guest', { conversations: [fullConversation] });

      const store = createAppStore();
      await hydrateStore(store);
      expect(store.getState().conversations[0].messages).toEqual([]);
      expect(store.getState().conversations[0].remoteMessageCount).toBe(2);

      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().updateConversation('c1', { folderID: 'folder-1' });
      await new Promise((r) => setTimeout(r, 600));

      const persisted = await getConversationById('c1');
      expect(persisted?.folderID).toBe('folder-1');
      expect(persisted?.messages.map((message) => message.id)).toEqual(['u1', 'a1']);

      unsub();
    });

    it('should remove deleted conversation from IDB immediately', async () => {
      await seedPartition('guest', {
        conversations: [makeConversation({ id: 'c1' })],
      });

      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().removeConversation('c1');

      await new Promise((r) => setTimeout(r, 50));

      const idbConvs = await getAllConversations();
      expect(idbConvs.find((c) => c.id === 'c1')).toBeUndefined();

      unsub();
    });

    it('should unsubscribe correctly', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);
      unsub();

      store.getState().addProvider(makeProvider({ id: 'after-unsub' }));
      await new Promise((r) => setTimeout(r, 50));

      const idbProviders = await getAllProviders();
      expect(idbProviders.find((p) => p.id === 'after-unsub')).toBeUndefined();
    });

    // Regression: a partition switch calls setState({ providers: [], hydrationPhase: 'booting' })
    // and then hydrateStore. Without a gate in the subscriber, the fire-and-forget deleteProvider
    // it triggers races the async partition switch and can delete IDB data belonging to the old
    // partition.
    it('clearing providers before hydration is ready does not trigger IDB deletes', async () => {
      await seedPartition('guest', {
        providers: [
          makeProvider({ id: 'p1' }),
          makeProvider({ id: 'p2', kind: 'anthropic' }),
        ],
      });

      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      // Simulate a partition reset: clear providers and set hydrationPhase back to booting atomically.
      store.setState({ providers: [], hydrationPhase: 'booting' });
      await new Promise((r) => setTimeout(r, 50));

      // The providers in IDB should be untouched, not deleted by the subscriber.
      const idbProviders = await getAllProviders();
      expect(idbProviders.map((p) => p.id).sort()).toEqual(['p1', 'p2']);

      unsub();
    });

    // Regression: on entering ready, prev is already synced to the current state, so differences
    // accumulated during hydration are not written back in bulk.
    it('state changes accumulated during hydration are not flushed on entering ready', async () => {
      await seedPartition('guest', { providers: [makeProvider({ id: 'p1' })] });

      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      // Simulate several setState calls during a partition reset: clear, then hydrate back in.
      store.setState({ providers: [], hydrationPhase: 'booting' });
      store.setState({ providers: [makeProvider({ id: 'p1' })] }); // hydration finished
      await new Promise((r) => setTimeout(r, 30));

      // hydrationPhase is still booting, so IDB should show no writes at all.
      const idbBeforeReady = await getAllProviders();
      expect(idbBeforeReady.map((p) => p.id).sort()).toEqual(['p1']);

      // Entering ready: prev is already synced, so no IDB write, delete or add, should happen.
      store.setState({ hydrationPhase: 'ready' });
      await new Promise((r) => setTimeout(r, 30));

      const idbAfterReady = await getAllProviders();
      expect(idbAfterReady.map((p) => p.id).sort()).toEqual(['p1']);

      unsub();
    });
  });
});
