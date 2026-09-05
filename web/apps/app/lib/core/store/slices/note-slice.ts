import {
  dedupeNotesByID,
  normalizeNoteIDs,
  normalizeUUID,
  sameNormalizedID,
} from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type NoteActions = Pick<
  AppActions,
  | 'setNotes'
  | 'setTrashedNotes'
  | 'addNote'
  | 'updateNote'
  | 'discardNote'
  | 'removeNote'
  | 'restoreNote'
  | 'emptyTrash'
  | 'clearLocallyDeletedNote'
>;

/**
 * Note slice: note CRUD plus a three-state trash, a path conversations do not have.
 *
 * - removeNote (soft delete into the trash): take it out of `notes`, stamp deletedAt and bump
 *   updatedAt, move it into `trashedNotes`, and add the id to `locallyDeletedNoteIds` so the
 *   server cannot write the old document back into notes.
 *   The record stays in IDB with its deletedAt and is persisted by the subscriber union; nothing
 *   is purged here.
 * - restoreNote: take it out of `trashedNotes`, clear deletedAt, bump updatedAt, put it back in
 *   `notes`, and remove the id from `locallyDeletedNoteIds`.
 * - emptyTrash (soft delete promoted to hard delete): clear `trashedNotes` (note-ops does the
 *   real IDB and remote deletion) and drop those ids from `locallyDeletedNoteIds`.
 *
 * Everything goes through normalizeUUID and sameNormalizedID, so ids are case-insensitive.
 */
export function createNoteSlice(set: AppStoreSet): NoteActions {
  return {
    setNotes: (notes) => set({ notes: dedupeNotesByID(notes) }),
    setTrashedNotes: (notes) => set({ trashedNotes: dedupeNotesByID(notes) }),
    addNote: (note) =>
      set((s) => ({ notes: [normalizeNoteIDs(note), ...s.notes] })),
    updateNote: (id, patch) =>
      set((s) => ({
        notes: s.notes.map((n) =>
          sameNormalizedID(n.id, id) ? normalizeNoteIDs({ ...n, ...patch }) : n,
        ),
      })),
    discardNote: (id) =>
      set((s) => {
        const normalizedId = normalizeUUID(id);
        const existed =
          s.notes.some((n) => sameNormalizedID(n.id, normalizedId)) ||
          s.trashedNotes.some((n) => sameNormalizedID(n.id, normalizedId));
        if (!existed) return s;
        return {
          notes: s.notes.filter((n) => !sameNormalizedID(n.id, normalizedId)),
          trashedNotes: s.trashedNotes.filter((n) => !sameNormalizedID(n.id, normalizedId)),
          locallyDeletedNoteIds: [
            ...s.locallyDeletedNoteIds.filter((existing) => !sameNormalizedID(existing, normalizedId)),
            normalizedId,
          ],
        };
      }),
    removeNote: (id, deletedAt) =>
      set((s) => {
        const target = s.notes.find((n) => sameNormalizedID(n.id, id));
        if (!target) return s;
        const normalizedId = normalizeUUID(id);
        const tombstone = normalizeNoteIDs({ ...target, deletedAt, updatedAt: deletedAt });
        return {
          notes: s.notes.filter((n) => !sameNormalizedID(n.id, id)),
          trashedNotes: [
            tombstone,
            ...s.trashedNotes.filter((n) => !sameNormalizedID(n.id, id)),
          ],
          locallyDeletedNoteIds: [
            ...s.locallyDeletedNoteIds.filter((existing) => !sameNormalizedID(existing, normalizedId)),
            normalizedId,
          ],
        };
      }),
    restoreNote: (id, updatedAt) =>
      set((s) => {
        const target = s.trashedNotes.find((n) => sameNormalizedID(n.id, id));
        if (!target) return s;
        const revived = normalizeNoteIDs({ ...target, deletedAt: undefined, updatedAt });
        return {
          trashedNotes: s.trashedNotes.filter((n) => !sameNormalizedID(n.id, id)),
          notes: [revived, ...s.notes.filter((n) => !sameNormalizedID(n.id, id))],
          locallyDeletedNoteIds: s.locallyDeletedNoteIds.filter(
            (existing) => !sameNormalizedID(existing, id),
          ),
        };
      }),
    emptyTrash: () =>
      set((s) => {
        if (s.trashedNotes.length === 0) return s;
        const trashedIds = new Set(s.trashedNotes.map((n) => normalizeUUID(n.id)));
        return {
          trashedNotes: [],
          locallyDeletedNoteIds: s.locallyDeletedNoteIds.filter(
            (existing) => !trashedIds.has(normalizeUUID(existing)),
          ),
        };
      }),
    clearLocallyDeletedNote: (id) =>
      set((s) => ({
        locallyDeletedNoteIds: s.locallyDeletedNoteIds.filter(
          (existing) => !sameNormalizedID(existing, id),
        ),
      })),
  };
}
