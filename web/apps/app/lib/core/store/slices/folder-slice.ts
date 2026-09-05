import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type FolderActions = Pick<
  AppActions,
  'setFolders' | 'addFolder' | 'updateFolder' | 'removeFolder' | 'reorderFolders' | 'toggleFolderExpand'
>;

/**
 * Folder slice: folder CRUD plus expansion state.
 * removeFolder cascades across domains in a single atomic set(), also clearing the folderID on any
 * conversation that pointed at the removed folder.
 */
export function createFolderSlice(set: AppStoreSet): FolderActions {
  return {
    setFolders: (folders) => set({ folders }),
    addFolder: (folder) =>
      set((s) => ({ folders: [...s.folders, folder] })),
    updateFolder: (id, patch) =>
      set((s) => ({
        folders: s.folders.map((f) => (f.id === id ? { ...f, ...patch } : f)),
      })),
    removeFolder: (id) =>
      set((s) => ({
        folders: s.folders.filter((f) => f.id !== id),
        conversations: s.conversations.map((c) =>
          c.folderID === id ? { ...c, folderID: undefined } : c,
        ),
        expandedFolderIds: s.expandedFolderIds.filter((fid) => fid !== id),
      })),
    reorderFolders: (folders) => set({ folders }),
    toggleFolderExpand: (id) =>
      set((s) => ({
        expandedFolderIds: s.expandedFolderIds.includes(id)
          ? s.expandedFolderIds.filter((fid) => fid !== id)
          : [...s.expandedFolderIds, id],
      })),
  };
}
