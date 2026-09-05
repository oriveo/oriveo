/**
 * subscribeNotes partition race and clearTimeout unsubscribe (idb/partition mocked with fake timers,
 * isolated from the real IDB tests). Also pins the union semantics: a soft delete moves rather than hard deletes, while emptyTrash hard deletes immediately.
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

const h = vi.hoisted(() => ({
  putNote: vi.fn(),
  deleteNote: vi.fn(),
  putNoteFolder: vi.fn(),
  deleteNoteFolder: vi.fn(),
  activeUID: 'user-A',
}));

vi.mock('../../../infra/storage/idb', () => ({
  putProvider: vi.fn(),
  deleteProvider: vi.fn(),
  putConversationPreservingHydratedMessages: vi.fn(),
  deleteConversation: vi.fn(),
  putFolder: vi.fn(),
  deleteFolder: vi.fn(),
  putNote: h.putNote,
  deleteNote: h.deleteNote,
  putNoteFolder: h.putNoteFolder,
  deleteNoteFolder: h.deleteNoteFolder,
  setSessionValue: vi.fn(),
}));
vi.mock('../../../infra/storage/image-store', () => ({ deleteImage: vi.fn() }));
vi.mock('../../../infra/storage/preferences', () => ({ setPreference: vi.fn(), removePreference: vi.fn() }));
vi.mock('../../../infra/storage/partition', () => ({ getActiveUIDSync: () => h.activeUID }));
vi.mock('../../sync-port', () => ({ getSyncAdapter: () => null }));

import { createAppStore } from '../app-store';
import { subscribeNotes, subscribeNoteFolders } from '../persistence-subscribers';
import type { Note, NoteFolder } from '@oriveo/shared';

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

beforeEach(() => {
  vi.clearAllMocks();
  h.activeUID = 'user-A';
  vi.useFakeTimers();
});
afterEach(() => { vi.useRealTimers(); });

describe('subscribeNotes partition race', () => {
  it('activeUID changing during the debounce discards the write, preventing cross-account leakage', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeNotes(store);

    h.activeUID = 'user-A';
    store.getState().addNote(makeNote({ id: 'n1' }));
    h.activeUID = 'guest'; // after scheduling, before the debounce fires
    vi.advanceTimersByTime(600);

    expect(h.putNote).not.toHaveBeenCalled();
    unsub();
  });

  it('activeUID unchanged during the debounce writes normally (control)', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeNotes(store);

    store.getState().addNote(makeNote({ id: 'n1' }));
    vi.advanceTimersByTime(600);

    expect(h.putNote).toHaveBeenCalledTimes(1);
    unsub();
  });

  it('unsubscribing clears the pending debounce so nothing is written', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeNotes(store);

    store.getState().addNote(makeNote({ id: 'n1' }));
    unsub();
    vi.advanceTimersByTime(600);

    expect(h.putNote).not.toHaveBeenCalled();
  });

  it('does not write while hydrationPhase is not ready', () => {
    const store = createAppStore();
    const unsub = subscribeNotes(store); // booting by default
    store.getState().addNote(makeNote({ id: 'n1' }));
    vi.advanceTimersByTime(600);
    expect(h.putNote).not.toHaveBeenCalled();
    unsub();
  });
});

describe('subscribeNotes union semantics', () => {
  it('a soft delete moving active to trash stays in the union and upserts rather than hard deleting', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeNotes(store);

    store.getState().addNote(makeNote({ id: 'n1' }));
    vi.advanceTimersByTime(600); // persisted, prev=[n1]
    h.putNote.mockClear();

    store.getState().removeNote('n1', '2026-06-19T11:00:00.000Z');
    vi.advanceTimersByTime(600);

    expect(h.deleteNote).not.toHaveBeenCalled(); // no hard delete
    expect(h.putNote).toHaveBeenCalledTimes(1); // upsert carrying deletedAt
    unsub();
  });

  it('emptyTrash leaves the union and hard deletes immediately without debouncing', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeNotes(store);

    store.getState().addNote(makeNote({ id: 'n1' }));
    vi.advanceTimersByTime(600);
    store.getState().removeNote('n1', '2026-06-19T11:00:00.000Z');
    vi.advanceTimersByTime(600); // prev=[n1(deleted)]
    h.deleteNote.mockClear();

    store.getState().emptyTrash();
    // Deletion is handled synchronously, so no timer needs to advance
    expect(h.deleteNote).toHaveBeenCalledWith('n1');
    unsub();
  });
});

describe('subscribeNoteFolders', () => {
  it('an addition puts immediately and a removal deletes immediately', () => {
    const store = createAppStore();
    store.setState({ hydrationPhase: 'ready' });
    const unsub = subscribeNoteFolders(store);

    store.getState().addNoteFolder(makeNoteFolder({ id: 'f1' }));
    expect(h.putNoteFolder).toHaveBeenCalledTimes(1);

    store.getState().removeNoteFolder('f1');
    expect(h.deleteNoteFolder).toHaveBeenCalledWith('f1');
    unsub();
  });
});
