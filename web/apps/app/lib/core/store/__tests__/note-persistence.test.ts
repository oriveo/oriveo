import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { openDB } from 'idb';
import { createAppStore } from '../app-store';
import { hydrateStore, subscribeToChanges } from '../persistence';
import {
  DB_VERSION,
  putNote,
  getNoteById,
  getAllNotes,
  putNoteFolder,
  getAllNoteFolders,
  resetDBConnection,
} from '../../../infra/storage/idb';
import { resetImageDBConnection } from '../../../infra/storage/image-store';
import { setActiveUID, getDBName } from '../../../infra/storage/partition';
import type { Note, NoteFolder } from '@oriveo/shared';

// The sync adapter takes no part in local persistence tests.
vi.mock('../../sync-port', () => ({
  getSyncAdapter: () => null,
  createSyncAdapter: vi.fn(),
  destroySyncAdapter: vi.fn(),
}));

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

function makeNote(overrides: Partial<Note> = {}): Note {
  return {
    id: 'n1',
    title: 'T',
    titleSource: 'placeholder',
    body: 'B',
    tags: [],
    captureKind: 'blank',
    createdAt: '2026-06-19T09:00:00.000Z',
    updatedAt: '2026-06-19T10:00:00.000Z',
    ...overrides,
  };
}

function makeNoteFolder(overrides: Partial<NoteFolder> = {}): NoteFolder {
  return {
    id: 'f1',
    name: 'Inbox',
    sortOrder: 1000,
    createdAt: '2026-06-19T09:00:00.000Z',
    updatedAt: '2026-06-19T10:00:00.000Z',
    ...overrides,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('note-persistence', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
    localStorage.clear();
  });

  describe('hydrateStore routes by deletedAt', () => {
    it('puts active notes in notes and tombstones in trashedNotes', async () => {
      await putNote(makeNote({ id: 'active1' }));
      await putNote(makeNote({ id: 'trash1', deletedAt: '2026-06-19T11:00:00.000Z' }));

      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().notes.map((n) => n.id)).toEqual(['active1']);
      expect(store.getState().trashedNotes.map((n) => n.id)).toEqual(['trash1']);
    });

    it('filters tombstones out of noteFolders and keeps only active ones', async () => {
      await putNoteFolder(makeNoteFolder({ id: 'f1' }));
      await putNoteFolder(makeNoteFolder({ id: 'f2', deletedAt: '2026-06-19T11:00:00.000Z' }));

      const store = createAppStore();
      await hydrateStore(store);

      expect(store.getState().noteFolders.map((f) => f.id)).toEqual(['f1']);
    });
  });

  describe('IDB v5', () => {
    it('has readable and writable notes / noteFolders stores at DB version 5', async () => {
      await putNote(makeNote({ id: 'x' }));
      await putNoteFolder(makeNoteFolder({ id: 'fx' }));

      expect(await getAllNotes()).toHaveLength(1);
      expect(await getAllNoteFolders()).toHaveLength(1);

      const db = await openDB(getDBName('guest'));
      expect(db.version).toBe(DB_VERSION);
      const stores = Array.from(db.objectStoreNames);
      expect(stores).toContain('notes');
      expect(stores).toContain('noteFolders');
      db.close();
    });
  });

  describe('subscribeNotes union persistence', () => {
    it('writes a new note to IDB after the debounce', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().addNote(makeNote({ id: 'new1' }));
      await wait(600);

      expect(await getNoteById('new1')).toBeDefined();
      unsub();
    });

    it('keeps the record in IDB on a soft delete, with deletedAt set so the trash can restore it', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().addNote(makeNote({ id: 'n1' }));
      await wait(600);
      store.getState().removeNote('n1', new Date().toISOString());
      await wait(600);

      const persisted = await getNoteById('n1');
      expect(persisted).toBeDefined();
      expect(persisted?.deletedAt).toBeTruthy();
      expect(store.getState().trashedNotes.map((n) => n.id)).toEqual(['n1']);
      unsub();
    });

    it('hard deletes from IDB immediately when emptyTrash removes it from the union', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().addNote(makeNote({ id: 'n1' }));
      await wait(600);
      store.getState().removeNote('n1', new Date().toISOString());
      await wait(600);
      expect(await getNoteById('n1')).toBeDefined();

      store.getState().emptyTrash();
      await wait(50); // Deletions are handled immediately, without debounce.

      expect(await getNoteById('n1')).toBeUndefined();
      unsub();
    });

    it('gates on hydrationPhase: a note added while booting is not written to IDB', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      // Stay in booting; hydrate does not change the phase.
      const unsub = subscribeToChanges(store);

      store.getState().addNote(makeNote({ id: 'gated' }));
      await wait(600);

      expect(await getNoteById('gated')).toBeUndefined();
      unsub();
    });
  });

  describe('subscribeNoteFolders', () => {
    it('writes a new note folder to IDB immediately and removes it immediately on delete', async () => {
      const store = createAppStore();
      await hydrateStore(store);
      store.setState({ hydrationPhase: 'ready' });
      const unsub = subscribeToChanges(store);

      store.getState().addNoteFolder(makeNoteFolder({ id: 'f1' }));
      await wait(50);
      expect((await getAllNoteFolders()).map((f) => f.id)).toEqual(['f1']);

      store.getState().removeNoteFolder('f1');
      await wait(50);
      expect(await getAllNoteFolders()).toHaveLength(0);
      unsub();
    });
  });
});
