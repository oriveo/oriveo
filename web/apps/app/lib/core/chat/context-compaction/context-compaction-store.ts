import { ContextCheckpoint, type CheckpointDigestMessage } from '@oriveo/core/context/checkpoint';
import {
  type ContextCheckpointRow,
  deleteAllContextCheckpoints,
  deleteContextCheckpoints,
  listContextCheckpoints,
  putContextCheckpoint,
} from '../../../infra/storage/context-checkpoint-store';

/*
 * Checkpoint validity and invalidation. Only calls the production functions of core ContextCheckpoint.
 * Mutations made through this store's put / deleteAll / invalidate notify subscribeCheckpointChanges subscribers (used to refresh the UI).
 */

type CheckpointChangeListener = (conversationId: string) => void;
const changeListeners = new Set<CheckpointChangeListener>();

/** Subscribes to checkpoint changes of a conversation; returns the unsubscribe function. */
function subscribeCheckpointChanges(listener: CheckpointChangeListener): () => void {
  changeListeners.add(listener);
  return () => {
    changeListeners.delete(listener);
  };
}

function notifyCheckpointChanged(conversationId: string): void {
  for (const listener of [...changeListeners]) {
    try {
      listener(conversationId);
    } catch (error) {
      console.error('[ContextCompaction] change listener failed:', error);
    }
  }
}

/** Writes one checkpoint and notifies. */
async function put(row: ContextCheckpointRow): Promise<void> {
  await putContextCheckpoint(row);
  notifyCheckpointChanged(row.conversationId);
}

/** Clears every checkpoint of the conversation: returns the deleted ids and notifies only when something was deleted. */
async function deleteAll(conversationId: string): Promise<string[]> {
  const deleted = await deleteAllContextCheckpoints(conversationId);
  if (deleted.length > 0) {
    notifyCheckpointChanged(conversationId);
  }
  return deleted;
}

/** Deletes the given checkpoints (re-compaction deletes the active row R): notifies only when ids were given. */
async function remove(conversationId: string, checkpointIds: readonly string[]): Promise<void> {
  if (checkpointIds.length === 0) return;
  await deleteContextCheckpoints(conversationId, checkpointIds);
  notifyCheckpointChanged(conversationId);
}

/**
 * The newest usable checkpoint for the current history: rows whose coversTo is not in history or whose prefix digest
 * does not match are skipped (not deleted); the rest are picked with resolveConcurrency; returns null when none.
 */
async function latestValid(
  conversationId: string,
  history: readonly CheckpointDigestMessage[],
): Promise<ContextCheckpointRow | null> {
  const rows = await listContextCheckpoints(conversationId);
  let best: { checkpointId: string; coversToIndex: number; createdAtMillis: number; row: ContextCheckpointRow } | null =
    null;
  for (const row of rows) {
    const coversToIndex = history.findIndex((m) => m.id === row.coversTo);
    if (coversToIndex < 0) continue;
    if (ContextCheckpoint.coversDigest(history.slice(0, coversToIndex + 1)) !== row.coversDigest) continue;
    const candidate = { checkpointId: row.checkpointId, coversToIndex, createdAtMillis: row.createdAt, row };
    best = best === null ? candidate : ContextCheckpoint.resolveConcurrency(best, candidate);
  }
  return best?.row ?? null;
}

/**
 * The history changed at affectedIds: k = the smallest index of any affected id in the pre-change historyIds;
 * rows whose coversTo index is >= k are deleted; rows whose coversTo is not in history are left alone. Returns the deleted checkpointIds.
 */
async function invalidate(
  conversationId: string,
  historyIds: readonly string[],
  affectedIds: readonly string[],
): Promise<string[]> {
  const indexById = new Map(historyIds.map((id, index) => [id, index]));
  let k = Infinity;
  for (const id of affectedIds) {
    const index = indexById.get(id);
    if (index !== undefined && index < k) k = index;
  }
  if (k === Infinity) return [];
  const rows = await listContextCheckpoints(conversationId);
  const doomed = rows
    .filter((row) => {
      const index = indexById.get(row.coversTo);
      return index !== undefined && index >= k;
    })
    .map((row) => row.checkpointId);
  await deleteContextCheckpoints(conversationId, doomed);
  if (doomed.length > 0) notifyCheckpointChanged(conversationId);
  return doomed;
}

/**
 * Hook for local history changes (edit and resend / retry / delete message): invalidates locally.
 * Does not block the caller: a failure is only logged (the read-time digest check is the backstop).
 */
function invalidateAndSync(
  conversationId: string,
  historyIds: readonly string[],
  affectedIds: readonly string[],
): Promise<void> {
  return invalidate(conversationId, historyIds, affectedIds).then(
    () => undefined,
    (error: unknown) => {
      console.error('[ContextCompaction] invalidate failed:', error);
    },
  );
}

export const ContextCompactionStore = { latestValid, invalidate, invalidateAndSync, put, deleteAll, remove, subscribeCheckpointChanges };
