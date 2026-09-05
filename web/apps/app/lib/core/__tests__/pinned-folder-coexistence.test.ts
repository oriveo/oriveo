import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createAppStore, type AppStore } from '../store/app-store';
import { groupConversations } from '../../utils/conversation-grouping';
import type { Conversation, Folder } from '@oriveo/shared';
import type { StoreApi } from 'zustand';

// Mock sync module
vi.mock('../sync-port', () => ({
  getSyncAdapter: () => null,
}));

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
    messages: [{ id: 'msg1', role: 'user', text: 'Hi', state: 'delivered' }],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeFolder(overrides: Partial<Folder> = {}): Folder {
  return {
    id: 'f1',
    name: 'Work',
    sortOrder: 1000,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

describe('pinned conversations coexisting with folders', () => {
  let store: StoreApi<AppStore>;

  beforeEach(() => {
    store = createAppStore();
  });

  describe('a conversation shows in both the pinned list and its folder', () => {
    it('conversation can be both pinned and in a folder', () => {
      const conv = makeConversation({ id: 'c1', folderID: 'f1' });
      store.getState().addConversation(conv);
      store.getState().setFolders([makeFolder({ id: 'f1' })]);
      store.getState().togglePinConversation('c1');

      const state = store.getState();

      // Should appear in the pinned list
      expect(state.pinnedConversationIds).toContain('c1');

      // folderID should be preserved
      const storedConv = state.conversations.find((c) => c.id === 'c1');
      expect(storedConv?.folderID).toBe('f1');
    });
  });

  describe('time groups exclude pinned conversations and conversations in folders', () => {
    it('pinned conversation should not appear in time groups', () => {
      const conversations = [
        makeConversation({ id: 'pinned-conv', updatedAt: new Date().toISOString() }),
        makeConversation({ id: 'normal-conv', updatedAt: new Date().toISOString() }),
      ];

      store.getState().addConversation(conversations[0]);
      store.getState().addConversation(conversations[1]);
      store.getState().togglePinConversation('pinned-conv');

      const state = store.getState();
      const pinnedIds = new Set(state.pinnedConversationIds);
      const unpinned = state.conversations.filter(
        (c) => !pinnedIds.has(c.id) && !c.folderID,
      );
      const groups = groupConversations(unpinned);

      const allGroupItems = groups.flatMap((g) => g.items);
      expect(allGroupItems.find((c) => c.id === 'pinned-conv')).toBeUndefined();
      expect(allGroupItems.find((c) => c.id === 'normal-conv')).toBeDefined();
    });

    it('folder conversation should not appear in time groups', () => {
      const conversations = [
        makeConversation({
          id: 'folder-conv',
          folderID: 'f1',
          updatedAt: new Date().toISOString(),
        }),
        makeConversation({
          id: 'normal-conv',
          updatedAt: new Date().toISOString(),
        }),
      ];

      // groupConversations filters folderID internally
      const groups = groupConversations(conversations);
      const allGroupItems = groups.flatMap((g) => g.items);

      expect(allGroupItems.find((c) => c.id === 'folder-conv')).toBeUndefined();
      expect(allGroupItems.find((c) => c.id === 'normal-conv')).toBeDefined();
    });
  });

  describe('list section order', () => {
    it('order should be: Pinned → Folders → Time Groups', () => {
      const pinnedConv = makeConversation({
        id: 'pinned',
        updatedAt: new Date().toISOString(),
      });
      const folderConv = makeConversation({
        id: 'in-folder',
        folderID: 'f1',
        updatedAt: new Date().toISOString(),
      });
      const normalConv = makeConversation({
        id: 'normal',
        updatedAt: new Date().toISOString(),
      });

      store.getState().addConversation(pinnedConv);
      store.getState().addConversation(folderConv);
      store.getState().addConversation(normalConv);
      store.getState().setFolders([makeFolder({ id: 'f1' })]);
      store.getState().togglePinConversation('pinned');

      const state = store.getState();
      const pinnedIds = new Set(state.pinnedConversationIds);

      // Build the sections in order
      const sections: string[] = [];

      // 1. Pinned
      const pinned = state.conversations.filter((c) => pinnedIds.has(c.id));
      if (pinned.length > 0) sections.push('pinned');

      // 2. Folders
      if (state.folders.length > 0) sections.push('folders');

      // 3. Time groups
      const ungrouped = state.conversations.filter(
        (c) => !pinnedIds.has(c.id) && !c.folderID,
      );
      const groups = groupConversations(ungrouped);
      if (groups.length > 0) sections.push('timeGroups');

      expect(sections).toEqual(['pinned', 'folders', 'timeGroups']);
    });
  });

  describe('unpinning does not affect the folder', () => {
    it('unpinning should not remove from folder', () => {
      const conv = makeConversation({ id: 'c1', folderID: 'f1' });
      store.getState().addConversation(conv);
      store.getState().togglePinConversation('c1'); // pin

      // Confirm it is pinned and in a folder
      expect(store.getState().pinnedConversationIds).toContain('c1');
      expect(
        store.getState().conversations.find((c) => c.id === 'c1')?.folderID,
      ).toBe('f1');

      // Unpin
      store.getState().togglePinConversation('c1');

      // Unpinned
      expect(store.getState().pinnedConversationIds).not.toContain('c1');
      // Still in the folder
      expect(
        store.getState().conversations.find((c) => c.id === 'c1')?.folderID,
      ).toBe('f1');
    });
  });

  describe('removing from a folder does not affect the pin', () => {
    it('removing from folder should not affect pin status', () => {
      const conv = makeConversation({ id: 'c1', folderID: 'f1' });
      store.getState().addConversation(conv);
      store.getState().togglePinConversation('c1'); // pin

      // Confirm the initial state
      expect(store.getState().pinnedConversationIds).toContain('c1');
      expect(
        store.getState().conversations.find((c) => c.id === 'c1')?.folderID,
      ).toBe('f1');

      // Remove from the folder
      store.getState().updateConversation('c1', { folderID: undefined });

      // Still pinned
      expect(store.getState().pinnedConversationIds).toContain('c1');
      // Out of the folder
      const updatedConv = store
        .getState()
        .conversations.find((c) => c.id === 'c1');
      expect(updatedConv?.folderID).toBeUndefined();
    });
  });
});
