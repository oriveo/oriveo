import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { Attachment, ChatMessage, Conversation } from '@oriveo/shared';
import * as idb from '../idb';
import { imageExists, resetImageDBConnection, saveImage } from '../image-store';
import { setActiveUID } from '../partition';
import { purgeUnreferencedImages, sweepOrphanImagesOnLaunch } from '../image-orphan-sweeper';

// Wrapped in vi.fn: cases can inject read failures and assert the sweep touched no conversation-store write entry point.
vi.mock('../idb', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../idb')>();
  return {
    ...actual,
    getAllConversations: vi.fn(actual.getAllConversations),
    scanConversationsInChunks: vi.fn(actual.scanConversationsInChunks),
    putConversation: vi.fn(actual.putConversation),
    putConversationPreservingHydratedMessages: vi.fn(actual.putConversationPreservingHydratedMessages),
    deleteConversation: vi.fn(actual.deleteConversation),
  };
});

// The sweep runs once per partition per run (module-level dedup), so each case uses its own partition.
let uidSeq = 0;
let UID = 'user-sweep-0';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function blob(content: string): Blob {
  return new Blob([content], { type: 'image/png' });
}

function imageAttachment(id: string, localImageID?: string): Attachment {
  return { id, kind: 'image', fileName: `${id}.png`, mimeType: 'image/png', localImageID };
}

function conversationWith(id: string, attachments: Attachment[]): Conversation {
  const message = {
    id: `${id}-m1`,
    role: 'user',
    text: 'hi',
    createdAt: new Date().toISOString(),
    attachments,
  } as unknown as ChatMessage;
  return {
    id,
    title: 'T',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: 'hi',
    estimatedCost: 0,
    isDraft: false,
    messages: [message],
    draftText: '',
    updatedAt: new Date().toISOString(),
  };
}

const HOUR = 60 * 60 * 1000;
/** Images left over from a previous run are by default long past the grace period (saved 48 h before launch). */
const OLD_SAVED_AT = () => Date.now() - 48 * HOUR;

async function openSeedDB(uid: string) {
  const { openDB } = await import('idb');
  const { getImageDBName } = await import('../partition');
  return openDB(getImageDBName(uid), 1, {
    upgrade(database) {
      if (!database.objectStoreNames.contains('images')) {
        database.createObjectStore('images', { keyPath: 'id' });
      }
    },
  });
}

/**
 * Writes bypassing saveImage, to simulate images left by a previous run (not in this run's saved set).
 * A savedAt of null means an old record written before savedAt existed.
 */
async function seedPreviousRunImages(
  ids: string[],
  uid: string = UID,
  savedAt: number | null = OLD_SAVED_AT(),
) {
  const db = await openSeedDB(uid);
  for (const id of ids) {
    await db.put('images', {
      id,
      data: blob(id),
      thumbnail: blob(`${id}-t`),
      mimeType: 'image/png',
      ...(savedAt === null ? {} : { savedAt }),
    });
  }
  db.close();
}

/** Write a raw conversation record bypassing putConversation's sanitising: simulates a corrupt conversation record. */
async function putRawConversation(record: Record<string, unknown>, uid: string = UID) {
  // Create the database through the normal entry point first (with its schema), then open it at the existing version to write the raw record
  await idb.putConversation(conversationWith('seed-ok', []));
  const { openDB } = await import('idb');
  const { getDBName } = await import('../partition');
  const db = await openDB(getDBName(uid));
  await db.put('conversations', record);
  db.close();
}

async function readSeedRecord(id: string, uid: string = UID) {
  const db = await openSeedDB(uid);
  const record = await db.get('images', id);
  db.close();
  return record as { savedAt?: number } | undefined;
}

function idsOf(prefix: string, count: number): string[] {
  return Array.from({ length: count }, (_, index) => `${prefix}-${index}`);
}

/** Switch the active partition after the reference set is read: simulates a sign-in / sign-out in the middle of a sweep round. */
async function switchPartitionAfterReferenceRead(otherUID: string) {
  const actual = await vi.importActual<typeof import('../idb')>('../idb');
  vi.mocked(idb.scanConversationsInChunks).mockImplementationOnce(async (uid, visit, chunkSize) => {
    await actual.scanConversationsInChunks(uid, visit, chunkSize);
    await setActiveUID(otherUID);
  });
}

describe('image-orphan-sweeper', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    idb.resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    UID = `user-sweep-${++uidSeq}`;
    await setActiveUID(UID);
  });

  it('attachmentPurge_deletesUnreferencedCandidate', async () => {
    await saveImage('img-gone', blob('a'), blob('a-t'), 'image/png', UID);
    await saveImage('img-kept', blob('b'), blob('b-t'), 'image/png', UID);
    await idb.putConversation(conversationWith('c1', [imageAttachment('att-b', 'img-kept')]));

    const result = await purgeUnreferencedImages(['img-gone', 'img-kept'], UID);

    expect(result).toEqual({ referencesRead: true, deleted: ['img-gone'] });
    expect(await imageExists('img-gone', UID)).toBe(false);
    expect(await imageExists('img-kept', UID)).toBe(true);
  });

  it('attachmentPurge_keepsSharedKey', async () => {
    // Conflict copies share the same file key: after one conversation is deleted the other still references it (both localImageID and attachment.id count)
    await saveImage('shared-local', blob('s'), blob('s-t'), 'image/png', UID);
    await saveImage('shared-att', blob('d'), blob('d-t'), 'image/png', UID);
    await idb.putConversation(conversationWith('copy', [
      imageAttachment('x', 'shared-local'),
      imageAttachment('shared-att'),
    ]));

    const result = await purgeUnreferencedImages(['shared-local', 'shared-att'], UID);

    expect(result.deleted).toEqual([]);
    expect(await imageExists('shared-local', UID)).toBe(true);
    expect(await imageExists('shared-att', UID)).toBe(true);
  });

  it('attachmentPurge_referenceReadFails_deletesNothing', async () => {
    await saveImage('img-orphan', blob('o'), blob('o-t'), 'image/png', UID);
    vi.mocked(idb.scanConversationsInChunks).mockRejectedValueOnce(new Error('read failed'));

    const result = await purgeUnreferencedImages(['img-orphan'], UID);

    expect(result).toEqual({ referencesRead: false, deleted: [] });
    expect(await imageExists('img-orphan', UID)).toBe(true);
  });

  it('orphanSweep_deletesOrphansOutsideGrace', async () => {
    // Spans several batches (> 200) but orphans are under half, so the mass-deletion abort does not trigger
    const orphans = idsOf('old-orphan', 205);
    const referencedIds = idsOf('old-referenced', 205);
    await seedPreviousRunImages([...orphans, ...referencedIds]);
    await idb.putConversation(conversationWith('c1', referencedIds.map((id) => imageAttachment(`a-${id}`, id))));

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result.referencesRead).toBe(true);
    expect([...result.deleted].sort()).toEqual([...orphans].sort());
    expect(await imageExists('old-orphan-0', UID)).toBe(false);
    expect(await imageExists('old-orphan-204', UID)).toBe(false);
    expect(await imageExists('old-referenced-0', UID)).toBe(true);
  });

  it('orphanSweep_keepsAvatarAndGrace', async () => {
    await seedPreviousRunImages(['user-avatar-abc', 'old-orphan']);
    await saveImage('fresh-unsaved-draft', blob('f'), blob('f-t'), 'image/png', UID);

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result.deleted).toEqual(['old-orphan']);
    expect(await imageExists('user-avatar-abc', UID)).toBe(true);
    expect(await imageExists('fresh-unsaved-draft', UID)).toBe(true);
  });

  it('orphanSweep_noDbOrCloudWrites', async () => {
    await seedPreviousRunImages(['old-orphan']);
    await idb.putConversation(conversationWith('c1', [imageAttachment('a1')]));
    const before = await idb.getAllConversations(UID);
    vi.clearAllMocks();

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result.deleted).toEqual(['old-orphan']);
    expect(idb.scanConversationsInChunks).toHaveBeenCalledWith(UID, expect.any(Function));
    expect(idb.putConversation).not.toHaveBeenCalled();
    expect(idb.putConversationPreservingHydratedMessages).not.toHaveBeenCalled();
    expect(idb.deleteConversation).not.toHaveBeenCalled();
    expect(await idb.getAllConversations(UID)).toEqual(before);
  });

  it('orphanSweep_oncePerPartitionPerRun', async () => {
    await seedPreviousRunImages(['old-orphan-1']);
    const first = await sweepOrphanImagesOnLaunch(UID);
    expect(first.deleted).toEqual(['old-orphan-1']);

    // Second trigger for the same partition: lists no keys, reads no references, deletes nothing
    await seedPreviousRunImages(['old-orphan-2']);
    vi.clearAllMocks();
    const second = await sweepOrphanImagesOnLaunch(UID);

    expect(second.deleted).toEqual([]);
    expect(idb.scanConversationsInChunks).not.toHaveBeenCalled();
    expect(await imageExists('old-orphan-2', UID)).toBe(true);

    // Another partition is unaffected
    const otherUID = `${UID}-other`;
    await setActiveUID(otherUID);
    resetImageDBConnection();
    await seedPreviousRunImages(['other-orphan'], otherUID);
    const otherResult = await sweepOrphanImagesOnLaunch(otherUID);
    expect(otherResult).toEqual({ referencesRead: true, deleted: ['other-orphan'] });
  });

  it('orphanSweep_graceFromLaunchTime', async () => {
    // Launched 10 h ago: the grace period counts from launch time, not from when the sweep is triggered
    const launchedAt = Date.now() - 10 * HOUR;
    await seedPreviousRunImages(['before-grace'], UID, launchedAt - 24 * HOUR - 1);
    await seedPreviousRunImages(['inside-grace'], UID, launchedAt - 20 * HOUR);

    const result = await sweepOrphanImagesOnLaunch(UID, { launchedAt });

    expect(result).toEqual({ referencesRead: true, deleted: ['before-grace'] });
    expect(await imageExists('before-grace', UID)).toBe(false);
    // Saved 30 h before now but less than 24 h before launch: kept
    expect(await imageExists('inside-grace', UID)).toBe(true);
  });

  it('orphanSweep_legacyRecordStampedNotDeleted', async () => {
    await seedPreviousRunImages(['legacy-orphan'], UID, null);
    const before = Date.now();

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: [] });
    expect(await imageExists('legacy-orphan', UID)).toBe(true);
    const stamped = await readSeedRecord('legacy-orphan');
    expect(stamped?.savedAt).toBeGreaterThanOrEqual(before);
    expect(idb.putConversation).not.toHaveBeenCalled();
  });

  it('orphanSweep_partitionSwitchMidRun_aborts', async () => {
    await seedPreviousRunImages(['old-orphan-a', 'old-orphan-b']);
    await switchPartitionAfterReferenceRead(`${UID}-switched`);

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: [], aborted: 'partition-changed' });
    await setActiveUID(UID);
    expect(await imageExists('old-orphan-a', UID)).toBe(true);
    expect(await imageExists('old-orphan-b', UID)).toBe(true);
  });

  it('orphanSweep_massDeletionAborts', async () => {
    // 201 orphans making up > 50 % of stored keys: judged abnormal (most likely an incomplete reference set), none deleted
    const orphans = idsOf('old-orphan', 201);
    await seedPreviousRunImages([...orphans, 'old-referenced']);
    await idb.putConversation(conversationWith('c1', [imageAttachment('a1', 'old-referenced')]));

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: [], aborted: 'mass-deletion' });
    expect(await imageExists('old-orphan-0', UID)).toBe(true);
    expect(await imageExists('old-orphan-200', UID)).toBe(true);
  });

  it('orphanSweep_capPerRound', async () => {
    const orphans = idsOf('old-orphan', 600);
    const referencedIds = idsOf('old-referenced', 600);
    await seedPreviousRunImages([...orphans, ...referencedIds]);
    await idb.putConversation(conversationWith('c1', referencedIds.map((id) => imageAttachment(`a-${id}`, id))));

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result.referencesRead).toBe(true);
    expect(result.aborted).toBeUndefined();
    expect(result.deleted).toHaveLength(500);
    const remaining = await Promise.all(orphans.map((id) => imageExists(id, UID)));
    expect(remaining.filter(Boolean)).toHaveLength(100);
  });

  it('purge_partitionSwitchMidRun_aborts', async () => {
    await saveImage('img-gone', blob('a'), blob('a-t'), 'image/png', UID);
    await switchPartitionAfterReferenceRead(`${UID}-switched`);

    const result = await purgeUnreferencedImages(['img-gone'], UID);

    expect(result).toEqual({ referencesRead: true, deleted: [], aborted: 'partition-changed' });
    await setActiveUID(UID);
    expect(await imageExists('img-gone', UID)).toBe(true);
  });

  it('purge_capsAt500_andLogs', async () => {
    const ids = idsOf('gone', 600);
    await seedPreviousRunImages(ids);
    const info = vi.spyOn(console, 'info').mockImplementation(() => {});

    const result = await purgeUnreferencedImages(ids, UID);

    expect(result.referencesRead).toBe(true);
    expect(result.aborted).toBeUndefined();
    expect(result.deleted).toHaveLength(500);
    const remaining = await Promise.all(ids.map((id) => imageExists(id, UID)));
    expect(remaining.filter(Boolean)).toHaveLength(100);
    // The size comes from the deleted record's Blob metadata; Blobs cloned by fake-indexeddb do not keep size, so only the format is locked here
    const lines = info.mock.calls.map((call) => String(call[0])).filter((line) => line.startsWith('[ImagePurge]'));
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatch(/^\[ImagePurge\] candidates=600 deleted=500 bytes=\d+ aborted=none$/);
    info.mockRestore();
  });

  it('sweep_massAbortCountsOnlyDueOrphans', async () => {
    // 300 orphans within grace + 300 orphans without savedAt: none are deleted this round, so they do not count toward the abort numerator
    const fresh = idsOf('fresh-orphan', 300);
    const legacy = idsOf('legacy-orphan', 300);
    await seedPreviousRunImages(fresh, UID, Date.now() - HOUR);
    await seedPreviousRunImages(legacy, UID, null);
    await seedPreviousRunImages(['old-orphan', 'old-referenced']);
    await idb.putConversation(conversationWith('c1', [imageAttachment('a1', 'old-referenced')]));
    const before = Date.now();

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: ['old-orphan'] });
    expect(await imageExists('fresh-orphan-0', UID)).toBe(true);
    expect(await imageExists('old-referenced', UID)).toBe(true);
    expect((await readSeedRecord('legacy-orphan-0'))?.savedAt).toBeGreaterThanOrEqual(before);
    expect((await readSeedRecord('legacy-orphan-299'))?.savedAt).toBeGreaterThanOrEqual(before);
  });

  it('sweep_legacyStampedBeforeAbortDecision', async () => {
    // 201 orphans beyond grace making up over half of stored keys -> abort; old orphans without savedAt are still stamped first
    await seedPreviousRunImages(idsOf('old-orphan', 201));
    await seedPreviousRunImages(idsOf('legacy-orphan', 50), UID, null);
    const before = Date.now();

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: [], aborted: 'mass-deletion' });
    expect(await imageExists('old-orphan-0', UID)).toBe(true);
    expect(await imageExists('legacy-orphan-0', UID)).toBe(true);
    expect((await readSeedRecord('legacy-orphan-0'))?.savedAt).toBeGreaterThanOrEqual(before);
    expect((await readSeedRecord('legacy-orphan-49'))?.savedAt).toBeGreaterThanOrEqual(before);
  });

  it('sweep_corruptSavedAtSkipped', async () => {
    const db = await openSeedDB(UID);
    await db.put('images', { id: 'nan-orphan', data: blob('n'), mimeType: 'image/png', savedAt: Number.NaN });
    await db.put('images', { id: 'str-orphan', data: blob('s'), mimeType: 'image/png', savedAt: 'x' });
    db.close();
    await seedPreviousRunImages(['old-orphan']);

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: ['old-orphan'] });
    expect(await imageExists('nan-orphan', UID)).toBe(true);
    expect(await imageExists('str-orphan', UID)).toBe(true);
  });

  it('references_nonArrayMessages_abortsRound', async () => {
    for (const [index, messages] of [null, {}, 'corrupt'].entries()) {
      await saveImage(`img-${index}`, blob('a'), blob('a-t'), 'image/png', UID);
      await putRawConversation({ ...conversationWith(`bad-${index}`, []), messages });

      const result = await purgeUnreferencedImages([`img-${index}`], UID);

      expect(result).toEqual({ referencesRead: false, deleted: [] });
      expect(await imageExists(`img-${index}`, UID)).toBe(true);
      await idb.deleteConversation(`bad-${index}`);
    }
    // An attachments value that is not an array inside a message also abandons the whole round
    await saveImage('img-att', blob('a'), blob('a-t'), 'image/png', UID);
    await putRawConversation({
      ...conversationWith('bad-att', []),
      messages: [{ id: 'm1', role: 'user', text: 'hi', attachments: 'corrupt' }],
    });
    expect(await purgeUnreferencedImages(['img-att'], UID)).toEqual({ referencesRead: false, deleted: [] });
    expect(await imageExists('img-att', UID)).toBe(true);

    // The launch sweep likewise deletes nothing
    await seedPreviousRunImages(['old-orphan']);
    const sweep = await sweepOrphanImagesOnLaunch(UID);
    expect(sweep).toEqual({ referencesRead: false, deleted: [] });
    expect(await imageExists('old-orphan', UID)).toBe(true);
  });

  it('references_readInChunks_yieldsBetween', async () => {
    // 120 conversations: the reference lands in the third chunk, chunk size <= 50, with a macrotask yield between chunks
    for (let index = 0; index < 120; index++) {
      const id = `c-${String(index).padStart(3, '0')}`;
      const attachments = index === 110 ? [imageAttachment('att-kept', 'img-kept')] : [];
      await idb.putConversation(conversationWith(id, attachments));
    }
    await saveImage('img-kept', blob('k'), blob('k-t'), 'image/png', UID);
    await saveImage('img-gone', blob('g'), blob('g-t'), 'image/png', UID);
    const actual = await vi.importActual<typeof import('../idb')>('../idb');
    const events: string[] = [];
    vi.mocked(idb.scanConversationsInChunks).mockImplementationOnce(async (uid, visit, chunkSize) => {
      await actual.scanConversationsInChunks(uid, (chunk) => {
        if (events.length === 0) setTimeout(() => events.push('macrotask'), 0);
        events.push(`chunk:${chunk.length}`);
        visit(chunk);
      }, chunkSize);
    });

    const result = await purgeUnreferencedImages(['img-kept', 'img-gone'], UID);

    expect(result).toEqual({ referencesRead: true, deleted: ['img-gone'] });
    expect(await imageExists('img-kept', UID)).toBe(true);
    expect(events).toEqual(['chunk:50', 'macrotask', 'chunk:50', 'chunk:20']);
  });

  it('purge_coalescesConcurrentRequests', async () => {
    const ids = idsOf('img', 5);
    for (const id of ids) await saveImage(id, blob(id), blob(`${id}-t`), 'image/png', UID);
    vi.clearAllMocks();

    const results = await Promise.all(ids.map((id) => purgeUnreferencedImages([id], UID)));

    expect(vi.mocked(idb.scanConversationsInChunks).mock.calls.length).toBeLessThanOrEqual(2);
    expect(results).toEqual(ids.map((id) => ({ referencesRead: true, deleted: [id] })));
    for (const id of ids) expect(await imageExists(id, UID)).toBe(false);
  });
});
