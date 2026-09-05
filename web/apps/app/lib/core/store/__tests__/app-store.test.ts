import { describe, it, expect, beforeEach } from 'vitest';
import { createAppStore, type AppStore } from '../app-store';
import type { Provider, Conversation } from '@oriveo/shared';
import type { StoreApi } from 'zustand';

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

describe('AppStore', () => {
  let store: StoreApi<AppStore>;

  beforeEach(() => {
    store = createAppStore();
  });

  describe('Providers', () => {
    it('should add a provider', () => {
      const provider = makeProvider();
      store.getState().addProvider(provider);
      expect(store.getState().providers).toHaveLength(1);
      expect(store.getState().providers[0].id).toBe('p1');
    });

    it('should update a provider', () => {
      store.getState().addProvider(makeProvider());
      store.getState().updateProvider('p1', { apiKey: 'sk-new' });
      expect(store.getState().providers[0].apiKey).toBe('sk-new');
    });

    it('should remove a provider', () => {
      store.getState().addProvider(makeProvider());
      store.getState().removeProvider('p1');
      expect(store.getState().providers).toHaveLength(0);
    });

    it('should set all providers', () => {
      store.getState().setProviders([makeProvider(), makeProvider({ id: 'p2' })]);
      expect(store.getState().providers).toHaveLength(2);
    });

    it('should upsert by id when adding existing provider', () => {
      store.getState().addProvider(makeProvider({ apiKey: 'sk-old' }));
      store.getState().addProvider(makeProvider({ apiKey: 'sk-new' }));
      expect(store.getState().providers).toHaveLength(1);
      expect(store.getState().providers[0].apiKey).toBe('sk-new');
    });

    it('should keep multiple relays as independent instances', () => {
      store.getState().addProvider(makeProvider({ id: 'r1', kind: 'relay', customName: 'Relay A' }));
      store.getState().addProvider(makeProvider({ id: 'r2', kind: 'relay', customName: 'Relay B' }));
      const ids = store.getState().providers.map((p) => p.id).sort();
      expect(ids).toEqual(['r1', 'r2']);
    });
  });

  describe('Conversations', () => {
    it('should add a conversation', () => {
      store.getState().addConversation(makeConversation());
      expect(store.getState().conversations).toHaveLength(1);
    });

    it('should update a conversation', () => {
      store.getState().addConversation(makeConversation());
      store.getState().updateConversation('c1', { title: 'Updated' });
      expect(store.getState().conversations[0].title).toBe('Updated');
    });

    it('should remove a conversation', () => {
      store.getState().addConversation(makeConversation());
      store.getState().removeConversation('c1');
      expect(store.getState().conversations).toHaveLength(0);
    });

    it('should remove multiple conversations', () => {
      store.getState().addConversation(makeConversation({ id: 'c1' }));
      store.getState().addConversation(makeConversation({ id: 'c2' }));
      store.getState().addConversation(makeConversation({ id: 'c3' }));
      store.getState().removeConversations(['c1', 'c3']);
      expect(store.getState().conversations).toHaveLength(1);
      expect(store.getState().conversations[0].id).toBe('c2');
    });
  });

  describe('UI State', () => {
    it('should toggle sidebar', () => {
      expect(store.getState().sidebarOpen).toBe(true);
      store.getState().setSidebarOpen(false);
      expect(store.getState().sidebarOpen).toBe(false);
    });

    it('should set active conversation', () => {
      store.getState().setActiveConversationId('c1');
      expect(store.getState().activeConversationId).toBe('c1');
    });

  });

  describe('Streaming (per-conversation dictionaries)', () => {
    it('beginStreamingForConversation: registering a stream keeps the dictionaries + ids array in sync', () => {
      store.getState().beginStreamingForConversation('c1', 'm1');
      expect(store.getState().streamingTexts.c1).toBe('');
      expect(store.getState().streamingMessageIds.c1).toBe('m1');
      expect(store.getState().streamingConversationIds).toContain('c1');
    });

    it('setStreamingText: only updates the partial of the given conversation', () => {
      store.getState().beginStreamingForConversation('c1', 'm1');
      store.getState().beginStreamingForConversation('c2', 'm2');
      store.getState().setStreamingText('c1', 'Hello');
      expect(store.getState().streamingTexts.c1).toBe('Hello');
      expect(store.getState().streamingTexts.c2).toBe('');
    });

    it('appendStreamingText: accumulates each conversation partial separately', () => {
      store.getState().beginStreamingForConversation('c1', 'm1');
      store.getState().beginStreamingForConversation('c2', 'm2');
      store.getState().appendStreamingText('c1', 'Hello');
      store.getState().appendStreamingText('c1', ' world');
      store.getState().appendStreamingText('c2', 'Other');
      expect(store.getState().streamingTexts.c1).toBe('Hello world');
      expect(store.getState().streamingTexts.c2).toBe('Other');
    });

    it('clearStreamingForConversation: removes that conversation from the dictionaries + ids', () => {
      store.getState().beginStreamingForConversation('c1', 'm1');
      store.getState().beginStreamingForConversation('c2', 'm2');
      store.getState().clearStreamingForConversation('c1');
      expect(store.getState().streamingTexts.c1).toBeUndefined();
      expect(store.getState().streamingMessageIds.c1).toBeUndefined();
      expect(store.getState().streamingConversationIds).not.toContain('c1');
      expect(store.getState().streamingConversationIds).toContain('c2');
    });

    it('streamingConversationIds keeps a stable reference: append does not change the ids reference', () => {
      store.getState().beginStreamingForConversation('c1', 'm1');
      const idsBefore = store.getState().streamingConversationIds;
      store.getState().appendStreamingText('c1', 'a');
      store.getState().appendStreamingText('c1', 'b');
      const idsAfter = store.getState().streamingConversationIds;
      expect(idsAfter).toBe(idsBefore);
    });
  });

  describe('Search', () => {
    it('should set search query and reset index', () => {
      store.getState().setSearchMatchIndex(5);
      store.getState().setSearchQuery('hello');
      expect(store.getState().searchQuery).toBe('hello');
      expect(store.getState().searchMatchIndex).toBe(0);
    });
  });

  describe('Pin & Order', () => {
    it('should toggle pin conversation', () => {
      expect(store.getState().togglePinConversation('c1')).toBe(true);
      expect(store.getState().pinnedConversationIds).toContain('c1');
      expect(store.getState().togglePinConversation('c1')).toBe(true);
      expect(store.getState().pinnedConversationIds).not.toContain('c1');
    });

    it('should reject a third free pinned conversation when a limit is provided', () => {
      expect(store.getState().togglePinConversation('c1', 2)).toBe(true);
      expect(store.getState().togglePinConversation('c2', 2)).toBe(true);
      expect(store.getState().togglePinConversation('c3', 2)).toBe(false);
      expect(store.getState().pinnedConversationIds).toEqual(['c1', 'c2']);
    });

    it('should set conversation order', () => {
      store.getState().setConversationOrder(['c2', 'c1']);
      expect(store.getState().conversationOrder).toEqual(['c2', 'c1']);
    });

    it('should clean up pins when removing conversations', () => {
      store.getState().togglePinConversation('c1');
      store.getState().addConversation(makeConversation({ id: 'c1' }));
      store.getState().removeConversations(['c1']);
      expect(store.getState().pinnedConversationIds).not.toContain('c1');
    });
  });

  describe('Preferences', () => {
    it('should update preferences partially', () => {
      store.getState().setPreferences({ theme: 'dark' });
      expect(store.getState().preferences.theme).toBe('dark');
      expect(store.getState().preferences.language).toBe('system');
    });
  });

  describe('Image Generation', () => {
    it('should set image gen mode', () => {
      store.getState().setImageGenMode(true);
      expect(store.getState().imageGenMode).toBe(true);
    });
  });

  describe('Memory', () => {
    it('setConversationUseMemory - sets the per-conversation Memory switch', () => {
      store.getState().addConversation(makeConversation({ id: 'c1' }));
      store.getState().setConversationUseMemory('c1', false);

      const conv = store.getState().conversations.find((c) => c.id === 'c1');
      expect(conv?.useMemory).toBe(false);
    });

    it('setConversationUseMemory - turning it back on', () => {
      store.getState().addConversation(makeConversation({ id: 'c1' }));
      store.getState().setConversationUseMemory('c1', false);
      store.getState().setConversationUseMemory('c1', true);

      const conv = store.getState().conversations.find((c) => c.id === 'c1');
      expect(conv?.useMemory).toBe(true);
    });

    it('setConversationUseMemory - does not affect other conversations', () => {
      store.getState().addConversation(makeConversation({ id: 'c1' }));
      store.getState().addConversation(makeConversation({ id: 'c2' }));
      store.getState().setConversationUseMemory('c1', false);

      const c2 = store.getState().conversations.find((c) => c.id === 'c2');
      expect(c2?.useMemory).toBeUndefined();
    });

    it('incrementMemoryUsageCount - increments the counter', () => {
      expect(store.getState().memoryUsageCount).toBe(0);
      store.getState().incrementMemoryUsageCount();
      store.getState().incrementMemoryUsageCount();
      expect(store.getState().memoryUsageCount).toBe(2);
    });
  });
});
