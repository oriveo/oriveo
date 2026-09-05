/* notification arguments differ per entity;
   a backend is free to ignore them, so the port does not model each shape. */
/**
 * The port a synchronisation backend plugs into.
 *
 * Nothing is installed by default, so `getSyncAdapter()` returns `null` and IndexedDB is the only
 * copy of a user's data. Every call site reaches the adapter through optional chaining, which is
 * what keeps "there is no backend" from being a special case anyone has to handle.
 *
 * The interface is deliberately a set of past-tense notifications rather than commands. Local state
 * is written first and the adapter is told afterwards, so a backend can never be on the critical
 * path of an edit: a slow or broken one costs the user nothing.
 */

import type { ChatMessage } from '@oriveo/shared';

export type SyncState = 'idle' | 'syncing' | 'error' | 'disabled';

/**
 * A past-tense notification. Arguments vary by entity, and a backend is free to ignore them: what
 * matters is that local state was already written before the call.
 */
type SyncNotification = (...args: any[]) => void;

/**
 * A backend implements all of it. Making the methods required rather than optional is deliberate:
 * a partial implementation would silently stop mirroring one entity, and nothing in the app would
 * report it.
 */
export interface SyncAdapter {
  /** Identifier of the account this adapter is bound to, if it has a notion of accounts. */
  boundUID?: string;

  /** Whether the backend is connected and accepting writes. */
  isActive: boolean;

  didUpdateProvider: SyncNotification;
  didUpdatePreferences: SyncNotification;

  didCreateFolder: SyncNotification;
  didUpdateFolder: SyncNotification;
  didDeleteFolder: SyncNotification;
  didReorderFolders: SyncNotification;
  didMoveConversationToFolder: SyncNotification;
  didBatchMoveToFolder: SyncNotification;

  didCreateNote: SyncNotification;
  didUpdateNote: SyncNotification;
  didDeleteNotes: SyncNotification;
  didRestoreNote: SyncNotification;
  didEmptyTrashNotes: SyncNotification;
  didCreateNoteFolder: SyncNotification;
  didUpdateNoteFolder: SyncNotification;
  didDeleteNoteFolder: SyncNotification;
  didReorderNoteFolders: SyncNotification;
  didMoveNoteToFolder: SyncNotification;
  didUpdateConversationPinnedNotes: SyncNotification;

  didUpdateConversationTitle: SyncNotification;
  didUpdateConversationModel: SyncNotification;
  didCompleteAssistantMessage: SyncNotification;
  didCompleteRound: SyncNotification;
  didRegenerate: SyncNotification;
  didDeleteMessages: SyncNotification;
  didBackfillStorageRefs: SyncNotification;

  /** Live message updates for the conversation the user is looking at. */
  startMessagesListener: (...args: any[]) => void;
  stopMessagesListener: (...args: any[]) => void;

  /**
   * Pages the messages surrounding one message, for opening a link into the middle of a long
   * conversation whose body is not on this device.
   */
  fetchMessageWindowAround: (
    conversationId: string,
    messageId: string,
    window: { before: number; after: number },
  ) => Promise<ChatMessage[]>;

  /**
   * An import replaces local state wholesale. The backend is paused around it so its listeners
   * cannot race the rewrite, then asked to converge to the imported state.
   */
  pauseSyncListenersForCriticalSection: (...args: any[]) => void;
  resumeSyncListenersAfterCriticalSection: (...args: any[]) => void;
  convergeBackupImportToCloud: (...args: any[]) => Promise<unknown>;
}

let adapter: SyncAdapter | null = null;
const listeners = new Set<() => void>();

export function getSyncAdapter(): SyncAdapter | null {
  return adapter;
}

/** Installs a backend. Pass `null` to go back to local-only. */
export function setSyncAdapter(next: SyncAdapter | null): void {
  adapter = next;
  for (const listener of listeners) listener();
}

export function createSyncAdapter(): SyncAdapter | null {
  return adapter;
}

export function destroySyncAdapter(): void {
  setSyncAdapter(null);
}

export function subscribeSyncAdapter(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Deletions are recorded locally and only then handed to a backend, so a deletion that happens
 * while offline is not lost. Without an adapter there is nothing pending to flush.
 */
export async function flushPendingConversationDeletions(..._args: unknown[]): Promise<void> {}
export async function flushPendingProviderDeletions(..._args: unknown[]): Promise<void> {}
export function registerPendingProviderDeletion(..._args: unknown[]): void {}
export function unregisterPendingProviderDeletion(..._args: unknown[]): void {}

export function resetPreferencesWritebackCircuit(): void {}

/**
 * Attachment bodies stay in local blob storage. A backend that mirrors them returns a reference
 * from these; without one there is no reference to hand out and no remote copy to fetch.
 */
export async function uploadAttachmentIfNeeded(..._args: unknown[]): Promise<string | null> {
  return null;
}
export async function uploadFileAttachmentIfNeeded(..._args: unknown[]): Promise<string | null> {
  return null;
}
export async function downloadAttachmentIfNeeded(..._args: unknown[]): Promise<string | null> {
  return null;
}
export async function downloadFileBlob(_storageRef: string): Promise<Blob | null> {
  return null;
}
export async function downloadFileURL(_storageRef: string): Promise<string | null> {
  return null;
}
export async function deleteAttachments(..._args: unknown[]): Promise<void> {}
