import type { Conversation } from '@oriveo/shared';
import { scanConversationsInChunks } from './idb';
import { getActiveUIDSync } from './partition';
import {
  deleteImage,
  listImageRecords,
  stampImageSavedAt,
  wasImageSavedThisSession,
} from './image-store';

/**
 * Unreferenced-image cleanup plus the launch-time orphan sweep.
 *
 * The reference set is read straight from all conversation messages in IndexedDB, never from the
 * summary-state UI store; both key kinds count: the attachment's localImageID and its
 * attachment.id (used for remote downloads).
 * Fail-closed: if reading the reference set fails, or the active partition changed before any
 * deletion batch, nothing more is deleted this round.
 * Only image-store records are written (deleting, or stamping savedAt on old records); the
 * conversation store is never written.
 */

const BATCH_SIZE = 200;
const AVATAR_PREFIX = 'user-avatar-';
/** Orphan sweep grace: only records saved before (this launch time - 24 h) are deleted. */
const GRACE_MS = 24 * 60 * 60 * 1000;
/** Maximum deletions per round. */
const MAX_DELETIONS_PER_ROUND = 500;
/** When candidates exceed both this absolute count and this share of stored keys, treat it as abnormal (most likely an incomplete reference set) and abort the whole round. */
const MASS_DELETION_MIN_CANDIDATES = 200;
const MASS_DELETION_MAX_RATIO = 0.5;

// This launch time: the page navigation origin (independent of when the sweep is triggered); falls back to the module load time when unavailable.
const LAUNCHED_AT = typeof performance !== 'undefined' && Number.isFinite(performance.timeOrigin)
  ? Math.floor(performance.timeOrigin)
  : Date.now();

// Partitions that already started a launch sweep in this run: sweep once even when startup, sign-in and similar entry points trigger it repeatedly.
const sweptPartitions = new Set<string>();

export type ImagePurgeAbortReason = 'partition-changed' | 'mass-deletion';

export interface ImagePurgeResult {
  /** False when reading the reference set failed: no image was deleted this round. */
  referencesRead: boolean;
  deleted: string[];
  /** The round was aborted by a fail-closed check (images deleted before the abort are still listed in deleted). */
  aborted?: ImagePurgeAbortReason;
}

export interface OrphanSweepOptions {
  /** This launch time in milliseconds; defaults to the page navigation origin. */
  launchedAt?: number;
}

/** Malformed conversation record (messages / attachments not an array, etc.): the reference set cannot be trusted, give up the whole round. */
class CorruptConversationRecordError extends Error {}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Merge the attachment reference keys of one chunk of conversation records into keys. An undefined
 * messages / attachments counts as empty; null, an object, a string or any other non-array, or a
 * message / attachment that is not an object, throws and the whole round fails closed.
 */
function collectReferencedKeys(conversations: Conversation[], keys: Set<string>): void {
  for (const conversation of conversations) {
    const messages: unknown = (conversation as { messages?: unknown }).messages;
    if (messages === undefined) continue;
    if (!Array.isArray(messages)) throw new CorruptConversationRecordError();
    for (const message of messages) {
      if (!isRecord(message)) throw new CorruptConversationRecordError();
      const attachments = message.attachments;
      if (attachments === undefined) continue;
      if (!Array.isArray(attachments)) throw new CorruptConversationRecordError();
      for (const attachment of attachments) {
        if (!isRecord(attachment)) throw new CorruptConversationRecordError();
        if (typeof attachment.id === 'string' && attachment.id) keys.add(attachment.id);
        if (typeof attachment.localImageID === 'string' && attachment.localImageID) {
          keys.add(attachment.localImageID);
        }
      }
    }
  }
}

/** Read the reference set in chunks; a read failure, a partition switch in flight or a corrupt record all return null (delete nothing this round). */
async function readReferencedKeys(uid: string): Promise<Set<string> | null> {
  const keys = new Set<string>();
  try {
    await scanConversationsInChunks(uid, (chunk) => collectReferencedKeys(chunk, keys));
    return keys;
  } catch {
    return null;
  }
}

function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

interface BatchDeleteResult {
  deleted: string[];
  bytes: number;
  aborted?: ImagePurgeAbortReason;
}

async function deleteInBatches(ids: string[], uid: string): Promise<BatchDeleteResult> {
  const deleted: string[] = [];
  let bytes = 0;
  for (let start = 0; start < ids.length; start += BATCH_SIZE) {
    if (start > 0) await yieldToEventLoop();
    // Verify the active partition is unchanged before each batch: a sign-in / sign-out mid-round abandons the whole round, never deleting across partitions.
    if (getActiveUIDSync() !== uid) return { deleted, bytes, aborted: 'partition-changed' };
    for (const id of ids.slice(start, start + BATCH_SIZE)) {
      // Async partition check as a backstop: deleteImage throws when the partition switches in flight, so stop immediately.
      const freed: unknown = await deleteImage(id, uid);
      deleted.push(id);
      if (typeof freed === 'number' && Number.isFinite(freed)) bytes += freed;
    }
  }
  return { deleted, bytes };
}

function logPurge(fields: { candidates: number; deleted: number; bytes: number; aborted?: string }) {
  // Log only counts and the abort reason, never any user content.
  console.info(
    `[ImagePurge] candidates=${fields.candidates} deleted=${fields.deleted} `
      + `bytes=${fields.bytes} aborted=${fields.aborted ?? 'none'}`,
  );
}

interface PurgeWaiter {
  ids: string[];
  resolve: (result: ImagePurgeResult) => void;
  reject: (error: unknown) => void;
}

// Pending purge requests per partition and whether a round is already running: one round at a time
// per partition; candidates arriving meanwhile join the next round (one reference-set read serves
// several requests), with no timers.
const pendingPurges = new Map<string, PurgeWaiter[]>();
const runningPurges = new Set<string>();

async function runPurgeRound(uid: string, waiters: PurgeWaiter[]): Promise<void> {
  const union = [...new Set(waiters.flatMap((waiter) => waiter.ids))];
  try {
    const referenced = await readReferencedKeys(uid);
    if (!referenced) {
      logPurge({ candidates: union.length, deleted: 0, bytes: 0, aborted: 'references-unavailable' });
      for (const waiter of waiters) waiter.resolve({ referencesRead: false, deleted: [] });
      return;
    }
    // Candidates come from explicit deletions, so there is no mass-deletion abort; only the per-round deletion count is capped and the rest is left to the launch orphan sweep.
    const targets = union.filter((id) => !referenced.has(id)).slice(0, MAX_DELETIONS_PER_ROUND);
    const batch = await deleteInBatches(targets, uid);
    logPurge({
      candidates: union.length,
      deleted: batch.deleted.length,
      bytes: batch.bytes,
      aborted: batch.aborted,
    });
    const deletedIds = new Set(batch.deleted);
    for (const waiter of waiters) {
      waiter.resolve({
        referencesRead: true,
        deleted: waiter.ids.filter((id) => deletedIds.has(id)),
        ...(batch.aborted ? { aborted: batch.aborted } : {}),
      });
    }
  } catch (error) {
    for (const waiter of waiters) waiter.reject(error);
  }
}

async function drainPurges(uid: string): Promise<void> {
  runningPurges.add(uid);
  try {
    for (;;) {
      const waiters = pendingPurges.get(uid);
      if (!waiters || waiters.length === 0) break;
      pendingPurges.delete(uid);
      await runPurgeRound(uid, waiters);
    }
  } finally {
    pendingPurges.delete(uid);
    runningPurges.delete(uid);
  }
}

/**
 * Delete candidate images no longer referenced by any message in this partition.
 * Called in the background by the delete-message / delete-conversation entry points after the
 * deletion commits; concurrent requests for the same partition are merged into one round and each
 * request gets back the result for its own candidates.
 */
export function purgeUnreferencedImages(
  candidates: Iterable<string>,
  expectedUID: string = getActiveUIDSync(),
): Promise<ImagePurgeResult> {
  const ids = [...new Set(candidates)].filter((id) => id.length > 0);
  if (ids.length === 0) return Promise.resolve({ referencesRead: true, deleted: [] });
  return new Promise<ImagePurgeResult>((resolve, reject) => {
    const waiters = pendingPurges.get(expectedUID) ?? [];
    waiters.push({ ids, resolve, reject });
    pendingPurges.set(expectedUID, waiters);
    if (!runningPurges.has(expectedUID)) void drainPurges(expectedUID);
  });
}

// The size is for logging only: when unavailable (corrupt record / not a Blob) count it as 0 so the log never turns into NaN.
function blobSize(value: Blob | undefined): number {
  const size = value?.size;
  return typeof size === 'number' && Number.isFinite(size) ? size : 0;
}

function logSweep(fields: {
  candidates: number;
  deleted: number;
  bytes: number;
  stamped: number;
  aborted?: string;
}) {
  // Log only counts and the abort reason, never any user content.
  console.info(
    `[ImageOrphanSweep] candidates=${fields.candidates} deleted=${fields.deleted} `
      + `bytes=${fields.bytes} stamped=${fields.stamped} aborted=${fields.aborted ?? 'none'}`,
  );
}

/**
 * Launch orphan sweep: runs once in the background after the partition is ready. Candidates = all
 * image-store keys minus the reference set, skipping user-avatar-* and ids saved during this run.
 * Each partition is swept once per run. Of the candidates only those with savedAt earlier than
 * (launch time - 24 h) are deleted; old records without savedAt are only stamped this round, not
 * deleted (stamping happens before the abort check).
 */
export async function sweepOrphanImagesOnLaunch(
  expectedUID: string = getActiveUIDSync(),
  options: OrphanSweepOptions = {},
): Promise<ImagePurgeResult> {
  if (sweptPartitions.has(expectedUID)) return { referencesRead: true, deleted: [] };
  // Register on start: a concurrent second call does not enter; a failure is not retried within this run either.
  sweptPartitions.add(expectedUID);
  const launchedAt = options.launchedAt ?? LAUNCHED_AT;
  // List records before reading references: an image saved in between is in this run's saved set and its savedAt is within the grace period.
  const records = await listImageRecords(expectedUID);
  const pool = records.filter(
    (record) => !record.id.startsWith(AVATAR_PREFIX) && !wasImageSavedThisSession(record.id),
  );
  if (pool.length === 0) {
    logSweep({ candidates: 0, deleted: 0, bytes: 0, stamped: 0 });
    return { referencesRead: true, deleted: [] };
  }
  const referenced = await readReferencedKeys(expectedUID);
  if (!referenced) {
    logSweep({ candidates: 0, deleted: 0, bytes: 0, stamped: 0, aborted: 'references-unavailable' });
    return { referencesRead: false, deleted: [] };
  }
  const orphans = pool.filter((record) => !referenced.has(record.id));

  // Stamp old orphans without savedAt first, then check for abort: stamping deletes nothing, so the mass-deletion abort does not affect it.
  let stamped = 0;
  const legacy = orphans.filter((record) => record.savedAt === undefined);
  if (legacy.length > 0) {
    if (getActiveUIDSync() !== expectedUID) {
      logSweep({ candidates: orphans.length, deleted: 0, bytes: 0, stamped, aborted: 'partition-changed' });
      return { referencesRead: true, deleted: [], aborted: 'partition-changed' };
    }
    const stampAt = Date.now();
    for (const record of legacy) {
      await stampImageSavedAt(record.id, stampAt, expectedUID);
      stamped++;
    }
  }

  // Only orphans whose savedAt is a finite number earlier than the grace cutoff may be deleted; a corrupt (non-finite) savedAt is skipped, not deleted.
  const graceCutoff = launchedAt - GRACE_MS;
  const dueAll = orphans.filter(
    (record) => typeof record.savedAt === 'number'
      && Number.isFinite(record.savedAt)
      && record.savedAt < graceCutoff,
  );
  // The numerator of the abnormal-abort check counts only orphans deletable beyond the grace period: those within grace or just stamped will not be deleted and must not trigger an abort.
  if (
    dueAll.length > MASS_DELETION_MIN_CANDIDATES
    && dueAll.length > records.length * MASS_DELETION_MAX_RATIO
  ) {
    logSweep({ candidates: orphans.length, deleted: 0, bytes: 0, stamped, aborted: 'mass-deletion' });
    return { referencesRead: true, deleted: [], aborted: 'mass-deletion' };
  }
  const due = dueAll.slice(0, MAX_DELETIONS_PER_ROUND);
  const batch = await deleteInBatches(due.map((record) => record.id), expectedUID);
  const deletedIds = new Set(batch.deleted);
  const bytes = due
    .filter((record) => deletedIds.has(record.id))
    .reduce((sum, record) => sum + blobSize(record.data) + blobSize(record.thumbnail), 0);
  logSweep({
    candidates: orphans.length,
    deleted: batch.deleted.length,
    bytes,
    stamped,
    aborted: batch.aborted,
  });
  return {
    referencesRead: true,
    deleted: batch.deleted,
    ...(batch.aborted ? { aborted: batch.aborted } : {}),
  };
}
