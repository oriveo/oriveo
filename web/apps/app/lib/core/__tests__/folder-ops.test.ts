import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createAppStore } from '../store/app-store';
import type { Folder, Conversation, Provider } from '@oriveo/shared';
import {
  createFolder,
  renameFolder,
  deleteFolder,
  reorderFolders,
  moveConversationToFolder,
  batchMoveToFolder,
  createConversationInFolder,
  handleFolderReorder,
  updateFolderColor,
  assignFolderColors,
} from '../folder-ops';
import * as syncModule from '../sync-port';
import { groupConversations } from '../../utils/conversation-grouping';

// Mock sync adapter
vi.mock('../sync-port', () => ({
  getSyncAdapter: () => null,
}));

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: crypto.randomUUID(),
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    providerKind: 'openAI',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

/** createConversationInFolder needs at least one active provider in the store to resolve the default kind/model. */
function seedDefaultProvider(store: ReturnType<typeof createAppStore>): void {
  const provider: Provider = {
    id: 'p1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [{
      id: 'm1', name: 'GPT-4', capabilities: ['text'], reasoningModeAvailable: false,
      isAvailable: true, isDefault: true, priceTier: 'standard',
    }],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
  };
  store.getState().addProvider(provider);
}

describe('folder-ops', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    seedDefaultProvider(store);
  });

  // ── createFolder ────────────────────────────────────────

  describe('createFolder', () => {
    it('should create a folder with correct defaults', () => {
      const folder = createFolder(store, '  Work Projects  ');
      const state = store.getState();
      expect(state.folders).toHaveLength(1);
      expect(state.folders[0].name).toBe('Work Projects');
      expect(state.folders[0].sortOrder).toBe(1000);
      expect(state.folders[0].id).toBe(folder!.id);
    });

    it('should truncate name to 30 characters', () => {
      const folder = createFolder(store, 'A'.repeat(50));
      expect(folder!.name).toHaveLength(30);
    });

    it('should increment sortOrder for subsequent folders', () => {
      createFolder(store, 'Folder 1');
      createFolder(store, 'Folder 2');
      createFolder(store, 'Folder 3');
      const state = store.getState();
      expect(state.folders).toHaveLength(3);
      expect(state.folders[0].sortOrder).toBe(1000);
      expect(state.folders[1].sortOrder).toBe(2000);
      expect(state.folders[2].sortOrder).toBe(3000);
    });

    it('TC-1.1.4: should generate unique IDs for 10 folders', () => {
      const ids = Array.from({ length: 10 }, (_, i) => createFolder(store, `Folder ${i}`)!.id);
      const unique = new Set(ids);
      expect(unique.size).toBe(10);
      ids.forEach((id) => expect(id).toMatch(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/));
    });
  });

  // ── renameFolder ────────────────────────────────────────

  describe('renameFolder', () => {
    it('should rename an existing folder', () => {
      const folder = createFolder(store, 'Old Name')!;
      renameFolder(store, folder.id, 'New Name');
      expect(store.getState().folders[0].name).toBe('New Name');
    });

    it('should not rename if name is empty', () => {
      const folder = createFolder(store, 'Keep Me')!;
      renameFolder(store, folder.id, '   ');
      expect(store.getState().folders[0].name).toBe('Keep Me');
    });

    it('should truncate to 30 characters', () => {
      const folder = createFolder(store, 'Short')!;
      renameFolder(store, folder.id, 'B'.repeat(40));
      expect(store.getState().folders[0].name).toHaveLength(30);
    });

    it('TC-1.1.5: should not change createdAt when renaming', () => {
      const folder = createFolder(store, 'Original')!;
      const originalCreatedAt = store.getState().folders[0].createdAt;
      renameFolder(store, folder.id, 'Renamed');
      expect(store.getState().folders[0].createdAt).toBe(originalCreatedAt);
    });

    it('TC-1.1.5: should update updatedAt when renaming', () => {
      const folder = createFolder(store, 'Original')!;
      const before = store.getState().folders[0].updatedAt;
      // Make sure the timestamp differs.
      vi.setSystemTime(new Date(Date.now() + 1000));
      renameFolder(store, folder.id, 'Renamed');
      vi.useRealTimers();
      expect(store.getState().folders[0].updatedAt).not.toBe(before);
    });

    it('TC-1.2.2: should allow renaming to an already-used name', () => {
      const f1 = createFolder(store, 'Same Name')!;
      const f2 = createFolder(store, 'Different')!;
      renameFolder(store, f2.id, 'Same Name');
      expect(store.getState().folders.find((f) => f.id === f2.id)?.name).toBe('Same Name');
      expect(store.getState().folders.find((f) => f.id === f1.id)?.name).toBe('Same Name');
    });

    it('TC-1.2.3: rename should not affect conversations inside the folder', () => {
      const folder = createFolder(store, 'Old Name')!;
      const convs = [
        makeConversation({ id: 'r1', folderID: folder.id, title: 'Chat 1' }),
        makeConversation({ id: 'r2', folderID: folder.id, title: 'Chat 2' }),
        makeConversation({ id: 'r3', folderID: folder.id, title: 'Chat 3' }),
      ];
      convs.forEach((c) => store.getState().addConversation(c));

      renameFolder(store, folder.id, 'New Name');

      const state = store.getState();
      expect(state.conversations).toHaveLength(3);
      state.conversations.forEach((c) => {
        expect(c.folderID).toBe(folder.id);
      });
    });

    it('TC-1.2.4: rename should not change sortOrder', () => {
      const folder = createFolder(store, 'Test')!;
      const originalSortOrder = store.getState().folders[0].sortOrder;
      renameFolder(store, folder.id, 'Renamed');
      expect(store.getState().folders[0].sortOrder).toBe(originalSortOrder);
    });
  });

  // ── deleteFolder ────────────────────────────────────────

  describe('deleteFolder', () => {
    it('should remove the folder', () => {
      const folder = createFolder(store, 'To Delete')!;
      expect(store.getState().folders).toHaveLength(1);
      deleteFolder(store, folder.id);
      expect(store.getState().folders).toHaveLength(0);
    });

    it('should cascade clear folderID from conversations', () => {
      const folder = createFolder(store, 'My Folder')!;
      const conv = makeConversation({ folderID: folder.id });
      store.getState().addConversation(conv);

      expect(store.getState().conversations[0].folderID).toBe(folder.id);

      deleteFolder(store, folder.id);
      expect(store.getState().conversations[0].folderID).toBeUndefined();
    });

    it('TC-1.3.3: conversations should retain all data after folder deletion', () => {
      const folder = createFolder(store, 'Data Folder')!;
      const conv = makeConversation({
        folderID: folder.id,
        title: 'Important Chat',
        estimatedCost: 1.5,
        previewText: 'Hello world',
      });
      store.getState().addConversation(conv);

      deleteFolder(store, folder.id);

      const remaining = store.getState().conversations[0];
      expect(remaining.title).toBe('Important Chat');
      expect(remaining.estimatedCost).toBe(1.5);
      expect(remaining.previewText).toBe('Hello world');
      expect(remaining.folderID).toBeUndefined();
    });

    // Metadata-only change, so it must not reorder conversations.
    it('TC-1.3.4: should NOT update updatedAt of affected conversations after deletion', () => {
      const folder = createFolder(store, 'Dated Folder')!;
      const oldTime = new Date(Date.now() - 60000).toISOString();
      const conv = makeConversation({ folderID: folder.id, updatedAt: oldTime });
      store.getState().addConversation(conv);

      deleteFolder(store, folder.id);

      expect(store.getState().conversations[0].updatedAt).toBe(oldTime);
    });

    it('TC-1.3.5: deleting non-existent folder should not crash', () => {
      expect(() => deleteFolder(store, 'non-existent-id')).not.toThrow();
      expect(store.getState().folders).toHaveLength(0);
      expect(store.getState().conversations).toHaveLength(0);
    });

    it('TC-1.3.6: should remove folder from expandedFolderIds after deletion', () => {
      const folder = createFolder(store, 'Expanded Folder')!;
      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      deleteFolder(store, folder.id);
      expect(store.getState().expandedFolderIds).not.toContain(folder.id);
    });

    it('TC-1.3.9: conversations should still exist after folder deletion', () => {
      const folder = createFolder(store, 'Temp Folder')!;
      const conv = makeConversation({ folderID: folder.id, title: 'Survive Chat' });
      store.getState().addConversation(conv);

      deleteFolder(store, folder.id);

      const convs = store.getState().conversations;
      expect(convs).toHaveLength(1);
      // normalizeConversationIDs uppercases UUIDs, so compare case-insensitively.
      expect(convs[0].id.toUpperCase()).toBe(conv.id.toUpperCase());
      expect(convs[0].title).toBe('Survive Chat');
      expect(convs[0].folderID).toBeUndefined();
    });
  });

  // ── moveConversationToFolder ────────────────────────────

  describe('moveConversationToFolder', () => {
    it('should set folderID on conversation', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation();
      store.getState().addConversation(conv);

      moveConversationToFolder(store, conv.id, folder.id);
      expect(store.getState().conversations[0].folderID).toBe(folder.id);
    });

    it('should advance local metadata LWW when moving conversation', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation({
        firestoreMetadataUpdatedAt: '2026-03-19T10:00:00.000Z',
      });
      store.getState().addConversation(conv);

      vi.setSystemTime(new Date('2026-03-19T10:05:00.000Z'));
      moveConversationToFolder(store, conv.id, folder.id);
      vi.useRealTimers();

      expect(store.getState().conversations[0].firestoreMetadataUpdatedAt)
        .toBe('2026-03-19T10:05:00.000Z');
    });

    it('should clear folderID when passing null', () => {
      const folder = createFolder(store, 'Source')!;
      const conv = makeConversation({ folderID: folder.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, conv.id, null);
      expect(store.getState().conversations[0].folderID).toBeUndefined();
    });
  });

  // ── batchMoveToFolder ───────────────────────────────────

  describe('batchMoveToFolder', () => {
    it('should move multiple conversations to a folder', () => {
      const folder = createFolder(store, 'Batch Target')!;
      const c1 = makeConversation({ id: 'c1' });
      const c2 = makeConversation({ id: 'c2' });
      const c3 = makeConversation({ id: 'c3' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      batchMoveToFolder(store, ['c1', 'c2'], folder.id);

      const convs = store.getState().conversations;
      expect(convs.find((c) => c.id === 'c1')?.folderID).toBe(folder.id);
      expect(convs.find((c) => c.id === 'c2')?.folderID).toBe(folder.id);
      expect(convs.find((c) => c.id === 'c3')?.folderID).toBeUndefined();
    });

    it('should advance local metadata LWW for each moved conversation', () => {
      const folder = createFolder(store, 'Batch Target')!;
      store.getState().addConversation(makeConversation({ id: 'c1' }));
      store.getState().addConversation(makeConversation({ id: 'c2' }));

      vi.setSystemTime(new Date('2026-03-19T10:06:00.000Z'));
      batchMoveToFolder(store, ['c1', 'c2'], folder.id);
      vi.useRealTimers();

      const convs = store.getState().conversations;
      expect(convs.find((c) => c.id === 'c1')?.firestoreMetadataUpdatedAt)
        .toBe('2026-03-19T10:06:00.000Z');
      expect(convs.find((c) => c.id === 'c2')?.firestoreMetadataUpdatedAt)
        .toBe('2026-03-19T10:06:00.000Z');
    });
  });

  // ── createConversationInFolder ──────────────────────────

  describe('createConversationInFolder', () => {
    it('should create a draft conversation with folderID set', () => {
      const folder = createFolder(store, 'New Chat Folder')!;
      createConversationInFolder(store, folder.id);

      const convs = store.getState().conversations;
      expect(convs).toHaveLength(1);
      expect(convs[0].folderID).toBe(folder.id);
      expect(convs[0].isDraft).toBe(true);
    });
  });

  // ── reorderFolders ──────────────────────────────────────

  describe('reorderFolders', () => {
    it('should replace the folders array', () => {
      const f1 = createFolder(store, 'A')!;
      const f2 = createFolder(store, 'B')!;
      const f3 = createFolder(store, 'C')!;

      const reordered: Folder[] = [
        { ...f3, sortOrder: 1000 },
        { ...f1, sortOrder: 2000 },
        { ...f2, sortOrder: 3000 },
      ];
      reorderFolders(store, reordered);

      const state = store.getState();
      expect(state.folders[0].id).toBe(f3.id);
      expect(state.folders[1].id).toBe(f1.id);
      expect(state.folders[2].id).toBe(f2.id);
    });
  });

  // ── store: toggleFolderExpand ───────────────────────────

  describe('toggleFolderExpand', () => {
    it('should toggle expand state', () => {
      const folder = createFolder(store, 'Toggle')!;

      expect(store.getState().expandedFolderIds).not.toContain(folder.id);

      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).not.toContain(folder.id);
    });
  });


  describe('name validation (TC-2.1)', () => {
    it('TC-2.1.1: trim leading/trailing spaces', () => {
      const folder = createFolder(store, '  Work  ');
      expect(folder?.name).toBe('Work');
    });

    it('TC-2.1.2: exactly 30 chars accepted', () => {
      const folder = createFolder(store, 'A'.repeat(30));
      expect(folder?.name).toHaveLength(30);
      expect(folder?.name).toBe('A'.repeat(30));
    });

    it('TC-2.1.3: truncate to 30 chars', () => {
      const folder = createFolder(store, 'A'.repeat(50));
      expect(folder?.name).toHaveLength(30);
    });

    it('TC-2.1.4: empty string rejected for create', () => {
      const folder = createFolder(store, '');
      expect(folder).toBeNull();
      expect(store.getState().folders).toHaveLength(0);
    });

    it('TC-2.1.4: empty string rejected for rename', () => {
      const folder = createFolder(store, 'Keep')!;
      renameFolder(store, folder.id, '');
      expect(store.getState().folders[0].name).toBe('Keep');
    });

    it('TC-2.1.5: whitespace-only rejected for create', () => {
      const folder = createFolder(store, '   ');
      expect(folder).toBeNull();
      expect(store.getState().folders).toHaveLength(0);
    });

    it('TC-2.1.5: whitespace-only rejected for rename', () => {
      const folder = createFolder(store, 'Keep')!;
      renameFolder(store, folder.id, '   ');
      expect(store.getState().folders[0].name).toBe('Keep');
    });

    it('TC-2.1.6: emoji accepted', () => {
      const folder = createFolder(store, '📚 がくしゅうノート');
      expect(folder).not.toBeNull();
      expect(folder?.name).toBe('📚 がくしゅうノート');
    });

    it('TC-2.1.7: pure emoji accepted', () => {
      const folder = createFolder(store, '🎉🎊🎈');
      expect(folder?.name).toBe('🎉🎊🎈');
    });

    it('TC-2.1.8: special chars accepted', () => {
      const folder = createFolder(store, 'Work/Projects #1');
      expect(folder?.name).toBe('Work/Projects #1');
    });

    it('TC-2.1.9: non-Latin Unicode accepted', () => {
      const folder = createFolder(store, 'しごとプロジェクトかんり');
      expect(folder?.name).toBe('しごとプロジェクトかんり');
    });

    it('TC-2.1.10: single char accepted', () => {
      const folder = createFolder(store, 'A');
      expect(folder?.name).toBe('A');
    });

    it('TC-2.1.11: spaces + overlong → trim then truncate to 30', () => {
      const folder = createFolder(store, '  ' + 'A'.repeat(40) + '  ');
      expect(folder?.name).toHaveLength(30);
      expect(folder?.name).toBe('A'.repeat(30));
    });

    it('TC-2.1.12: inner newline preserved (Web: trim only removes leading/trailing)', () => {
      const folder = createFolder(store, 'Work\nProjects');
      expect(folder?.name).toBe('Work\nProjects');
    });

    it('TC-2.1.13: inner tab preserved (Web: trim only removes leading/trailing)', () => {
      const folder = createFolder(store, 'Work\tProjects');
      expect(folder?.name).toBe('Work\tProjects');
    });
  });


  describe('sortOrder TC-3.1', () => {
    it('TC-3.1.3: after deleting middle folder, new folder gets max(remaining)+1000', () => {
      const f1 = createFolder(store, 'A')!; // 1000
      const f2 = createFolder(store, 'B')!; // 2000
      const f3 = createFolder(store, 'C')!; // 3000
      deleteFolder(store, f2.id);           // remove the sortOrder=2000 folder
      const f4 = createFolder(store, 'D')!; // max(remaining)=3000, new=4000
      expect(f4.sortOrder).toBe(4000);
    });
  });


  describe('sortOrder TC-3.2 drag reorder (handleFolderReorder)', () => {
    it('TC-3.2.1: drag to middle - C between A and B', () => {
      const f1 = createFolder(store, 'A')!; // 1000
      const f2 = createFolder(store, 'B')!; // 2000
      const f3 = createFolder(store, 'C')!; // 3000
      handleFolderReorder(store, f3.id, f2.id); // drag C before B
      const sorted = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
      expect(sorted[0].id).toBe(f1.id); // A first
      expect(sorted[1].id).toBe(f3.id); // C second
      expect(sorted[2].id).toBe(f2.id); // B last
      expect(sorted[1].sortOrder).toBeGreaterThan(sorted[0].sortOrder);
      expect(sorted[1].sortOrder).toBeLessThan(sorted[2].sortOrder);
    });

    it('TC-3.2.2: drag to top - C becomes first', () => {
      const f1 = createFolder(store, 'A')!; // 1000
      const f2 = createFolder(store, 'B')!; // 2000
      const f3 = createFolder(store, 'C')!; // 3000
      handleFolderReorder(store, f3.id, f1.id); // drag C before A
      const sorted = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
      expect(sorted[0].id).toBe(f3.id); // C first
    });

    it('TC-3.2.3: drag to bottom - A becomes last', () => {
      const f1 = createFolder(store, 'A')!; // 1000
      const f2 = createFolder(store, 'B')!; // 2000
      const f3 = createFolder(store, 'C')!; // 3000
      // reorderFolders takes the explicit B, C, A order.
      reorderFolders(store, [
        { ...f2, sortOrder: 1000 },
        { ...f3, sortOrder: 2000 },
        { ...f1, sortOrder: 3000 },
      ]);
      const sorted = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
      expect(sorted[2].id).toBe(f1.id); // A last
    });

    it('TC-3.2.4: drag to original position - no change', () => {
      const f1 = createFolder(store, 'A')!; // 1000
      const f2 = createFolder(store, 'B')!; // 2000
      const originalOrder = store.getState().folders.map((f) => f.sortOrder);
      handleFolderReorder(store, f1.id, f1.id); // same source and target
      const afterOrder = store.getState().folders.map((f) => f.sortOrder);
      expect(afterOrder).toEqual(originalOrder);
    });

    it('TC-3.2.5: swap 2 folders - B before A', () => {
      const f1 = createFolder(store, 'A')!; // 1000
      const f2 = createFolder(store, 'B')!; // 2000
      handleFolderReorder(store, f2.id, f1.id); // drag B before A
      const sorted = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
      expect(sorted[0].id).toBe(f2.id); // B first
      expect(sorted[1].id).toBe(f1.id); // A second
    });
  });

  // addConversation uppercases UUIDs, so use conversations[0] or a hardcoded id to keep find() matching.
  describe('moveConversationToFolder TC-4.1', () => {
    it('TC-4.1.1: moving into folder sets folderID', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation({ id: 'conv-4-1-1' });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-1-1', folder.id);

      expect(store.getState().conversations[0].folderID).toBe(folder.id);
    });

    it('TC-4.1.2: cross-folder move changes folderID from A to B', () => {
      const folderA = createFolder(store, 'Folder A')!;
      const folderB = createFolder(store, 'Folder B')!;
      const conv = makeConversation({ id: 'conv-4-1-2', folderID: folderA.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-1-2', folderB.id);

      const updated = store.getState().conversations[0];
      expect(updated.folderID).toBe(folderB.id);
      expect(updated.folderID).not.toBe(folderA.id);
    });

    it('TC-4.1.3: removing from folder clears folderID', () => {
      const folder = createFolder(store, 'Source')!;
      const conv = makeConversation({ id: 'conv-4-1-3', folderID: folder.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-1-3', null);

      expect(store.getState().conversations[0].folderID).toBeUndefined();
    });

    // Metadata-only change, so it must not reorder conversations.
    it('TC-4.1.4: moving does NOT update updatedAt', () => {
      const folder = createFolder(store, 'Target')!;
      const oldTime = new Date(Date.now() - 60000).toISOString();
      const conv = makeConversation({ id: 'conv-4-1-4', updatedAt: oldTime });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-1-4', folder.id);

      expect(store.getState().conversations[0].updatedAt).toBe(oldTime);
    });

    it('TC-4.1.5: moving does not affect conversation content', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation({
        id: 'conv-4-1-5',
        title: 'Important Chat',
        estimatedCost: 2.5,
        previewText: 'Hello world',
      });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-1-5', folder.id);

      const updated = store.getState().conversations[0];
      expect(updated.title).toBe('Important Chat');
      expect(updated.estimatedCost).toBe(2.5);
      expect(updated.previewText).toBe('Hello world');
    });

    it('TC-4.1.6: moving non-existent conversation does not crash', () => {
      const folder = createFolder(store, 'Target')!;
      expect(() => moveConversationToFolder(store, 'non-existent-id', folder.id)).not.toThrow();
      expect(store.getState().conversations).toHaveLength(0);
    });

    it('TC-4.1.7: conversation can only belong to one folder at a time', () => {
      const folderA = createFolder(store, 'Folder A')!;
      const folderB = createFolder(store, 'Folder B')!;
      const conv = makeConversation({ id: 'conv-4-1-7', folderID: folderA.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-1-7', folderB.id);

      const updated = store.getState().conversations[0];
      expect(updated.folderID).toBe(folderB.id);
      const inA = store.getState().conversations.filter((c) => c.folderID === folderA.id);
      expect(inA).toHaveLength(0);
    });

    it('TC-4.1.8: folder count increases after moving in', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation({ id: 'conv-4-1-8', isDraft: false });
      store.getState().addConversation(conv);

      const countBefore = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && !c.isDraft,
      ).length;
      expect(countBefore).toBe(0);

      moveConversationToFolder(store, 'conv-4-1-8', folder.id);

      const countAfter = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && !c.isDraft,
      ).length;
      expect(countAfter).toBe(1);
    });

    it('TC-4.1.9: folder count decreases after moving out', () => {
      const folder = createFolder(store, 'Source')!;
      const c1 = makeConversation({ id: 'co1', isDraft: false, folderID: folder.id });
      const c2 = makeConversation({ id: 'co2', isDraft: false, folderID: folder.id });
      const c3 = makeConversation({ id: 'co3', isDraft: false, folderID: folder.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      const countBefore = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && !c.isDraft,
      ).length;
      expect(countBefore).toBe(3);

      moveConversationToFolder(store, 'co1', null);

      const countAfter = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && !c.isDraft,
      ).length;
      expect(countAfter).toBe(2);
    });
  });


  describe('"moveToFolder" menu logic TC-4.2', () => {
    it('TC-4.2.1: store lists all folders for submenu', () => {
      createFolder(store, 'Folder 1');
      createFolder(store, 'Folder 2');
      createFolder(store, 'Folder 3');

      expect(store.getState().folders).toHaveLength(3);
    });

    it('TC-4.2.3: conversation in folder has non-null folderID (for remove option)', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'conv-4-2-3', folderID: folder.id });
      store.getState().addConversation(conv);

      const c = store.getState().conversations[0];
      expect(c.folderID).toBeDefined();
      expect(c.folderID).toBe(folder.id);
    });

    it('TC-4.2.4: conversation not in folder has no folderID', () => {
      const conv = makeConversation({ id: 'conv-4-2-4' });
      store.getState().addConversation(conv);

      expect(store.getState().conversations[0].folderID).toBeUndefined();
    });

    it('TC-4.2.5: create folder in submenu then auto-move conversation', () => {
      const conv = makeConversation({ id: 'conv-4-2-5' });
      store.getState().addConversation(conv);

      const newFolder = createFolder(store, 'New Folder')!;
      moveConversationToFolder(store, 'conv-4-2-5', newFolder.id);

      expect(store.getState().conversations[0].folderID).toBe(newFolder.id);
    });

    it('TC-4.2.6: moving to same folder keeps folderID unchanged', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'conv-4-2-6', folderID: folder.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'conv-4-2-6', folder.id);

      expect(store.getState().conversations[0].folderID).toBe(folder.id);
    });
  });


  describe('batchMoveToFolder TC-5.1', () => {
    it('TC-5.1.1: batch move multiple conversations into folder', () => {
      const folder = createFolder(store, 'Target')!;
      const c1 = makeConversation({ id: 'b1' });
      const c2 = makeConversation({ id: 'b2' });
      const c3 = makeConversation({ id: 'b3' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      batchMoveToFolder(store, ['b1', 'b2', 'b3'], folder.id);

      const convs = store.getState().conversations;
      expect(convs.find((c) => c.id === 'b1')?.folderID).toBe(folder.id);
      expect(convs.find((c) => c.id === 'b2')?.folderID).toBe(folder.id);
      expect(convs.find((c) => c.id === 'b3')?.folderID).toBe(folder.id);
    });

    it('TC-5.1.2: batch remove from folder clears all folderIDs', () => {
      const folder = createFolder(store, 'Source')!;
      const c1 = makeConversation({ id: 'b1', folderID: folder.id });
      const c2 = makeConversation({ id: 'b2', folderID: folder.id });
      const c3 = makeConversation({ id: 'b3', folderID: folder.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      batchMoveToFolder(store, ['b1', 'b2', 'b3'], null);

      const convs = store.getState().conversations;
      expect(convs.find((c) => c.id === 'b1')?.folderID).toBeUndefined();
      expect(convs.find((c) => c.id === 'b2')?.folderID).toBeUndefined();
      expect(convs.find((c) => c.id === 'b3')?.folderID).toBeUndefined();
    });

    it('TC-5.1.3: mixed state batch move sets all to new folder', () => {
      const folderA = createFolder(store, 'Folder A')!;
      const folderB = createFolder(store, 'Folder B')!;
      const c1 = makeConversation({ id: 'b1', folderID: folderA.id });
      const c2 = makeConversation({ id: 'b2', folderID: folderA.id });
      const c3 = makeConversation({ id: 'b3' }); // not in any folder
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      batchMoveToFolder(store, ['b1', 'b2', 'b3'], folderB.id);

      const convs = store.getState().conversations;
      expect(convs.find((c) => c.id === 'b1')?.folderID).toBe(folderB.id);
      expect(convs.find((c) => c.id === 'b2')?.folderID).toBe(folderB.id);
      expect(convs.find((c) => c.id === 'b3')?.folderID).toBe(folderB.id);
    });

    it('TC-5.1.4: empty selection does nothing', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation({ id: 'b1' });
      store.getState().addConversation(conv);
      const folderIdBefore = store.getState().conversations[0].folderID;

      batchMoveToFolder(store, [], folder.id);

      expect(store.getState().conversations[0].folderID).toBe(folderIdBefore);
    });

    it('TC-5.1.5: invalid IDs in batch do not crash, valid IDs move correctly', () => {
      const folder = createFolder(store, 'Target')!;
      const conv = makeConversation({ id: 'valid-1' });
      store.getState().addConversation(conv);

      expect(() =>
        batchMoveToFolder(store, ['valid-1', 'non-existent-id'], folder.id),
      ).not.toThrow();

      const updated = store.getState().conversations.find((c) => c.id === 'valid-1');
      expect(updated?.folderID).toBe(folder.id);
    });

    it('TC-5.1.6: folder count reflects after batch move', () => {
      const folder = createFolder(store, 'Target')!;
      const c1 = makeConversation({ id: 'b1', isDraft: false });
      const c2 = makeConversation({ id: 'b2', isDraft: false });
      const c3 = makeConversation({ id: 'b3', isDraft: false });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      batchMoveToFolder(store, ['b1', 'b2', 'b3'], folder.id);

      const count = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && !c.isDraft,
      ).length;
      expect(count).toBe(3);
    });
  });


  describe('sortOrder TC-3.3 rebalance', () => {
    it('TC-3.3.1: adjacent diff ≤ 1 triggers global rebalance to 1000,2000,...', () => {
      const f1 = createFolder(store, 'A')!;
      const f2 = createFolder(store, 'B')!;
      const f3 = createFolder(store, 'C')!;
      // Set a tight sortOrder gap of 1 by hand.
      reorderFolders(store, [
        { ...f1, sortOrder: 1000 },
        { ...f2, sortOrder: 1001 }, // diff=1 -> triggers rebalance
        { ...f3, sortOrder: 2000 },
      ]);
      const folders = store.getState().folders;
      expect(folders[0].sortOrder).toBe(1000);
      expect(folders[1].sortOrder).toBe(2000);
      expect(folders[2].sortOrder).toBe(3000);
    });

    it('TC-3.3.2: rebalance preserves visual order', () => {
      const f1 = createFolder(store, 'A')!;
      const f2 = createFolder(store, 'B')!;
      const f3 = createFolder(store, 'C')!;
      reorderFolders(store, [
        { ...f2, sortOrder: 5000 },  // B first
        { ...f3, sortOrder: 5001 },  // C second (diff=1 triggers rebalance)
        { ...f1, sortOrder: 6000 },  // A third
      ]);
      const folders = store.getState().folders;
      expect(folders[0].id).toBe(f2.id); // B still first
      expect(folders[1].id).toBe(f3.id); // C still second
      expect(folders[2].id).toBe(f1.id); // A still last
    });

    it('TC-3.3.3: rebalance result is handed to the sync port', () => {
      const didReorderFolders = vi.fn();
      vi.spyOn(syncModule, 'getSyncAdapter').mockReturnValue({
        didCreateFolder: vi.fn(),
        didReorderFolders,
      } as ReturnType<typeof syncModule.getSyncAdapter>);

      const f1 = createFolder(store, 'A')!;
      const f2 = createFolder(store, 'B')!;
      reorderFolders(store, [
        { ...f1, sortOrder: 100 },
        { ...f2, sortOrder: 101 }, // diff=1 -> triggers rebalance
      ]);

      expect(didReorderFolders).toHaveBeenCalledWith(
        expect.arrayContaining([
          expect.objectContaining({ sortOrder: 1000 }),
          expect.objectContaining({ sortOrder: 2000 }),
        ])
      );

      vi.restoreAllMocks();
    });
  });


  describe('TC-6.1 expand and collapse', () => {
    it('TC-6.1.1: new folder defaults to collapsed', () => {
      const folder = createFolder(store, 'Work')!;
      expect(store.getState().expandedFolderIds).not.toContain(folder.id);
    });

    it('TC-6.1.2: toggle once → folder is expanded', () => {
      const folder = createFolder(store, 'Work')!;
      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).toContain(folder.id);
    });

    it('TC-6.1.3: toggle when expanded → folder is collapsed', () => {
      const folder = createFolder(store, 'Work')!;
      store.getState().toggleFolderExpand(folder.id);
      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).not.toContain(folder.id);
    });

    it('TC-6.1.4: double toggle is idempotent', () => {
      const folder = createFolder(store, 'Work')!;
      const before = store.getState().expandedFolderIds.includes(folder.id);
      store.getState().toggleFolderExpand(folder.id);
      store.getState().toggleFolderExpand(folder.id);
      const after = store.getState().expandedFolderIds.includes(folder.id);
      expect(after).toBe(before);
    });

    it('TC-6.1.6: multiple folders expand independently', () => {
      const fA = createFolder(store, 'A')!;
      const fB = createFolder(store, 'B')!;
      const fC = createFolder(store, 'C')!;
      store.getState().toggleFolderExpand(fA.id);
      store.getState().toggleFolderExpand(fC.id);
      expect(store.getState().expandedFolderIds).toContain(fA.id);
      expect(store.getState().expandedFolderIds).not.toContain(fB.id);
      expect(store.getState().expandedFolderIds).toContain(fC.id);
    });

    it('TC-6.1.7: expanded folder shows correct conversation count (non-draft)', () => {
      const folder = createFolder(store, 'Work')!;
      const c1 = makeConversation({ id: 'e1', folderID: folder.id, isDraft: false });
      const c2 = makeConversation({ id: 'e2', folderID: folder.id, isDraft: false });
      const draft = makeConversation({ id: 'e3', folderID: folder.id, isDraft: true, messages: [] });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(draft);

      const count = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(count).toBe(2);
    });

    it('TC-6.1.8: empty folder has zero non-draft conversations', () => {
      const folder = createFolder(store, 'Empty')!;
      store.getState().toggleFolderExpand(folder.id);
      const conversations = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft);
      expect(conversations).toHaveLength(0);
    });
  });


  describe('TC-7.1 time-group filtering', () => {
    it('TC-7.1.1: conversations in folders are excluded from time groups', () => {
      const folder = createFolder(store, 'Work')!;
      const inFolder = makeConversation({ id: 'g1', folderID: folder.id });
      const notInFolder = makeConversation({ id: 'g2' });
      store.getState().addConversation(inFolder);
      store.getState().addConversation(notInFolder);

      const groups = groupConversations(store.getState().conversations);
      const allGrouped = groups.flatMap((g) => g.items);
      expect(allGrouped.find((c) => c.id === 'g1')).toBeUndefined();
      expect(allGrouped.find((c) => c.id === 'g2')).toBeDefined();
    });

    it('TC-7.1.2: conversations without folder appear in time groups', () => {
      const c1 = makeConversation({ id: 'ug1' });
      const c2 = makeConversation({ id: 'ug2' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);

      const groups = groupConversations(store.getState().conversations);
      const allGrouped = groups.flatMap((g) => g.items);
      expect(allGrouped.find((c) => c.id === 'ug1')).toBeDefined();
      expect(allGrouped.find((c) => c.id === 'ug2')).toBeDefined();
    });

    it('TC-7.1.3: after moving into folder, conversation disappears from time groups', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'mv1' });
      store.getState().addConversation(conv);

      const before = groupConversations(store.getState().conversations).flatMap((g) => g.items);
      expect(before.find((c) => c.id === 'mv1')).toBeDefined();

      moveConversationToFolder(store, 'mv1', folder.id);

      const after = groupConversations(store.getState().conversations).flatMap((g) => g.items);
      expect(after.find((c) => c.id === 'mv1')).toBeUndefined();
    });

    it('TC-7.1.4: after moving out of folder, conversation returns to time groups', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'mv2', folderID: folder.id });
      store.getState().addConversation(conv);

      const before = groupConversations(store.getState().conversations).flatMap((g) => g.items);
      expect(before.find((c) => c.id === 'mv2')).toBeUndefined();

      moveConversationToFolder(store, 'mv2', null);

      const after = groupConversations(store.getState().conversations).flatMap((g) => g.items);
      expect(after.find((c) => c.id === 'mv2')).toBeDefined();
    });

    it('TC-7.1.6: draft conversations not counted in folder', () => {
      const folder = createFolder(store, 'Work')!;
      const normal1 = makeConversation({ id: 'd1', folderID: folder.id, isDraft: false });
      const normal2 = makeConversation({ id: 'd2', folderID: folder.id, isDraft: false });
      const draft = makeConversation({ id: 'd3', folderID: folder.id, isDraft: true, messages: [] });
      store.getState().addConversation(normal1);
      store.getState().addConversation(normal2);
      store.getState().addConversation(draft);

      const count = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(count).toBe(2);
    });

    it('TC-7.1.7: draft conversations not shown in folder expand list', () => {
      const folder = createFolder(store, 'Work')!;
      const normal = makeConversation({ id: 'sl1', folderID: folder.id, isDraft: false });
      const draft = makeConversation({ id: 'sl2', folderID: folder.id, isDraft: true, messages: [] });
      store.getState().addConversation(normal);
      store.getState().addConversation(draft);

      const visible = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && (!c.isDraft || c.messages.length > 0));
      expect(visible.map((c) => c.id)).toContain('sl1');
      expect(visible.map((c) => c.id)).not.toContain('sl2');
    });
  });


  describe('TC-8.1 global search', () => {
    it('TC-8.1.1: store conversations include folder conversations (available for search)', () => {
      const folder = createFolder(store, 'Work')!;
      const inFolder = makeConversation({ id: 'sr1', title: 'AI Discussion', folderID: folder.id });
      const notInFolder = makeConversation({ id: 'sr2', title: 'Daily Note' });
      store.getState().addConversation(inFolder);
      store.getState().addConversation(notInFolder);

      // The global conversations list holds everything, including conversations inside folders.
      const all = store.getState().conversations;
      expect(all.find((c) => c.id === 'sr1')).toBeDefined();
      expect(all.find((c) => c.id === 'sr2')).toBeDefined();
    });

    it('TC-8.1.2: conversations in folders have folderID for folder tag display', () => {
      const folder = createFolder(store, 'Work')!;
      const inFolder = makeConversation({ id: 'sr3', folderID: folder.id });
      store.getState().addConversation(inFolder);

      const conv = store.getState().conversations.find((c) => c.id === 'sr3');
      expect(conv?.folderID).toBe(folder.id);
      const folderName = store.getState().folders.find((f) => f.id === conv?.folderID)?.name;
      expect(folderName).toBe('Work');
    });

    it('TC-8.1.3: conversations not in folders have no folderID', () => {
      const conv = makeConversation({ id: 'sr4' });
      store.getState().addConversation(conv);

      const found = store.getState().conversations.find((c) => c.id === 'sr4');
      expect(found?.folderID).toBeUndefined();
    });
  });


  describe('TC-8.2 search inside a folder', () => {
    it('TC-8.2.1: folder-scoped search only returns conversations in that folder', () => {
      const folderA = createFolder(store, 'A')!;
      const folderB = createFolder(store, 'B')!;
      const c1 = makeConversation({ id: 'fs1', title: 'meeting notes', folderID: folderA.id });
      const c2 = makeConversation({ id: 'fs2', title: 'meeting recap', folderID: folderB.id });
      const c3 = makeConversation({ id: 'fs3', title: 'meeting prep', folderID: folderA.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      const folderAConvs = store
        .getState()
        .conversations.filter(
          (c) => c.folderID === folderA.id && c.title.toLowerCase().includes('meeting'),
        );
      expect(folderAConvs).toHaveLength(2);
      expect(folderAConvs.map((c) => c.id)).not.toContain('fs2');
    });

    it('TC-8.2.3: folder search matches by title', () => {
      const folder = createFolder(store, 'Research')!;
      const c1 = makeConversation({ id: 'fm1', title: 'AI Research Summary', folderID: folder.id });
      const c2 = makeConversation({ id: 'fm2', title: 'Budget Planning', folderID: folder.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);

      const results = store
        .getState()
        .conversations.filter(
          (c) => c.folderID === folder.id && c.title.toLowerCase().includes('ai'),
        );
      expect(results).toHaveLength(1);
      expect(results[0].id).toBe('fm1');
    });

    it('TC-8.2.2: no results returns empty list', () => {
      const folder = createFolder(store, 'Empty Search')!;
      const conv = makeConversation({ id: 'fe1', title: 'Regular Chat', folderID: folder.id });
      store.getState().addConversation(conv);

      const results = store
        .getState()
        .conversations.filter(
          (c) => c.folderID === folder.id && c.title.toLowerCase().includes('nonexistentkeyword'),
        );
      expect(results).toHaveLength(0);
    });
  });


  describe('TC-9.1 folder detail page', () => {
    it('TC-9.1.1: folder with 12 conversations → count should be 12 (non-draft only)', () => {
      const folder = createFolder(store, 'Big Folder')!;
      for (let i = 0; i < 12; i++) {
        const conv = makeConversation({ id: `fd-${i}`, folderID: folder.id, isDraft: false });
        store.getState().addConversation(conv);
      }
      // Add a draft; it must not be counted.
      const draft = makeConversation({ id: 'fd-draft', folderID: folder.id, isDraft: true, messages: [] });
      store.getState().addConversation(draft);

      const count = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(count).toBe(12);
    });

    it('TC-9.1.2: conversations sorted by updatedAt descending', () => {
      const folder = createFolder(store, 'Sorted')!;
      const c1 = makeConversation({ id: 'so1', folderID: folder.id, updatedAt: '2025-01-01T00:00:00Z' });
      const c2 = makeConversation({ id: 'so2', folderID: folder.id, updatedAt: '2025-06-15T00:00:00Z' });
      const c3 = makeConversation({ id: 'so3', folderID: folder.id, updatedAt: '2025-03-10T00:00:00Z' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      const sorted = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id)
        .sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());

      expect(sorted[0].id).toBe('so2'); // newest
      expect(sorted[1].id).toBe('so3');
      expect(sorted[2].id).toBe('so1'); // oldest
    });

    it('TC-9.1.3: search within folder filters by folderID and title', () => {
      const folder = createFolder(store, 'Search Folder')!;
      const c1 = makeConversation({ id: 'sf1', title: 'Machine Learning Notes', folderID: folder.id });
      const c2 = makeConversation({ id: 'sf2', title: 'Daily Standup', folderID: folder.id });
      const c3 = makeConversation({ id: 'sf3', title: 'Machine Learning Paper', folderID: folder.id });
      // Same title, but outside this folder.
      const c4 = makeConversation({ id: 'sf4', title: 'Machine Learning General' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);
      store.getState().addConversation(c4);

      const query = 'machine learning';
      const results = store
        .getState()
        .conversations.filter(
          (c) => c.folderID === folder.id && c.title.toLowerCase().includes(query),
        );
      expect(results).toHaveLength(2);
      expect(results.map((c) => c.id).sort()).toEqual(['sf1', 'sf3']);
    });

    it('TC-9.1.4: rename folder from detail page', () => {
      const folder = createFolder(store, 'Old Detail Name')!;
      const conv = makeConversation({ id: 'rd1', folderID: folder.id });
      store.getState().addConversation(conv);

      renameFolder(store, folder.id, 'New Detail Name');

      const updated = store.getState().folders.find((f) => f.id === folder.id);
      expect(updated?.name).toBe('New Detail Name');
      expect(store.getState().conversations[0].folderID).toBe(folder.id);
    });

    it('TC-9.1.5: delete folder from detail cascades, conversations kept', () => {
      const folder = createFolder(store, 'Delete Me')!;
      const c1 = makeConversation({ id: 'dd1', folderID: folder.id, title: 'Chat 1' });
      const c2 = makeConversation({ id: 'dd2', folderID: folder.id, title: 'Chat 2' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);

      deleteFolder(store, folder.id);

      expect(store.getState().folders).toHaveLength(0);
      expect(store.getState().conversations).toHaveLength(2);
      store.getState().conversations.forEach((c) => {
        expect(c.folderID).toBeUndefined();
      });
    });

    it('TC-9.1.6: folder deleted externally → conversations still accessible', () => {
      const folder = createFolder(store, 'External Delete')!;
      const conv = makeConversation({ id: 'ed1', folderID: folder.id, title: 'Surviving Chat' });
      store.getState().addConversation(conv);

      // Simulate an external delete by calling the store action directly.
      store.getState().removeFolder(folder.id);

      const remaining = store.getState().conversations;
      expect(remaining).toHaveLength(1);
      expect(remaining[0].title).toBe('Surviving Chat');
      expect(remaining[0].folderID).toBeUndefined();
    });

    it('TC-9.1.7: empty folder → 0 conversations count', () => {
      const folder = createFolder(store, 'Empty Detail')!;
      const count = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(count).toBe(0);
    });

    it('TC-9.1.8: edit mode - can select conversations via Set manipulation', () => {
      const folder = createFolder(store, 'Edit Mode')!;
      const c1 = makeConversation({ id: 'em1', folderID: folder.id });
      const c2 = makeConversation({ id: 'em2', folderID: folder.id });
      const c3 = makeConversation({ id: 'em3', folderID: folder.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      // Stand in for the UI-level selectedIds with a plain Set.
      const selectedIds = new Set<string>();
      selectedIds.add('em1');
      selectedIds.add('em3');
      expect(selectedIds.size).toBe(2);
      expect(selectedIds.has('em1')).toBe(true);
      expect(selectedIds.has('em2')).toBe(false);
      expect(selectedIds.has('em3')).toBe(true);

      selectedIds.delete('em1');
      expect(selectedIds.size).toBe(1);
      expect(selectedIds.has('em1')).toBe(false);
    });

    it('TC-9.1.9: batch move out of folder from detail page', () => {
      const folder = createFolder(store, 'Source Detail')!;
      const c1 = makeConversation({ id: 'bm1', folderID: folder.id });
      const c2 = makeConversation({ id: 'bm2', folderID: folder.id });
      const c3 = makeConversation({ id: 'bm3', folderID: folder.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      batchMoveToFolder(store, ['bm1', 'bm3'], null);

      const convs = store.getState().conversations;
      expect(convs.find((c) => c.id === 'bm1')?.folderID).toBeUndefined();
      expect(convs.find((c) => c.id === 'bm2')?.folderID).toBe(folder.id);
      expect(convs.find((c) => c.id === 'bm3')?.folderID).toBeUndefined();
    });

    it('TC-9.1.10: batch delete conversations', () => {
      const folder = createFolder(store, 'Batch Delete')!;
      const c1 = makeConversation({ id: 'bd1', folderID: folder.id });
      const c2 = makeConversation({ id: 'bd2', folderID: folder.id });
      const c3 = makeConversation({ id: 'bd3', folderID: folder.id });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);
      expect(store.getState().conversations).toHaveLength(3);

      ['bd1', 'bd3'].forEach((id) => store.getState().removeConversation(id));

      const remaining = store.getState().conversations;
      expect(remaining).toHaveLength(1);
      expect(remaining[0].id).toBe('bd2');
      expect(remaining[0].folderID).toBe(folder.id);
    });

    it('TC-9.1.11: new conversation button from detail page', () => {
      const folder = createFolder(store, 'Detail New')!;
      // One non-draft conversation already exists.
      const existing = makeConversation({ id: 'dn1', folderID: folder.id, isDraft: false });
      store.getState().addConversation(existing);

      const newId = createConversationInFolder(store, folder.id);
      // addConversation uppercases the UUID.
      const normalizedId = newId.toUpperCase();

      const convs = store.getState().conversations;
      expect(convs).toHaveLength(2);
      const newConv = convs.find((c) => c.id === normalizedId);
      expect(newConv).toBeDefined();
      expect(newConv?.folderID).toBe(folder.id);
      expect(newConv?.isDraft).toBe(true);
      expect(store.getState().activeConversationId).toBe(normalizedId);
    });
  });


  describe('TC-10.1 new conversation inside a folder', () => {
    it('TC-10.1.1: new conversation has folderID set and isDraft=true', () => {
      const folder = createFolder(store, 'Create Folder')!;
      const newId = createConversationInFolder(store, folder.id);
      const normalizedId = newId.toUpperCase();

      const conv = store.getState().conversations.find((c) => c.id === normalizedId);
      expect(conv).toBeDefined();
      expect(conv?.folderID).toBe(folder.id);
      expect(conv?.isDraft).toBe(true);
      expect(conv?.title).toBe('');
      expect(conv?.messages).toEqual([]);
    });

    it('TC-10.1.2: global new conversation without folderID → folderID is undefined', () => {
      const conv = makeConversation({ id: 'global-new' });
      store.getState().addConversation(conv);

      const found = store.getState().conversations.find((c) => c.id === 'global-new');
      expect(found?.folderID).toBeUndefined();
    });

    it('TC-10.1.3: draft does not count, after making non-draft it counts', () => {
      const folder = createFolder(store, 'Count Folder')!;
      const existing = makeConversation({ id: 'cnt1', folderID: folder.id, isDraft: false });
      store.getState().addConversation(existing);

      const countBefore = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(countBefore).toBe(1);

      const newId = createConversationInFolder(store, folder.id);
      const countWithDraft = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(countWithDraft).toBe(1); // drafts are not counted

      store.getState().updateConversation(newId, { isDraft: false, title: 'Now Active' });
      const countAfter = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(countAfter).toBe(2);
    });

    it('TC-10.1.4: empty folder → create conversation → conversation is in folder', () => {
      const folder = createFolder(store, 'Was Empty')!;
      const countBefore = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id).length;
      expect(countBefore).toBe(0);

      const newId = createConversationInFolder(store, folder.id);
      const normalizedId = newId.toUpperCase();

      const convs = store.getState().conversations.filter((c) => c.folderID === folder.id);
      expect(convs).toHaveLength(1);
      expect(convs[0].id).toBe(normalizedId);
      expect(convs[0].folderID).toBe(folder.id);
    });
  });


  describe('TC-11.1 navigation behavior', () => {
    it('TC-11.1.1: expand folder → other actions do not affect expand state', () => {
      const folder = createFolder(store, 'Nav Folder')!;
      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      // Adding a conversation does not change expand state.
      const conv = makeConversation({ id: 'nav1', folderID: folder.id });
      store.getState().addConversation(conv);
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      // Moving a conversation does not change expand state.
      moveConversationToFolder(store, 'nav1', null);
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      // Creating another folder does not change existing expand state.
      createFolder(store, 'Another Folder');
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      // Renaming does not change expand state.
      renameFolder(store, folder.id, 'Renamed Nav');
      expect(store.getState().expandedFolderIds).toContain(folder.id);
    });

    it('TC-11.1.2: activeConversationId can be set independently of folder state', () => {
      const folder = createFolder(store, 'Active Folder')!;
      const c1 = makeConversation({ id: 'ac1', folderID: folder.id });
      const c2 = makeConversation({ id: 'ac2' }); // not in a folder
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);

      store.getState().setActiveConversationId('ac1');
      expect(store.getState().activeConversationId).toBe('ac1');

      // Switching to a conversation outside the folder leaves the expand state alone.
      store.getState().toggleFolderExpand(folder.id);
      store.getState().setActiveConversationId('ac2');
      expect(store.getState().activeConversationId).toBe('ac2');
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      store.getState().setActiveConversationId(null);
      expect(store.getState().activeConversationId).toBeNull();
      expect(store.getState().expandedFolderIds).toContain(folder.id);
    });

    it('TC-11.1.4: create conversation in folder → folder auto-expands', () => {
      const folder = createFolder(store, 'Auto Expand')!;
      expect(store.getState().expandedFolderIds).not.toContain(folder.id);

      // Expand manually after creating, mirroring what the UI does.
      createConversationInFolder(store, folder.id);
      if (!store.getState().expandedFolderIds.includes(folder.id)) {
        store.getState().toggleFolderExpand(folder.id);
      }

      expect(store.getState().expandedFolderIds).toContain(folder.id);
      expect(store.getState().activeConversationId).not.toBeNull();
    });

    it('TC-11.1.5: folder expand state persists through other store mutations', () => {
      const fA = createFolder(store, 'Folder A')!;
      const fB = createFolder(store, 'Folder B')!;
      store.getState().toggleFolderExpand(fA.id);
      expect(store.getState().expandedFolderIds).toContain(fA.id);
      expect(store.getState().expandedFolderIds).not.toContain(fB.id);

      for (let i = 0; i < 5; i++) {
        store.getState().addConversation(
          makeConversation({ id: `persist-${i}`, folderID: fA.id }),
        );
      }
      expect(store.getState().expandedFolderIds).toContain(fA.id);
      expect(store.getState().expandedFolderIds).not.toContain(fB.id);

      batchMoveToFolder(store, ['persist-0', 'persist-1'], fB.id);
      expect(store.getState().expandedFolderIds).toContain(fA.id);
      expect(store.getState().expandedFolderIds).not.toContain(fB.id);

      const fC = createFolder(store, 'Folder C')!;
      store.getState().toggleFolderExpand(fC.id);
      expect(store.getState().expandedFolderIds).toContain(fC.id);
      deleteFolder(store, fC.id);
      // fC was dropped, but fA stays expanded.
      expect(store.getState().expandedFolderIds).toContain(fA.id);
      expect(store.getState().expandedFolderIds).not.toContain(fC.id);

      reorderFolders(store, [
        { ...store.getState().folders.find((f) => f.id === fB.id)!, sortOrder: 1000 },
        { ...store.getState().folders.find((f) => f.id === fA.id)!, sortOrder: 2000 },
      ]);
      expect(store.getState().expandedFolderIds).toContain(fA.id);
      expect(store.getState().expandedFolderIds).not.toContain(fB.id);
    });
  });


  describe('TC-12 toast backing state', () => {
    it('TC-12.1.1: moveConversationToFolder sets folderID (backing the "moved to folder" toast)', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'tc-12-1' });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'tc-12-1', folder.id);

      const updated = store.getState().conversations.find((c) => c.id === 'tc-12-1')!;
      expect(updated.folderID).toBe(folder.id);
    });

    it('TC-12.1.2: moveConversationToFolder with null clears folderID (backing the "removed from folder" toast)', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'tc-12-2', folderID: folder.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'tc-12-2', null);

      const updated = store.getState().conversations.find((c) => c.id === 'tc-12-2')!;
      expect(updated.folderID).toBeUndefined();
    });

    it('TC-12.1.3: batchMoveToFolder sets folderID on 3 conversations', () => {
      const folder = createFolder(store, 'Work')!;
      const ids = ['tc-12-3a', 'tc-12-3b', 'tc-12-3c'];
      ids.forEach((id) => store.getState().addConversation(makeConversation({ id })));

      batchMoveToFolder(store, ids, folder.id);

      const convs = store.getState().conversations.filter((c) => ids.includes(c.id));
      expect(convs).toHaveLength(3);
      convs.forEach((c) => expect(c.folderID).toBe(folder.id));
    });

    it('TC-12.1.4: batchMoveToFolder with null clears folderID from 3 conversations', () => {
      const folder = createFolder(store, 'Work')!;
      const ids = ['tc-12-4a', 'tc-12-4b', 'tc-12-4c'];
      ids.forEach((id) =>
        store.getState().addConversation(makeConversation({ id, folderID: folder.id })),
      );

      batchMoveToFolder(store, ids, null);

      const convs = store.getState().conversations.filter((c) => ids.includes(c.id));
      convs.forEach((c) => expect(c.folderID).toBeUndefined());
    });
  });

  // ── TC-13 Context Menu backing logic ────────────────────────────────────────────

  describe('TC-13 Context Menu backing logic', () => {
    it('TC-13.2.2: folders sorted by sortOrder for context menu display', () => {
      createFolder(store, 'C'); // sortOrder=1000
      createFolder(store, 'A'); // sortOrder=2000
      createFolder(store, 'B'); // sortOrder=3000

      const sorted = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
      expect(sorted[0].name).toBe('C');
      expect(sorted[1].name).toBe('A');
      expect(sorted[2].name).toBe('B');
    });

    it('TC-13.2.4: conversation in folder has non-null folderID → "remove from folder" shows', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'tc-13-1', folderID: folder.id });
      store.getState().addConversation(conv);

      const found = store.getState().conversations.find((c) => c.id === 'tc-13-1')!;
      expect(found.folderID).toBe(folder.id); // currentFolderId would be set → shows remove option
    });

    it('TC-13.2.4: after remove, folderID is undefined → "remove from folder" hidden', () => {
      const folder = createFolder(store, 'Work')!;
      const conv = makeConversation({ id: 'tc-13-2', folderID: folder.id });
      store.getState().addConversation(conv);

      moveConversationToFolder(store, 'tc-13-2', null);

      const found = store.getState().conversations.find((c) => c.id === 'tc-13-2')!;
      expect(found.folderID).toBeUndefined();
    });

    // 30 matches the maxLength of the name input.
    it('TC-13.3.3: createFolder name is truncated to 30 characters', () => {
      const folder = createFolder(store, 'x'.repeat(40))!;
      expect(folder.name).toHaveLength(30);
    });

    it('TC-13.3.4: createFolder with empty name returns null', () => {
      expect(createFolder(store, '')).toBeNull();
      expect(createFolder(store, '   ')).toBeNull();
      expect(store.getState().folders).toHaveLength(0);
    });
  });


  describe('TC-14 drag and drop', () => {
    it('TC-14.1.1: drop unclassified conversation onto folder moves it into folder', () => {
      const folder = createFolder(store, 'Drop Target')!;
      const conv = makeConversation({ id: 'dragged-conv' });
      store.getState().addConversation(conv);

      expect(store.getState().conversations[0].folderID).toBeUndefined();

      // Mirror FolderItem.handleDrop: read convId, skip if it is already in this folder, otherwise move it.
      const convId = 'dragged-conv';
      const alreadyInFolder = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id)
        .some((c) => c.id === convId);

      if (!alreadyInFolder) {
        moveConversationToFolder(store, convId, folder.id);
      }

      expect(store.getState().conversations[0].folderID).toBe(folder.id);
    });

    it('TC-14.1.3: drop with empty convId causes no store change', () => {
      const folder = createFolder(store, 'Drop Target')!;
      const conv = makeConversation({ id: 'stable-conv' });
      store.getState().addConversation(conv);

      const beforeFolderID = store.getState().conversations.find((c) => c.id === 'stable-conv')!
        .folderID;

      // Mirror the handleDrop guard: if (!convId) return
      const convId = '';
      if (convId) {
        moveConversationToFolder(store, convId, folder.id);
      }

      const afterFolderID = store.getState().conversations.find((c) => c.id === 'stable-conv')!
        .folderID;
      expect(afterFolderID).toBe(beforeFolderID);
    });

    it('TC-14.1.1 guard: conversation already in folder is not re-moved', () => {
      const folder = createFolder(store, 'Drop Target')!;
      const conv = makeConversation({ id: 'in-folder-conv', folderID: folder.id });
      store.getState().addConversation(conv);

      const before = store.getState().conversations.find((c) => c.id === 'in-folder-conv')!
        .folderID;

      // Mirror the handleDrop guard: if (conversations.some(c => c.id === convId)) return
      const convId = 'in-folder-conv';
      const alreadyInFolder = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id)
        .some((c) => c.id === convId);

      if (!alreadyInFolder) {
        moveConversationToFolder(store, convId, folder.id);
      }

      const after = store.getState().conversations.find((c) => c.id === 'in-folder-conv')!.folderID;
      expect(after).toBe(before);
      expect(after).toBe(folder.id);
    });

    it('TC-14.1.4: folder drag reorder updates sortOrder via handleFolderReorder', () => {
      const fA = createFolder(store, 'A')!; // sortOrder=1000
      const fB = createFolder(store, 'B')!; // sortOrder=2000
      const fC = createFolder(store, 'C')!; // sortOrder=3000

      // Drag C in front of A.
      handleFolderReorder(store, fC.id, fA.id);

      const sorted = [...store.getState().folders].sort((a, b) => a.sortOrder - b.sortOrder);
      expect(sorted[0].id).toBe(fC.id);
      expect(sorted[1].id).toBe(fA.id);
      expect(sorted[2].id).toBe(fB.id);
    });
  });


  describe('TC-22.1: edge cases', () => {
    it('22.1.1: delete last conversation from folder → folder remains, shows empty state', () => {
      const folder = createFolder(store, 'Solo Folder')!;
      const conv = makeConversation({ id: 'last-conv', folderID: folder.id });
      store.getState().addConversation(conv);

      // One conversation is in the folder.
      expect(
        store.getState().conversations.filter((c) => c.folderID === folder.id).length,
      ).toBe(1);

      store.getState().removeConversation('last-conv');

      expect(store.getState().folders).toHaveLength(1);
      expect(store.getState().folders[0].id).toBe(folder.id);

      const remaining = store.getState().conversations.filter((c) => c.folderID === folder.id);
      expect(remaining).toHaveLength(0);
    });

    it('22.1.2: 100+ conversations in single folder → all load correctly', () => {
      const folder = createFolder(store, 'Big Folder')!;
      const count = 120;
      for (let i = 0; i < count; i++) {
        store.getState().addConversation(
          makeConversation({ id: `bulk-${i}`, folderID: folder.id, isDraft: false }),
        );
      }

      const inFolder = store.getState().conversations.filter((c) => c.folderID === folder.id);
      expect(inFolder).toHaveLength(count);
      inFolder.forEach((c) => {
        expect(c.folderID).toBe(folder.id);
        expect(c.title).toBe('Test Chat');
      });
    });

    it('22.1.3: 50+ folders → list renders correctly', () => {
      const count = 55;
      for (let i = 0; i < count; i++) {
        createFolder(store, `Folder ${i}`);
      }

      const folders = store.getState().folders;
      expect(folders).toHaveLength(count);
      // sortOrder is strictly increasing.
      for (let i = 1; i < folders.length; i++) {
        expect(folders[i].sortOrder).toBeGreaterThan(folders[i - 1].sortOrder);
      }
      const names = new Set(folders.map((f) => f.name));
      expect(names.size).toBe(count);
    });

    it('22.1.5: quick sequential create → rename → delete → each step state correct', () => {
      // create
      const folder = createFolder(store, 'Step1')!;
      expect(store.getState().folders).toHaveLength(1);
      expect(store.getState().folders[0].name).toBe('Step1');

      // rename
      renameFolder(store, folder.id, 'Step2');
      expect(store.getState().folders).toHaveLength(1);
      expect(store.getState().folders[0].name).toBe('Step2');

      // delete
      deleteFolder(store, folder.id);
      expect(store.getState().folders).toHaveLength(0);
    });

    it('22.1.6: draft conversation in folder → folderID set, but folder count excludes drafts', () => {
      const folder = createFolder(store, 'Draft Test')!;
      const normal = makeConversation({ id: 'n1', folderID: folder.id, isDraft: false });
      const draft = makeConversation({
        id: 'd1',
        folderID: folder.id,
        isDraft: true,
        messages: [],
      });
      store.getState().addConversation(normal);
      store.getState().addConversation(draft);

      const draftConv = store.getState().conversations.find((c) => c.id === 'd1');
      expect(draftConv?.folderID).toBe(folder.id);

      // The count excludes drafts.
      const count = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(count).toBe(1);
    });

    it('22.1.7: delete conversation from folder → folder count decreases', () => {
      const folder = createFolder(store, 'Count Folder')!;
      const c1 = makeConversation({ id: 'dc1', folderID: folder.id, isDraft: false });
      const c2 = makeConversation({ id: 'dc2', folderID: folder.id, isDraft: false });
      const c3 = makeConversation({ id: 'dc3', folderID: folder.id, isDraft: false });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      expect(
        store.getState().conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length,
      ).toBe(3);

      store.getState().removeConversation('dc1');

      expect(
        store.getState().conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length,
      ).toBe(2);

      expect(store.getState().folders.find((f) => f.id === folder.id)).toBeDefined();
    });
  });


  describe('TC-25.1: shared behavior contract', () => {
    it('TC-25.1.1: max folder name length = 30 characters', () => {
      // createFolder truncates to 30.
      const folder = createFolder(store, 'A'.repeat(50))!;
      expect(folder.name).toHaveLength(30);

      // Exactly 30 characters is kept intact.
      const exact = createFolder(store, 'B'.repeat(30))!;
      expect(exact.name).toHaveLength(30);
      expect(exact.name).toBe('B'.repeat(30));

      // 29 characters is not truncated.
      const under = createFolder(store, 'C'.repeat(29))!;
      expect(under.name).toHaveLength(29);

      // renameFolder truncates to 30 as well.
      renameFolder(store, folder.id, 'D'.repeat(40));
      expect(store.getState().folders.find((f) => f.id === folder.id)?.name).toHaveLength(30);
    });

    it('TC-25.1.2: empty or whitespace-only name is rejected', () => {
      expect(createFolder(store, '')).toBeNull();
      expect(createFolder(store, '   ')).toBeNull();
      expect(createFolder(store, '\t\t')).toBeNull();
      expect(createFolder(store, '\n\n')).toBeNull();

      expect(store.getState().folders).toHaveLength(0);

      // renameFolder rejects empty and whitespace-only names too.
      const folder = createFolder(store, 'Keep')!;
      renameFolder(store, folder.id, '');
      expect(store.getState().folders[0].name).toBe('Keep');
      renameFolder(store, folder.id, '   ');
      expect(store.getState().folders[0].name).toBe('Keep');
    });

    it('TC-25.1.3: sortOrder initial value = 1000', () => {
      const folder = createFolder(store, 'First Folder')!;
      expect(folder.sortOrder).toBe(1000);
    });

    it('TC-25.1.4: sortOrder increment = +1000', () => {
      const f1 = createFolder(store, 'F1')!;
      const f2 = createFolder(store, 'F2')!;
      const f3 = createFolder(store, 'F3')!;
      const f4 = createFolder(store, 'F4')!;

      expect(f1.sortOrder).toBe(1000);
      expect(f2.sortOrder).toBe(2000);
      expect(f3.sortOrder).toBe(3000);
      expect(f4.sortOrder).toBe(4000);

      // Each step is exactly 1000.
      expect(f2.sortOrder - f1.sortOrder).toBe(1000);
      expect(f3.sortOrder - f2.sortOrder).toBe(1000);
      expect(f4.sortOrder - f3.sortOrder).toBe(1000);
    });

    it('TC-25.1.5: delete folder cascades to clear folderID from conversations', () => {
      const folder = createFolder(store, 'Cascade Target')!;
      const c1 = makeConversation({ id: 'cc1', folderID: folder.id, title: 'Chat 1' });
      const c2 = makeConversation({ id: 'cc2', folderID: folder.id, title: 'Chat 2' });
      const c3 = makeConversation({ id: 'cc3', title: 'Not in folder' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);

      // Two conversations sit in the folder; c3 does not.
      const countBefore = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(countBefore).toBe(2);

      deleteFolder(store, folder.id);

      expect(store.getState().folders).toHaveLength(0);
      expect(store.getState().conversations).toHaveLength(3);
      const updated1 = store.getState().conversations.find((c) => c.id === 'cc1');
      const updated2 = store.getState().conversations.find((c) => c.id === 'cc2');
      const unaffected = store.getState().conversations.find((c) => c.id === 'cc3');
      expect(updated1?.folderID).toBeUndefined();
      expect(updated2?.folderID).toBeUndefined();
      expect(unaffected?.folderID).toBeUndefined();
      expect(updated1?.title).toBe('Chat 1');
      expect(updated2?.title).toBe('Chat 2');
    });

    it('22.1.8: folder name with quotes/backslash saves/displays correctly', () => {
      const folder = createFolder(store, 'He said "hello"')!;
      expect(folder.name).toBe('He said "hello"');
      expect(store.getState().folders[0].name).toBe('He said "hello"');

      const folder2 = createFolder(store, 'path\\to\\folder')!;
      expect(folder2.name).toBe('path\\to\\folder');
    });

    it('22.1.9: folder name with HTML/XSS → stored as plain text', () => {
      const xssName = '<script>alert(1)</script>';
      const folder = createFolder(store, xssName)!;
      // The name is stored verbatim without HTML escaping; the render layer handles safety.
      expect(folder.name).toBe(xssName);
      expect(store.getState().folders[0].name).toBe(xssName);
    });

    it('22.1.11: conversation folderID points to deleted folder → treated as uncategorized', () => {
      const folder = createFolder(store, 'To Delete')!;
      const conv = makeConversation({ id: 'orphan-1', folderID: folder.id });
      store.getState().addConversation(conv);

      deleteFolder(store, folder.id);

      // removeFolder cascades and clears folderID.
      const updated = store.getState().conversations.find((c) => c.id === 'orphan-1');
      expect(updated?.folderID).toBeUndefined();

      const groups = groupConversations(store.getState().conversations);
      const allGrouped = groups.flatMap((g) => g.items);
      expect(allGrouped.find((c) => c.id === 'orphan-1')).toBeDefined();
    });

    it('22.1.13: long name (30 CJK chars) → truncated correctly', () => {
      const thirtyChars = 'あいうえおかきくけこあいうえおかきくけこあいうえおかきくけこ';
      expect(thirtyChars.length).toBe(30);
      const folder = createFolder(store, thirtyChars)!;
      expect(folder.name).toBe(thirtyChars);
      expect(folder.name.length).toBe(30);

      // More than 30 characters gets truncated.
      const fortyChars = thirtyChars + 'あいうえおかきくけこ';
      const folder2 = createFolder(store, fortyChars)!;
      expect(folder2.name.length).toBe(30);
      expect(folder2.name).toBe(thirtyChars);
    });
  });


  describe('TC-22.2: empty states', () => {
    it('22.2.1: no folders → folder section hidden or shows guidance', () => {
      expect(store.getState().folders).toHaveLength(0);
    });

    it('22.2.2: all folders deleted → folder section disappears', () => {
      const f1 = createFolder(store, 'A')!;
      const f2 = createFolder(store, 'B')!;
      const f3 = createFolder(store, 'C')!;
      expect(store.getState().folders).toHaveLength(3);

      deleteFolder(store, f1.id);
      deleteFolder(store, f2.id);
      deleteFolder(store, f3.id);

      expect(store.getState().folders).toHaveLength(0);
    });

    it('22.2.3: empty folder expanded → shows prompt text (empty conversation list)', () => {
      const folder = createFolder(store, 'Empty')!;
      store.getState().toggleFolderExpand(folder.id);
      expect(store.getState().expandedFolderIds).toContain(folder.id);

      const conversations = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id);
      expect(conversations).toHaveLength(0);
    });
  });


  describe('TC-22.3: orphaned folderID handling', () => {
    it('22.3.1: conversation folderID points to non-existent folder → appears in time groups', () => {
      // Simulate synced data: a conversation carrying a folderID that does not exist locally.
      const conv = makeConversation({ id: 'orphan-sync', folderID: 'non-existent-folder-id' });
      store.getState().addConversation(conv);

      const folders = store.getState().folders; // empty
      expect(folders).toHaveLength(0);

      // Pass folders in so orphans can be detected.
      const groups = groupConversations(store.getState().conversations, folders);
      const allGrouped = groups.flatMap((g) => g.items);
      expect(allGrouped.find((c) => c.id === 'orphan-sync')).toBeDefined();
    });

    it('22.3.3: after orphan recovery (folderID cleared) → conversation back in time groups', () => {
      const conv = makeConversation({ id: 'orphan-recover', folderID: 'deleted-folder-id' });
      store.getState().addConversation(conv);

      // Clear folderID to recover the orphan.
      store.getState().updateConversation('orphan-recover', { folderID: undefined });

      const groups = groupConversations(store.getState().conversations);
      const allGrouped = groups.flatMap((g) => g.items);
      expect(allGrouped.find((c) => c.id === 'orphan-recover')).toBeDefined();
    });

    it('22.3.4: folder count excludes orphan references to deleted folders', () => {
      const folder = createFolder(store, 'Valid Folder')!;
      const c1 = makeConversation({ id: 'valid-1', folderID: folder.id, isDraft: false });
      const c2 = makeConversation({ id: 'orphan-ref', folderID: 'deleted-folder-xyz', isDraft: false });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);

      // The folder's valid count is 1; the orphan is not included.
      const validCount = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id && !c.isDraft).length;
      expect(validCount).toBe(1);

      // The orphan's folderID does not match any existing folder id.
      const orphan = store.getState().conversations.find((c) => c.id === 'orphan-ref');
      const existingFolderIds = store.getState().folders.map((f) => f.id);
      expect(existingFolderIds).not.toContain(orphan?.folderID);
    });
  });


  describe('TC-23.1: performance baselines', () => {
    it('23.1.1: collapsed folder does not render internal conversations (verify data filtering)', () => {
      const folder = createFolder(store, 'Collapsed')!;
      for (let i = 0; i < 20; i++) {
        store.getState().addConversation(
          makeConversation({ id: `col-${i}`, folderID: folder.id }),
        );
      }

      expect(store.getState().expandedFolderIds).not.toContain(folder.id);

      // Mirror the UI filter: a collapsed folder does not need its conversation list.
      const isExpanded = store.getState().expandedFolderIds.includes(folder.id);
      const visibleConversations = isExpanded
        ? store.getState().conversations.filter((c) => c.folderID === folder.id)
        : []; // collapsed returns empty and renders nothing

      expect(visibleConversations).toHaveLength(0);

      store.getState().toggleFolderExpand(folder.id);
      const expandedVisible = store.getState().expandedFolderIds.includes(folder.id)
        ? store.getState().conversations.filter((c) => c.folderID === folder.id)
        : [];
      expect(expandedVisible).toHaveLength(20);
    });

    it('23.1.4: batch move 50 conversations → store updates in single operation', () => {
      const folder = createFolder(store, 'Batch Target')!;
      const ids: string[] = [];
      for (let i = 0; i < 50; i++) {
        const id = `batch-perf-${i}`;
        ids.push(id);
        store.getState().addConversation(makeConversation({ id }));
      }

      // Track how many times setState is called.
      const setStateSpy = vi.spyOn(store, 'setState');

      batchMoveToFolder(store, ids, folder.id);

      // batchMoveToFolder should call setState once, not 50 times.
      expect(setStateSpy).toHaveBeenCalledTimes(1);

      const moved = store.getState().conversations.filter((c) => c.folderID === folder.id);
      expect(moved).toHaveLength(50);

      setStateSpy.mockRestore();
    });

    it('23.1.5: 50 folders + 500 conversations → store operations stay correct at scale', () => {
      const folderIds: string[] = [];
      for (let i = 0; i < 50; i++) {
        const f = createFolder(store, `Perf Folder ${i}`)!;
        folderIds.push(f.id);
      }

      // Spread them evenly across the folders.
      for (let i = 0; i < 500; i++) {
        const folderId = folderIds[i % 50];
        store.getState().addConversation(
          makeConversation({ id: `perf-conv-${i}`, folderID: folderId, isDraft: false }),
        );
      }

      expect(store.getState().folders).toHaveLength(50);
      expect(store.getState().conversations).toHaveLength(500);

      // The 500 conversations are spread evenly across the 50 folders by i % 50, exactly 10 each.
      for (const fId of folderIds) {
        const count = store
          .getState()
          .conversations.filter((c) => c.folderID === fId && !c.isDraft).length;
        expect(count).toBe(10); // 500 / 50 = 10
      }
      // Move 50 conversations into folder 0.
      const idsToMove = Array.from({ length: 50 }, (_, i) => `perf-conv-${i}`);
      batchMoveToFolder(store, idsToMove, folderIds[0]);

      // No wall-clock thresholds here: building and filtering 500 in-memory objects takes
      // single-digit milliseconds, so a one-second budget would only ever go red when the
      // machine running the tests is paging. Assert the batchMoveToFolder invariants instead.
      const byFolder = (fId: string) =>
        store.getState().conversations.filter((c) => c.folderID === fId && !c.isDraft).length;

      // perf-conv-0..49 are spread evenly by i % 50, so every folder gives up exactly one;
      // folder 0 keeps its own share and takes the other 49: 10 - 1 + 50 = 59.
      expect(byFolder(folderIds[0])).toBe(59);
      // The other 49 folders each lose one, dropping from 10 to 9.
      for (const fId of folderIds.slice(1)) {
        expect(byFolder(fId)).toBe(9);
      }
      // Moving must not add or drop conversations.
      expect(store.getState().conversations).toHaveLength(500);
    });

    it('TC-25.1.6: folders default to collapsed state', () => {
      const f1 = createFolder(store, 'Folder A')!;
      const f2 = createFolder(store, 'Folder B')!;
      const f3 = createFolder(store, 'Folder C')!;

      expect(store.getState().expandedFolderIds).not.toContain(f1.id);
      expect(store.getState().expandedFolderIds).not.toContain(f2.id);
      expect(store.getState().expandedFolderIds).not.toContain(f3.id);
      expect(store.getState().expandedFolderIds).toHaveLength(0);
    });

    it('TC-25.1.7: conversations in folder sorted by updatedAt descending', () => {
      const folder = createFolder(store, 'Sort Test')!;
      const c1 = makeConversation({ id: 'st1', folderID: folder.id, updatedAt: '2025-01-01T00:00:00Z' });
      const c2 = makeConversation({ id: 'st2', folderID: folder.id, updatedAt: '2025-06-15T12:00:00Z' });
      const c3 = makeConversation({ id: 'st3', folderID: folder.id, updatedAt: '2025-03-10T08:00:00Z' });
      const c4 = makeConversation({ id: 'st4', folderID: folder.id, updatedAt: '2025-12-31T23:59:59Z' });
      store.getState().addConversation(c1);
      store.getState().addConversation(c2);
      store.getState().addConversation(c3);
      store.getState().addConversation(c4);

      const sorted = store
        .getState()
        .conversations.filter((c) => c.folderID === folder.id)
        .sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime());

      expect(sorted[0].id).toBe('st4'); // newest, 2025-12-31
      expect(sorted[1].id).toBe('st2'); // 2025-06-15
      expect(sorted[2].id).toBe('st3'); // 2025-03-10
      expect(sorted[3].id).toBe('st1'); // oldest, 2025-01-01

      for (let i = 1; i < sorted.length; i++) {
        expect(new Date(sorted[i - 1].updatedAt).getTime())
          .toBeGreaterThanOrEqual(new Date(sorted[i].updatedAt).getTime());
      }
    });

    it('TC-25.1.8: draft conversations not counted in folder count', () => {
      const folder = createFolder(store, 'Draft Test')!;
      const normal1 = makeConversation({ id: 'dr1', folderID: folder.id, isDraft: false });
      const normal2 = makeConversation({ id: 'dr2', folderID: folder.id, isDraft: false });
      const normal3 = makeConversation({ id: 'dr3', folderID: folder.id, isDraft: false });
      const draft1 = makeConversation({ id: 'dr4', folderID: folder.id, isDraft: true, messages: [] });
      const draft2 = makeConversation({ id: 'dr5', folderID: folder.id, isDraft: true, messages: [] });
      store.getState().addConversation(normal1);
      store.getState().addConversation(normal2);
      store.getState().addConversation(normal3);
      store.getState().addConversation(draft1);
      store.getState().addConversation(draft2);

      // Total conversations in the folder = 5.
      const totalInFolder = store.getState().conversations.filter(
        (c) => c.folderID === folder.id,
      ).length;
      expect(totalInFolder).toBe(5);

      // Folder count excluding drafts = 3.
      const folderCount = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && !c.isDraft,
      ).length;
      expect(folderCount).toBe(3);

      const draftsInFolder = store.getState().conversations.filter(
        (c) => c.folderID === folder.id && c.isDraft,
      ).length;
      expect(draftsInFolder).toBe(2);
    });
  });

  // ── folder color ─────────────────────────────────────

  describe('folder color auto-assign', () => {
    it('first folder gets blue', () => {
      const folder = createFolder(store, 'First');
      expect(folder!.colorTag).toBe('blue');
    });

    it('sequential folders cycle through palette', () => {
      const expected = ['blue', 'purple', 'pink', 'red', 'orange',
        'yellow', 'green', 'teal', 'indigo', 'gray'];
      for (let i = 0; i < 10; i++) {
        createFolder(store, `Folder ${i}`);
      }
      const colors = store.getState().folders.map((f) => f.colorTag);
      expect(colors).toEqual(expected);
    });

    it('wraps around after 10th folder', () => {
      for (let i = 0; i < 11; i++) {
        createFolder(store, `Folder ${i}`);
      }
      expect(store.getState().folders[10].colorTag).toBe('blue');
    });
  });

  describe('updateFolderColor', () => {
    it('updates folder colorTag and syncs', () => {
      const folder = createFolder(store, 'Test')!;
      updateFolderColor(store, folder.id, 'red');
      expect(store.getState().folders[0].colorTag).toBe('red');
    });
  });

  describe('assignFolderColors (migration)', () => {
    it('assigns colors to folders with nil colorTag', () => {
      // Manually add folders without colorTag
      store.setState({
        folders: [
          { id: '1', name: 'A', sortOrder: 1000, createdAt: '', updatedAt: '' },
          { id: '2', name: 'B', sortOrder: 2000, createdAt: '', updatedAt: '' },
          { id: '3', name: 'C', sortOrder: 3000, createdAt: '', updatedAt: '' },
        ],
      });
      assignFolderColors(store);
      const colors = store.getState().folders.map((f) => f.colorTag);
      expect(colors).toEqual(['blue', 'purple', 'pink']);
    });

    it('preserves existing colorTags and continues rotation', () => {
      store.setState({
        folders: [
          { id: '1', name: 'A', sortOrder: 1000, colorTag: 'red', createdAt: '', updatedAt: '' },
          { id: '2', name: 'B', sortOrder: 2000, createdAt: '', updatedAt: '' },
          { id: '3', name: 'C', sortOrder: 3000, createdAt: '', updatedAt: '' },
        ],
      });
      assignFolderColors(store);
      const colors = store.getState().folders.map((f) => f.colorTag);
      expect(colors).toEqual(['red', 'orange', 'yellow']);
    });

    it('does nothing when all folders have colorTags', () => {
      store.setState({
        folders: [
          { id: '1', name: 'A', sortOrder: 1000, colorTag: 'blue', createdAt: '', updatedAt: '' },
        ],
      });
      const before = store.getState().folders[0].updatedAt;
      assignFolderColors(store);
      expect(store.getState().folders[0].updatedAt).toBe(before);
    });
  });
});
