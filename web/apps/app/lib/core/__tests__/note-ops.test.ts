import { describe, it, expect, beforeEach, vi } from 'vitest';
import { createAppStore } from '../store/app-store';
import {
  createNote,
  replaceNote,
  updateNoteBody,
  updateNoteUserNote,
  updateNoteTitle,
  updateNoteTags,
  toggleNotePin,
  discardEmptyBlankNote,
  deleteNote,
  restoreNote,
  emptyTrash,
  moveNoteToFolder,
  createNoteFolder,
  renameNoteFolder,
  deleteNoteFolder,
} from '../note-ops';

type TestSyncAdapter = {
  didCreateNote: ReturnType<typeof vi.fn>;
  didUpdateNote?: ReturnType<typeof vi.fn>;
  didEmptyTrashNotes?: ReturnType<typeof vi.fn>;
};
const mockGetSyncAdapter = vi.fn<() => TestSyncAdapter | null>(() => null);

// Neutralise the sync adapter (the free path, with no adapter): by default these ops only assert the store side
vi.mock('../sync-port', () => ({
  getSyncAdapter: () => mockGetSyncAdapter(),
}));

describe('note-ops', () => {
  let store: ReturnType<typeof createAppStore>;
  beforeEach(() => {
    store = createAppStore();
    mockGetSyncAdapter.mockClear();
    mockGetSyncAdapter.mockReturnValue(null);
  });

  describe('createNote', () => {
    it('placeholder title is the first non-empty body line, with titleSource=placeholder', () => {
      const note = createNote(store, { body: 'First line\nSecond line', captureKind: 'fullAnswer' });
      expect(note.title).toBe('First line');
      expect(note.titleSource).toBe('placeholder');
      expect(store.getState().notes).toHaveLength(1);
      expect(store.getState().notes[0].id).toBe(note.id);
    });

    it('a given title sets titleSource=manual', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank', title: 'My title' });
      expect(note.title).toBe('My title');
      expect(note.titleSource).toBe('manual');
    });

    it('skips leading blank lines when deriving the placeholder title', () => {
      const note = createNote(store, { body: '\n\n Body text', captureKind: 'blank' });
      expect(note.title).toBe('Body text');
    });

    it('table body: the placeholder title takes a clean first row, dropping pipes and skipping the separator line, so no markdown structure characters remain', () => {
      const note = createNote(store, {
        body: '| Chinese | English |\n|------|------|\n| Hello | hello |',
        captureKind: 'selection',
      });
      expect(note.title).toBe('Chinese English');
    });

    it('heading and list bodies: the placeholder title strips markdown structure characters', () => {
      expect(createNote(store, { body: '## My hometown\nBody text', captureKind: 'fullAnswer' }).title).toBe('My hometown');
      expect(createNote(store, { body: '- First item\n- Second item', captureKind: 'fullAnswer' }).title).toBe('First item');
    });

    it('the placeholder title prefers sourcePrompt, the original question, over the first answer line', () => {
      const note = createNote(store, {
        body: '| Chinese | English |\n|------|------|\n| Hello | hello |',
        captureKind: 'selection',
        sourcePrompt: 'Translate this passage into English for me',
      });
      expect(note.title).toBe('Translate this passage into English for me');
      expect(note.titleSource).toBe('placeholder');
    });

    it('falls back to the first body line when there is no sourcePrompt', () => {
      const note = createNote(store, { body: 'Answer first line\nMore', captureKind: 'fullAnswer' });
      expect(note.title).toBe('Answer first line');
    });

    it('a cross-check note without sourcePrompt skips the internal Original answer section when deriving the title', () => {
      const note = createNote(store, {
        body: '## Original answer\n\nOld answer\n\n## Cross-check (GPT-5)\n\nHere is the cross-check conclusion',
        bodySnapshot: 'Old answer',
        captureKind: 'fullAnswer',
      });

      expect(note.title).toBe('Here is the cross-check conclusion');
    });

    it('tags default to an empty array rather than undefined', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      expect(note.tags).toEqual([]);
    });

    it('an empty manual note is discarded silently on exit and never reaches the trash', () => {
      const adapter = { didCreateNote: vi.fn(), didEmptyTrashNotes: vi.fn() };
      mockGetSyncAdapter.mockReturnValue(adapter);
      const note = createNote(store, { body: '', captureKind: 'blank' });
      adapter.didCreateNote.mockClear();

      const discarded = discardEmptyBlankNote(store, note.id);

      expect(discarded).toBe(true);
      expect(store.getState().notes).toHaveLength(0);
      expect(store.getState().trashedNotes).toHaveLength(0);
      expect(adapter.didEmptyTrashNotes).toHaveBeenCalledWith([note.id]);
    });

    it('a blank note that has content is not auto-discarded', () => {
      const adapter = { didCreateNote: vi.fn(), didEmptyTrashNotes: vi.fn() };
      mockGetSyncAdapter.mockReturnValue(adapter);
      const note = createNote(store, { body: 'user content', captureKind: 'blank' });
      adapter.didCreateNote.mockClear();

      const discarded = discardEmptyBlankNote(store, note.id);

      expect(discarded).toBe(false);
      expect(store.getState().notes).toHaveLength(1);
      expect(adapter.didEmptyTrashNotes).not.toHaveBeenCalled();
    });
  });

  describe('updateNoteBody', () => {
    it('the placeholder title follows the first body line as it changes', () => {
      const note = createNote(store, { body: 'old', captureKind: 'blank' });
      updateNoteBody(store, note.id, 'new title line\nbody');
      const updated = store.getState().notes[0];
      expect(updated.body).toBe('new title line\nbody');
      expect(updated.title).toBe('new title line');
    });

    it('a manual title is not overwritten by the body', () => {
      const note = createNote(store, { body: 'old', captureKind: 'blank', title: 'Fixed title' });
      updateNoteBody(store, note.id, 'changed body');
      const updated = store.getState().notes[0];
      expect(updated.title).toBe('Fixed title');
      expect(updated.body).toBe('changed body');
    });

    it('with a sourcePrompt the placeholder title stays locked to the question, and editing the body does not replace it with the first answer line', () => {
      const note = createNote(store, {
        body: 'Old answer',
        captureKind: 'fullAnswer',
        sourcePrompt: 'My question',
      });
      expect(note.title).toBe('My question');
      updateNoteBody(store, note.id, 'New answer first line\nMore');
      const updated = store.getState().notes[0];
      expect(updated.title).toBe('My question');
      expect(updated.body).toBe('New answer first line\nMore');
    });
  });

  describe('replaceNote', () => {
    it('keeps the curated fields, updates body, source and snapshot, and clears the old provenance', () => {
      const adapter = { didCreateNote: vi.fn(), didUpdateNote: vi.fn() };
      mockGetSyncAdapter.mockReturnValue(adapter);
      const original = createNote(store, {
        title: 'Manual title',
        body: 'Old body',
        bodySnapshot: 'Old full answer',
        captureKind: 'fullAnswer',
        tags: ['keep'],
        noteFolderID: '22222222-2222-4222-8222-222222222222',
        sourceConversationId: '33333333-3333-4333-8333-333333333333',
        sourceMessageId: '44444444-4444-4444-8444-444444444444',
        sourceModelID: 'gpt-5',
        sourceModelName: 'GPT-5',
        sourceProviderKind: 'openAI',
        sourceProviderName: 'OpenAI',
        sourcePrompt: 'Old prompt',
        provenance: [
          {
            kind: 'origin',
            modelID: 'gpt-5',
            modelName: 'GPT-5',
            providerKind: 'openAI',
            providerName: 'OpenAI',
            conversationId: '33333333-3333-4333-8333-333333333333',
            messageId: '44444444-4444-4444-8444-444444444444',
            at: '2026-06-01T00:00:00.000Z',
          },
          {
            kind: 'crosscheck',
            modelID: 'claude',
            modelName: 'Claude',
            providerKind: 'anthropic',
            providerName: 'Anthropic',
            at: '2026-06-01T00:01:00.000Z',
          },
        ],
        isPinned: true,
      });
      adapter.didCreateNote.mockClear();

      const replaced = replaceNote(store, original.id, {
        body: 'Selected replacement',
        bodySnapshot: 'Full replacement answer',
        captureKind: 'selection',
        tags: ['should-not-copy'],
        noteFolderID: '55555555-5555-4555-8555-555555555555',
        sourceConversationId: '66666666-6666-4666-8666-666666666666',
        sourceMessageId: '77777777-7777-4777-8777-777777777777',
        sourceModelID: 'claude-3-5',
        sourceModelName: 'Claude 3.5',
        sourceProviderKind: 'anthropic',
        sourceProviderName: 'Anthropic',
        sourcePrompt: 'New prompt',
        provenance: [
          {
            kind: 'origin',
            modelID: 'unused',
            at: '2026-06-02T00:00:00.000Z',
          },
        ],
      });

      expect(replaced?.id).toBe(original.id);
      expect(replaced?.createdAt).toBe(original.createdAt);
      expect(replaced?.title).toBe('Manual title');
      expect(replaced?.titleSource).toBe('manual');
      expect(replaced?.body).toBe('Selected replacement');
      expect(replaced?.bodySnapshot).toBe('Full replacement answer');
      expect(replaced?.tags).toEqual(['keep']);
      expect(replaced?.noteFolderID).toBe('22222222-2222-4222-8222-222222222222');
      expect(replaced?.isPinned).toBe(true);
      expect(replaced?.captureKind).toBe('selection');
      expect(replaced?.sourceConversationId).toBe('66666666-6666-4666-8666-666666666666');
      expect(replaced?.sourceMessageId).toBe('77777777-7777-4777-8777-777777777777');
      expect(replaced?.sourceModelID).toBe('claude-3-5');
      expect(replaced?.sourceModelName).toBe('Claude 3.5');
      expect(replaced?.sourceProviderKind).toBe('anthropic');
      expect(replaced?.sourceProviderName).toBe('Anthropic');
      expect(replaced?.sourcePrompt).toBe('New prompt');
      expect(replaced?.provenance).toBeUndefined();
      expect(adapter.didUpdateNote).toHaveBeenCalledWith(original.id, expect.objectContaining({
        body: 'Selected replacement',
        bodySnapshot: 'Full replacement answer',
        captureKind: 'selection',
        sourceConversationId: '66666666-6666-4666-8666-666666666666',
        sourceMessageId: '77777777-7777-4777-8777-777777777777',
        provenance: undefined,
      }));
    });
  });

  describe('updateNoteTitle / toggleNotePin', () => {
    it('updateNoteTitle sets manual', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      updateNoteTitle(store, note.id, 'Edited title');
      expect(store.getState().notes[0].title).toBe('Edited title');
      expect(store.getState().notes[0].titleSource).toBe('manual');
    });

    it('toggleNotePin flips the flag', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      toggleNotePin(store, note.id);
      expect(store.getState().notes[0].isPinned).toBe(true);
      toggleNotePin(store, note.id);
      expect(store.getState().notes[0].isPinned).toBe(false);
    });
  });

  describe('editing the user note and tags', () => {
    it('updateNoteUserNote only updates the user note, leaving body and title alone', () => {
      const note = createNote(store, { body: 'Body title\nBody text', captureKind: 'blank' });

      updateNoteUserNote(store, note.id, 'Take another look before release');

      const updated = store.getState().notes[0];
      expect(updated.title).toBe('Body title');
      expect(updated.body).toBe('Body title\nBody text');
      expect(updated.userNote).toBe('Take another look before release');
    });

    it('updateNoteTags writes the whole tag array', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });

      updateNoteTags(store, note.id, ['release', 'vector']);

      expect(store.getState().notes[0].tags).toEqual(['release', 'vector']);
    });
  });

  describe('unlimited locally when no sync adapter is installed', () => {
    it('without a sync adapter, creating several notes writes locally only and triggers no cloud write', () => {
      createNote(store, { body: 'first', captureKind: 'blank' });
      createNote(store, { body: 'second', captureKind: 'blank' });

      expect(store.getState().notes.map((note) => note.body)).toEqual(['second', 'first']);
      expect(mockGetSyncAdapter).toHaveBeenCalledTimes(2);
    });

    it('with a sync adapter, creating a note triggers a cloud sync write', () => {
      const adapter = { didCreateNote: vi.fn() };
      mockGetSyncAdapter.mockReturnValue(adapter);

      const note = createNote(store, { body: 'pro note', captureKind: 'blank' });

      expect(adapter.didCreateNote).toHaveBeenCalledWith(note);
    });

    it('source ids are normalised before the note is written locally and synced', () => {
      const adapter = { didCreateNote: vi.fn() };
      mockGetSyncAdapter.mockReturnValue(adapter);

      const note = createNote(store, {
        body: 'pro note',
        captureKind: 'fullAnswer',
        sourceConversationId: 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa',
        sourceMessageId: 'bbbbbbbb-bbbb-4bbb-abbb-bbbbbbbbbbbb',
      });

      expect(note.sourceConversationId).toBe('AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA');
      expect(note.sourceMessageId).toBe('BBBBBBBB-BBBB-4BBB-ABBB-BBBBBBBBBBBB');
      expect(store.getState().notes[0].sourceConversationId).toBe('AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA');
      expect(adapter.didCreateNote).toHaveBeenCalledWith(
        expect.objectContaining({
          sourceConversationId: 'AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA',
          sourceMessageId: 'BBBBBBBB-BBBB-4BBB-ABBB-BBBBBBBBBBBB',
        }),
      );
    });
  });

  describe('the three trash states', () => {
    it('deleteNote moves the note out of notes into trashedNotes and sets locallyDeletedNoteIds and deletedAt', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      deleteNote(store, note.id);
      const s = store.getState();
      expect(s.notes).toHaveLength(0);
      expect(s.trashedNotes.map((n) => n.id)).toEqual([note.id]);
      expect(s.trashedNotes[0].deletedAt).toBeTruthy();
      expect(s.locallyDeletedNoteIds).toContain(note.id);
    });

    it('restoreNote moves it back into notes, clears deletedAt and drops the guard', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      deleteNote(store, note.id);
      restoreNote(store, note.id);
      const s = store.getState();
      expect(s.notes.map((n) => n.id)).toEqual([note.id]);
      expect(s.notes[0].deletedAt).toBeUndefined();
      expect(s.trashedNotes).toHaveLength(0);
      expect(s.locallyDeletedNoteIds).not.toContain(note.id);
    });

    it('after a restore, updatedAt is later than the delete time so LWW beats the delete', () => {
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      deleteNote(store, note.id);
      const deletedAt = store.getState().trashedNotes[0].deletedAt!;
      restoreNote(store, note.id);
      const restoredUpdatedAt = store.getState().notes[0].updatedAt;
      expect(Date.parse(restoredUpdatedAt)).toBeGreaterThanOrEqual(Date.parse(deletedAt));
    });

    it('emptyTrash clears trashedNotes and the guards', () => {
      const a = createNote(store, { body: 'a', captureKind: 'blank' });
      const b = createNote(store, { body: 'b', captureKind: 'blank' });
      deleteNote(store, a.id);
      deleteNote(store, b.id);
      expect(store.getState().trashedNotes).toHaveLength(2);
      emptyTrash(store);
      expect(store.getState().trashedNotes).toHaveLength(0);
      expect(store.getState().locallyDeletedNoteIds).toHaveLength(0);
    });
  });

  describe('note folders', () => {
    it('createNoteFolder spaces sortOrder in steps of 1000', () => {
      const f1 = createNoteFolder(store, 'A');
      const f2 = createNoteFolder(store, 'B');
      expect(f1?.sortOrder).toBe(1000);
      expect(f2?.sortOrder).toBe(2000);
      expect(store.getState().noteFolders).toHaveLength(2);
    });

    it('an empty name returns null', () => {
      expect(createNoteFolder(store, '   ')).toBeNull();
      expect(store.getState().noteFolders).toHaveLength(0);
    });

    it('renameNoteFolder', () => {
      const f = createNoteFolder(store, 'Old')!;
      renameNoteFolder(store, f.id, 'New');
      expect(store.getState().noteFolders[0].name).toBe('New');
    });

    it('moveNoteToFolder sets and clears the folder', () => {
      const f = createNoteFolder(store, 'F')!;
      const note = createNote(store, { body: 'x', captureKind: 'blank' });
      moveNoteToFolder(store, note.id, f.id);
      expect(store.getState().notes[0].noteFolderID).toBe(f.id);
      moveNoteToFolder(store, note.id, null);
      expect(store.getState().notes[0].noteFolderID).toBeUndefined();
    });

    it('deleteNoteFolder cascades the note.noteFolderID cleanup, including the trash', () => {
      const f = createNoteFolder(store, 'F')!;
      const active = createNote(store, { body: 'a', captureKind: 'blank', noteFolderID: f.id });
      const toTrash = createNote(store, { body: 'b', captureKind: 'blank', noteFolderID: f.id });
      deleteNote(store, toTrash.id);
      deleteNoteFolder(store, f.id);
      const s = store.getState();
      expect(s.noteFolders).toHaveLength(0);
      expect(s.notes.find((n) => n.id === active.id)?.noteFolderID).toBeUndefined();
      expect(s.trashedNotes.find((n) => n.id === toTrash.id)?.noteFolderID).toBeUndefined();
    });
  });
});
