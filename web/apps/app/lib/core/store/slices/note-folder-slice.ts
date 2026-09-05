import { sameNormalizedID } from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type NoteFolderActions = Pick<
  AppActions,
  | 'setNoteFolders'
  | 'addNoteFolder'
  | 'updateNoteFolder'
  | 'removeNoteFolder'
  | 'reorderNoteFolders'
  | 'toggleNoteFolderExpand'
>;

/**
 * NoteFolder slice: note folder CRUD plus expansion state, mirroring folder-slice.
 * removeNoteFolder is a cross-domain cascade in a single atomic set(): it clears the noteFolderID
 * from both notes and trashedNotes that point at this folder, so those notes return to "uncategorised",
 * and clears the expansion state. The store only holds active note folders; the soft-delete tombstone
 * lives remotely alone (writeDeleteNoteFolder writes deletedAt) and is never kept locally.
 */
export function createNoteFolderSlice(set: AppStoreSet): NoteFolderActions {
  return {
    setNoteFolders: (folders) => set({ noteFolders: folders }),
    addNoteFolder: (folder) =>
      set((s) => ({ noteFolders: [...s.noteFolders, folder] })),
    updateNoteFolder: (id, patch) =>
      set((s) => ({
        noteFolders: s.noteFolders.map((f) => (f.id === id ? { ...f, ...patch } : f)),
      })),
    removeNoteFolder: (id) =>
      set((s) => ({
        noteFolders: s.noteFolders.filter((f) => f.id !== id),
        notes: s.notes.map((n) =>
          n.noteFolderID === id ? { ...n, noteFolderID: undefined } : n,
        ),
        trashedNotes: s.trashedNotes.map((n) =>
          n.noteFolderID === id ? { ...n, noteFolderID: undefined } : n,
        ),
        expandedNoteFolderIds: s.expandedNoteFolderIds.filter((fid) => fid !== id),
      })),
    reorderNoteFolders: (folders) => set({ noteFolders: folders }),
    toggleNoteFolderExpand: (id) =>
      set((s) => ({
        expandedNoteFolderIds: s.expandedNoteFolderIds.includes(id)
          ? s.expandedNoteFolderIds.filter((fid) => fid !== id)
          : [...s.expandedNoteFolderIds, id],
      })),
  };
}
