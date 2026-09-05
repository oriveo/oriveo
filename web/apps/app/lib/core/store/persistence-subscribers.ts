import type { StoreApi } from 'zustand';
import type { Conversation } from '@oriveo/shared';
import type { AppStore } from './app-store';
import {
  putProvider,
  deleteProvider,
  putConversationPreservingHydratedMessages,
  deleteConversation,
  putFolder,
  deleteFolder as idbDeleteFolder,
  putNote,
  deleteNote as idbDeleteNote,
  putNoteFolder,
  deleteNoteFolder as idbDeleteNoteFolder,
  setSessionValue,
} from '../../infra/storage/idb';
import { deleteImage } from '../../infra/storage/image-store';
import { setPreference, removePreference } from '../../infra/storage/preferences';
import { getActiveUIDSync } from '../../infra/storage/partition';
import { normalizeUUID } from '../../utils/id-utils';
import { getSyncAdapter } from '../sync-port';
import { withErrorReporting } from '../../sentry/report-silent';

/* ── Tuning constants ─────────────────────────────────────────── */

/** Debounce for writing conversations back to IDB: during high-frequency token streaming, flush once after 500ms of quiet. */
const CONVERSATION_PERSIST_DEBOUNCE_MS = 500;
/** Debounce for writing notes back to IDB: while the body is edited keystroke by keystroke, flush once after 500ms of quiet. */
const NOTE_PERSIST_DEBOUNCE_MS = 500;
/** Throttle window for notifying the sync port of pin changes: rapid toggles collapse into a single trailing push. */
const PIN_PUSH_THROTTLE_MS = 1000;

/* ── Per-domain subscribers ───────────────────────────────────── */
//
// Each subscriber:
//   1. holds its own prev reference (zustand reference equality is enough to detect no change);
//   2. applies its own hydrationPhase gate: before ready it refreshes prev and skips persisting,
//      so clearing state during bootstrap is not mistaken for a user delete;
//   3. returns its own cleanup, timer teardown included.
// persistence.ts composes them in subscribeToChanges.

export function subscribeProviders(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().providers;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.providers;
      return;
    }
    if (state.providers === prev) return;
    const current = new Set(state.providers.map((p) => p.id));
    const prevMap = new Map(prev.map((p) => [p.id, p]));
    // Added or updated
    for (const p of state.providers) {
      const old = prevMap.get(p.id);
      if (!old || old !== p) putProvider(p);
    }
    // Deleted
    for (const p of prev) {
      if (!current.has(p.id)) deleteProvider(p.id);
    }
    prev = state.providers;
  });
}

export function subscribeConversations(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().conversations;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const unsub = store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.conversations;
      return;
    }
    if (state.conversations === prev) return;
    const current = new Set(state.conversations.map((c) => c.id));
    const deleted = prev.filter((c) => !current.has(c.id));
    if (deleted.length > 0) {
      for (const c of deleted) {
        deleteConversation(c.id);
        cleanupConversationImages(c);
      }
      prev = prev.filter((c) => current.has(c.id));
    }
    if (timer) clearTimeout(timer);
    // Record the activeUID at schedule time: signing out mid-stream makes abortAllStreams
    // update the store synchronously and trigger this debounce, and the partition switches to
    // guest right after. If the partition changed before the timer fired, writing would put the
    // previous account's whole conversation into the guest partition, so drop the stale write.
    const scheduledUID = getActiveUIDSync();
    timer = setTimeout(() => {
      if (getActiveUIDSync() !== scheduledUID) {
        // The partition already switched, so drop this write; writes to the new partition belong to the subscriber created by resubscribe
        return;
      }
      const prevMap = new Map(prev.map((c) => [c.id, c]));
      for (const c of state.conversations) {
        const old = prevMap.get(c.id);
        if (!old || old !== c) {
          void putConversationPreservingHydratedMessages(c)
            .catch(withErrorReporting('storage.conversation.persist'));
        }
      }
      prev = state.conversations;
    }, CONVERSATION_PERSIST_DEBOUNCE_MS);
  });
  // Clear the pending debounce on unmount or partition switch, so a stale write cannot land in the wrong partition or after teardown
  return () => {
    unsub();
    if (timer) clearTimeout(timer);
  };
}

export function subscribePreferences(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().preferences;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.preferences;
      return;
    }
    if (state.preferences === prev) return;
    setPreference('preferences', state.preferences);
    prev = state.preferences;
  });
}

export function subscribeOnboarding(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().hasCompletedOnboarding;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.hasCompletedOnboarding;
      return;
    }
    if (state.hasCompletedOnboarding === prev) return;
    setPreference('hasCompletedOnboarding', state.hasCompletedOnboarding);
    prev = state.hasCompletedOnboarding;
  });
}

export function subscribePinned(store: StoreApi<AppStore>): () => void {
  let prevPinned = store.getState().pinnedConversationIds;
  let prevPinnedUpdatedAt = store.getState().pinnedConversationIdsUpdatedAt;

  // Cloud pushes are throttled (leading plus trailing); a local setPreference still persists immediately
  let lastPushAt = 0;
  let pushTimer: ReturnType<typeof setTimeout> | null = null;
  let pendingPayload: { pinnedConversationIds: string[]; pinnedConversationIdsUpdatedAt: string } | null = null;

  const flushPush = () => {
    pushTimer = null;
    if (!pendingPayload) return;
    lastPushAt = Date.now();
    getSyncAdapter()?.didUpdatePreferences(pendingPayload);
    pendingPayload = null;
  };
  const schedulePush = (payload: { pinnedConversationIds: string[]; pinnedConversationIdsUpdatedAt: string }) => {
    const elapsed = Date.now() - lastPushAt;
    if (elapsed >= PIN_PUSH_THROTTLE_MS) {
      lastPushAt = Date.now();
      getSyncAdapter()?.didUpdatePreferences(payload);
      return;
    }
    pendingPayload = payload;
    if (!pushTimer) pushTimer = setTimeout(flushPush, PIN_PUSH_THROTTLE_MS - elapsed);
  };

  const unsub = store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prevPinned = state.pinnedConversationIds;
      prevPinnedUpdatedAt = state.pinnedConversationIdsUpdatedAt;
      return;
    }
    if (state.pinnedConversationIds === prevPinned && state.pinnedConversationIdsUpdatedAt === prevPinnedUpdatedAt) {
      return;
    }
    setPreference('pinnedConversationIds', state.pinnedConversationIds);
    // Remove the key explicitly when undefined, otherwise setPreference(key, undefined) writes the literal string "undefined" and the next parse fails
    if (state.pinnedConversationIdsUpdatedAt === undefined) {
      removePreference('pinnedConversationIdsUpdatedAt');
    } else {
      setPreference('pinnedConversationIdsUpdatedAt', state.pinnedConversationIdsUpdatedAt);
    }
    prevPinned = state.pinnedConversationIds;
    prevPinnedUpdatedAt = state.pinnedConversationIdsUpdatedAt;
    // Notify the sync port, but only once a timestamp exists: no timestamp means pins were never
    // edited locally, so pushing would overwrite the other side with nothing.
    if (state.pinnedConversationIdsUpdatedAt) {
      schedulePush({
        pinnedConversationIds: state.pinnedConversationIds,
        pinnedConversationIdsUpdatedAt: state.pinnedConversationIdsUpdatedAt,
      });
    }
  });
  return () => {
    unsub();
    if (pushTimer) clearTimeout(pushTimer);
  };
}

export function subscribeConversationOrder(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().conversationOrder;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.conversationOrder;
      return;
    }
    if (state.conversationOrder === prev) return;
    setPreference('conversationOrder', state.conversationOrder);
    prev = state.conversationOrder;
  });
}

export function subscribeLastUsedModelRef(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().lastUsedModelRef;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.lastUsedModelRef;
      return;
    }
    if (state.lastUsedModelRef === prev) return;
    setSessionValue('lastUsedModelRef', state.lastUsedModelRef);
    prev = state.lastUsedModelRef;
  });
}

export function subscribeFolders(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().folders;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.folders;
      return;
    }
    // Folders persist immediately: there are few of them and they change rarely
    if (state.folders === prev) return;
    const currentIds = new Set(state.folders.map((f) => f.id));
    const prevFolderMap = new Map(prev.map((f) => [f.id, f]));
    for (const f of state.folders) {
      const old = prevFolderMap.get(f.id);
      if (!old || old !== f) putFolder(f);
    }
    for (const f of prev) {
      if (!currentIds.has(f.id)) idbDeleteFolder(f.id);
    }
    prev = state.folders;
  });
}

/**
 * Note persistence, managing active notes and the trash as one union.
 *
 * Soft deleting a note does not remove it from IDB; the store only moves it from notes to
 * trashedNotes. A real delete is therefore detected by disappearance from the union: moving
 * between active and trashed stays inside the union and is an upsert, with or without
 * deletedAt, and only leaving the union (emptyTrash, or removed remotely) hard deletes from IDB.
 * Same shape as conversations: a 500ms debounce for upserts, because the body is edited
 * keystroke by keystroke, immediate handling of deletes, partition race protection through
 * getActiveUIDSync, a hydrationPhase gate and clearTimeout.
 */
export function subscribeNotes(store: StoreApi<AppStore>): () => void {
  let prevNotesRef = store.getState().notes;
  let prevTrashedRef = store.getState().trashedNotes;
  // prev is the last persisted snapshot of the whole set (active plus trashed); diffing it yields additions, changes and disappearances
  let prev = [...prevNotesRef, ...prevTrashedRef];
  let timer: ReturnType<typeof setTimeout> | null = null;

  const unsub = store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prevNotesRef = state.notes;
      prevTrashedRef = state.trashedNotes;
      prev = [...state.notes, ...state.trashedNotes];
      return;
    }
    if (state.notes === prevNotesRef && state.trashedNotes === prevTrashedRef) return;
    prevNotesRef = state.notes;
    prevTrashedRef = state.trashedNotes;

    const union = [...state.notes, ...state.trashedNotes];
    const currentIds = new Set(union.map((n) => normalizeUUID(n.id)));

    // Leaving the union is a real delete (emptyTrash, or removed remotely), so hard delete from IDB right away rather than on the debounce
    const deleted = prev.filter((n) => !currentIds.has(normalizeUUID(n.id)));
    if (deleted.length > 0) {
      for (const n of deleted) idbDeleteNote(n.id);
      prev = prev.filter((n) => currentIds.has(normalizeUUID(n.id)));
    }

    if (timer) clearTimeout(timer);
    // Record the activeUID at schedule time: switching accounts inside the debounce window discards this write, so nothing leaks across account partitions
    const scheduledUID = getActiveUIDSync();
    timer = setTimeout(() => {
      if (getActiveUIDSync() !== scheduledUID) return;
      const prevMap = new Map(prev.map((n) => [normalizeUUID(n.id), n]));
      for (const n of union) {
        const old = prevMap.get(normalizeUUID(n.id));
        if (!old || old !== n) putNote(n);
      }
      prev = union;
    }, NOTE_PERSIST_DEBOUNCE_MS);
  });
  // Clear the pending debounce on unmount or partition switch, so a stale write cannot land in the wrong partition or after teardown
  return () => {
    unsub();
    if (timer) clearTimeout(timer);
  };
}

export function subscribeNoteFolders(store: StoreApi<AppStore>): () => void {
  let prev = store.getState().noteFolders;
  return store.subscribe((state) => {
    if (state.hydrationPhase !== 'ready') {
      prev = state.noteFolders;
      return;
    }
    // NoteFolders persist immediately (there are few of them and they change rarely), mirroring subscribeFolders
    if (state.noteFolders === prev) return;
    const currentIds = new Set(state.noteFolders.map((f) => f.id));
    const prevFolderMap = new Map(prev.map((f) => [f.id, f]));
    for (const f of state.noteFolders) {
      const old = prevFolderMap.get(f.id);
      if (!old || old !== f) putNoteFolder(f);
    }
    for (const f of prev) {
      if (!currentIds.has(f.id)) idbDeleteNoteFolder(f.id);
    }
    prev = state.noteFolders;
  });
}

/* ── Orphaned image cleanup ─────────────────────────────────────── */

function cleanupConversationImages(conv: Conversation) {
  for (const msg of conv.messages) {
    if (!msg.attachments) continue;
    for (const att of msg.attachments) {
      if (att.kind === 'image' && att.localImageID) {
        deleteImage(att.localImageID);
      }
    }
  }
}
