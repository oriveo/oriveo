import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
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

const ROOT = resolve(__dirname, '../../../../../../../..');

interface StudioOrphanSweepCase {
  chatAssets: string[];
  studioVersions: string[];
  studioRefs: string[];
  onDisk: string[];
  expectOrphans: string[];
}

const studioModel = JSON.parse(readFileSync(
  resolve(ROOT, '\u5171\u4eab/studio-contracts/studio_data_model.v1.json'), 'utf8',
)) as { orphanSweep: { case: StudioOrphanSweepCase } };
const STUDIO_CASE = studioModel.orphanSweep.case;

function chatConversationFor(assetIds: string[]): Conversation {
  return conversationWith('c-chat', assetIds.map((id) => imageAttachment(`att-${id}`, id)));
}

/** Writes studio rows straight into the partition DB (no studio write API exists yet). */
async function seedStudioRows(testCase: StudioOrphanSweepCase, uid: string = UID) {
  // Create the partition DB at the current schema through the normal entry point first.
  await idb.putConversation(chatConversationFor(testCase.chatAssets));
  const { openDB } = await import('idb');
  const { getDBName } = await import('../partition');
  const db = await openDB(getDBName(uid));
  expect(db.objectStoreNames.contains('studio_versions'), 'studio_versions store exists').toBe(true);
  expect(db.objectStoreNames.contains('studio_round_refs'), 'studio_round_refs store exists').toBe(true);
  // Only the first version is kept; the rest are candidates, which still count as references.
  for (const [index, assetId] of testCase.studioVersions.entries()) {
    await db.put('studio_versions', {
      id: `version-${index}`,
      roundId: 'round-1',
      workId: 'work-1',
      parentVersionId: null,
      assetId,
      width: 1024,
      height: 1024,
      mime: 'image/png',
      kept: index === 0,
      createdAt: new Date().toISOString(),
    });
  }
  for (const [order, assetId] of testCase.studioRefs.entries()) {
    await db.put('studio_round_refs', { roundId: 'round-1', order, assetId, role: 'subject' });
  }
  db.close();
}

describe('studio_data_model.v1 orphanSweep', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    idb.resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    UID = `user-sweep-${++uidSeq}`;
    await setActiveUID(UID);
  });

  it('launch_sweep_keeps_studio_versions_and_round_refs', async () => {
    await seedStudioRows(STUDIO_CASE);
    await seedPreviousRunImages(STUDIO_CASE.onDisk);

    const result = await sweepOrphanImagesOnLaunch(UID);

    expect(result).toEqual({ referencesRead: true, deleted: STUDIO_CASE.expectOrphans });
    for (const id of STUDIO_CASE.onDisk) {
      expect(await imageExists(id, UID), id).toBe(!STUDIO_CASE.expectOrphans.includes(id));
    }
  });

  it('purge_keeps_studio_versions_and_round_refs', async () => {
    await seedStudioRows(STUDIO_CASE);
    await seedPreviousRunImages(STUDIO_CASE.onDisk);

    const result = await purgeUnreferencedImages(STUDIO_CASE.onDisk, UID);

    expect(result).toEqual({ referencesRead: true, deleted: STUDIO_CASE.expectOrphans });
    for (const id of STUDIO_CASE.onDisk) {
      expect(await imageExists(id, UID), id).toBe(!STUDIO_CASE.expectOrphans.includes(id));
    }
  });

  it('missing_studio_stores_contribute_no_references_and_sweep_runs', async () => {
    // A partition DB at the current version without the studio stores.
    const { openDB } = await import('idb');
    const { getDBName } = await import('../partition');
    const db = await openDB(getDBName(UID), idb.DB_VERSION, {
      upgrade(database) {
        const conversations = database.createObjectStore('conversations', { keyPath: 'id' });
        conversations.createIndex('by-updated', 'updatedAt');
      },
    });
    await db.put('conversations', chatConversationFor(STUDIO_CASE.chatAssets));
    db.close();
    await seedPreviousRunImages(STUDIO_CASE.onDisk);

    const result = await sweepOrphanImagesOnLaunch(UID);

    const expected = STUDIO_CASE.onDisk.filter((id) => !STUDIO_CASE.chatAssets.includes(id));
    expect(result).toEqual({ referencesRead: true, deleted: expected });
    for (const id of STUDIO_CASE.chatAssets) expect(await imageExists(id, UID), id).toBe(true);
  });

  it('studio_corruptRow_aborts', async () => {
    await seedStudioRows(STUDIO_CASE);
    await seedPreviousRunImages(STUDIO_CASE.onDisk);
    const versionBase = { id: 'version-corrupt', roundId: 'round-1', workId: 'work-1', kept: false };
    const refBase = { roundId: 'round-1', order: 99, role: 'subject' };
    const corruptRows: Array<{ store: 'studio_versions' | 'studio_round_refs'; row: Record<string, unknown> }> = [
      { store: 'studio_versions', row: { ...versionBase } },
      { store: 'studio_versions', row: { ...versionBase, assetId: 42 } },
      { store: 'studio_versions', row: { ...versionBase, assetId: '' } },
      { store: 'studio_round_refs', row: { ...refBase } },
      { store: 'studio_round_refs', row: { ...refBase, assetId: null } },
    ];
    const { openDB } = await import('idb');
    const { getDBName } = await import('../partition');

    for (const { store, row } of corruptRows) {
      const label = `${store} ${JSON.stringify(row)}`;
      const seedDB = await openDB(getDBName(UID));
      await seedDB.put(store, row);
      seedDB.close();
      idb.resetDBConnection();

      const result = await purgeUnreferencedImages(STUDIO_CASE.onDisk, UID);

      expect(result, label).toEqual({ referencesRead: false, deleted: [] });
      for (const id of STUDIO_CASE.onDisk) expect(await imageExists(id, UID), `${label} ${id}`).toBe(true);
      idb.resetDBConnection();
      const cleanupDB = await openDB(getDBName(UID));
      await cleanupDB.delete(store, store === 'studio_versions' ? 'version-corrupt' : ['round-1', 99]);
      cleanupDB.close();
      idb.resetDBConnection();
    }
  });

  it('studio_readError_aborts', async () => {
    await seedStudioRows(STUDIO_CASE);
    await seedPreviousRunImages(STUDIO_CASE.onDisk);
    const originalGetAll = IDBObjectStore.prototype.getAll;
    const getAll = vi.spyOn(IDBObjectStore.prototype, 'getAll').mockImplementation(
      function (this: IDBObjectStore, ...args: Parameters<IDBObjectStore['getAll']>) {
        if (this.name === 'studio_versions') throw new Error('studio read failed');
        return originalGetAll.apply(this, args);
      },
    );

    try {
      const result = await purgeUnreferencedImages(STUDIO_CASE.onDisk, UID);

      expect(result).toEqual({ referencesRead: false, deleted: [] });
      expect(getAll.mock.contexts.some((store) => (store as IDBObjectStore).name === 'studio_versions')).toBe(true);
    } finally {
      getAll.mockRestore();
    }
    for (const id of STUDIO_CASE.onDisk) expect(await imageExists(id, UID), id).toBe(true);
  });

  it('studio_partitionSwitchDuringStudioRead_aborts', async () => {
    await seedStudioRows(STUDIO_CASE);
    await seedPreviousRunImages(STUDIO_CASE.onDisk);
    const otherUID = `${UID}-switched`;
    const actual = await vi.importActual<typeof import('../idb')>('../idb');
    // Studio rows are already read when the conversation scan starts; switch the partition right there.
    vi.mocked(idb.scanConversationsInChunks).mockImplementationOnce(async (uid, visit, chunkSize) => {
      await setActiveUID(otherUID);
      await actual.scanConversationsInChunks(uid, visit, chunkSize);
    });

    const result = await purgeUnreferencedImages(STUDIO_CASE.onDisk, UID);

    expect(result).toEqual({ referencesRead: false, deleted: [] });
    await setActiveUID(UID);
    for (const id of STUDIO_CASE.onDisk) expect(await imageExists(id, UID), id).toBe(true);
  });
});
