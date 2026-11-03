/**
 * Shared fixture studio_data_model.v1.json (repository.deleteCases): deletion cases of the Web
 * studio work repository. Every case seeds its rows and an image for every seeded asset in the
 * active partition, then checks rows, work fields and which assets the orphan sweeper reclaimed.
 * Aliases resolve through repository.ids; fixture times are epoch milliseconds stored as
 * toISOString().
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import type { Attachment, ChatMessage, Conversation } from '@oriveo/shared';
import type { BackupFile } from '../../../backup';
import {
  getPartitionDB,
  putConversation,
  resetDBConnection,
  type StudioRoundRefRow,
  type StudioRoundRow,
  type StudioVersionRow,
  type StudioWorkRow,
} from '../../../infra/storage/idb';
import { imageExists, resetImageDBConnection, saveImage } from '../../../infra/storage/image-store';
import { setActiveUID } from '../../../infra/storage/partition';
import { createCanonicalUUID } from '../../../utils/id-utils';
import { createStudioWorkRepository } from '../studio-work-repository';

if (typeof Blob.prototype.arrayBuffer !== 'function') {
  Blob.prototype.arrayBuffer = function () {
    return new Promise((resolvePromise, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolvePromise(reader.result as ArrayBuffer);
      reader.onerror = reject;
      reader.readAsArrayBuffer(this);
    });
  };
}

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', { value: nodeCrypto.webcrypto, writable: true, configurable: true });
}

const { generateImportPreview, executeImport } = await import('../../../backup');
const { canonicalJSON } = await import('../../../backup/backup-format');
const { sha256hex } = await import('../../../backup/backup-crypto');

const ROOT = resolve(__dirname, '../../../../../../../..');
const SHARED_DIR = String.fromCharCode(0x5171, 0x4eab);

type Ms = number;

interface SeedWork extends Omit<StudioWorkRow, 'createdAt' | 'updatedAt' | 'deletedAt'> {
  createdAt: Ms;
  updatedAt: Ms;
  deletedAt: Ms | null;
}
interface SeedRound {
  id: string;
  workId: string;
  index: number;
  baseVersionId: string | null;
  status: string;
}
interface SeedVersion {
  id: string;
  roundId: string;
  workId: string;
  parentVersionId: string | null;
  assetId: string;
  kept: boolean;
  createdAt: Ms;
}
interface Seed {
  works: SeedWork[];
  rounds: SeedRound[];
  versions: SeedVersion[];
  refs: StudioRoundRefRow[];
}
interface DeleteCase {
  caseId: string;
  seed: string;
  ops: string[];
  before?: { descendants?: Record<string, number> };
  expect: {
    tombstone: boolean;
    title?: string;
    favorite?: boolean;
    source?: string;
    chatConversationId?: string | null;
    chatMessageId?: string | null;
    currentVersionId: string | null;
    selectedVersionIds: string[];
    deletedVersionIds: string[];
    deletedAt?: Ms;
    updatedAt?: Ms;
    revision: number;
    syncState: string;
    versions: string[];
    rounds: string[];
    reclaimedAssets: string[];
    numbers?: Record<string, number>;
  };
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, SHARED_DIR, 'studio-contracts/studio_data_model.v1.json'), 'utf8',
)) as {
  repository: {
    ids: Record<string, string>;
    seeds: Record<string, Seed>;
    deleteCases: DeleteCase[];
  };
};

const { ids, seeds } = fixture.repository;
const aliasById = new Map(Object.entries(ids).map(([alias, id]) => [id, alias]));
const NOW = 9000;
const UID = 'uid-a';
const STORES = ['studio_works', 'studio_rounds', 'studio_versions', 'studio_round_refs'] as const;

function idOf(alias: string): string {
  const id = ids[alias];
  if (!id) throw new Error(`unknown alias ${alias}`);
  return id;
}
const idOrNull = (alias: string | null) => (alias == null ? null : idOf(alias));
const aliasOf = (id: string) => aliasById.get(id) ?? id;
const iso = (ms: Ms) => new Date(ms).toISOString();
const sortedAliases = (rowIds: readonly string[]) => rowIds.map(aliasOf).sort();

function seedOf(name: string): Seed {
  const seed = seeds[name];
  if (!seed) throw new Error(`unknown seed ${name}`);
  return seed;
}

function makeRound(fields: SeedRound): StudioRoundRow {
  return {
    ...fields,
    operation: fields.baseVersionId == null ? 'generate' : 'edit',
    prompt: 'case prompt',
    composedPrompt: null,
    enhancedPrompt: null,
    presetIds: [],
    params: {},
    modelRef: null,
    errorKind: null,
    adjustments: null,
    nRequested: 1,
    nDelivered: 1,
    costEstimateUsd: null,
    chargedUsd: null,
    fundingSource: 'byok',
    managedJobId: null,
    clientJobId: null,
    startedAt: null,
    finishedAt: null,
  };
}

function makeVersion(fields: SeedVersion): StudioVersionRow {
  return { ...fields, createdAt: iso(fields.createdAt), width: 1024, height: 1024, mime: 'image/png' };
}

/** Writes the seed rows and saves an image for every asset the seed mentions; returns those asset ids. */
async function writeSeed(name: string): Promise<string[]> {
  const seed = seedOf(name);
  const db = await getPartitionDB();
  for (const w of seed.works) {
    await db.put('studio_works', {
      ...w,
      id: idOf(w.id),
      currentVersionId: idOrNull(w.currentVersionId),
      selectedVersionIds: w.selectedVersionIds.map(idOf),
      deletedVersionIds: w.deletedVersionIds.map(idOf),
      createdAt: iso(w.createdAt),
      updatedAt: iso(w.updatedAt),
      deletedAt: w.deletedAt == null ? null : iso(w.deletedAt),
    });
  }
  for (const r of seed.rounds) {
    await db.put('studio_rounds', makeRound({
      ...r, id: idOf(r.id), workId: idOf(r.workId), baseVersionId: idOrNull(r.baseVersionId),
    }));
  }
  for (const v of seed.versions) {
    await db.put('studio_versions', makeVersion({
      ...v,
      id: idOf(v.id),
      roundId: idOf(v.roundId),
      workId: idOf(v.workId),
      parentVersionId: idOrNull(v.parentVersionId),
      assetId: idOf(v.assetId),
    }));
  }
  for (const ref of seed.refs) {
    await db.put('studio_round_refs', { ...ref, roundId: idOf(ref.roundId), assetId: idOf(ref.assetId) });
  }
  const assets = [...new Set([...seed.versions, ...seed.refs].map((row) => idOf(row.assetId)))];
  for (const assetId of assets) {
    await saveImage(assetId, new Blob([assetId], { type: 'image/png' }), null, 'image/png', UID);
  }
  return assets;
}

async function snapshotStudioStores() {
  const db = await getPartitionDB();
  const snapshot: Record<string, unknown[]> = {};
  for (const store of STORES) snapshot[store] = await db.getAll(store);
  return snapshot;
}

async function expectAssets(assets: readonly string[], present: boolean, label: string) {
  for (const assetId of assets) {
    expect(await imageExists(assetId, UID), `${label} ${aliasOf(assetId)}`).toBe(present);
  }
}

async function resetAll() {
  resetDBConnection();
  resetImageDBConnection();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
  await setActiveUID(UID);
}

const repoFor = () => createStudioWorkRepository({ now: () => NOW, partition: () => UID });

const EXPECT_KEYS = new Set([
  'tombstone', 'title', 'favorite', 'source', 'chatConversationId', 'chatMessageId', 'currentVersionId',
  'selectedVersionIds', 'deletedVersionIds', 'deletedAt', 'updatedAt', 'revision', 'syncState',
  'versions', 'rounds', 'reclaimedAssets', 'numbers',
]);

async function runDeleteCase(c: DeleteCase) {
  const assets = await writeSeed(c.seed);
  const seed = seedOf(c.seed);
  expect(seed.works.length, c.caseId).toBe(1);
  const workId = idOf(seed.works[0]!.id);
  const repo = repoFor();

  for (const [alias, count] of Object.entries(c.before?.descendants ?? {})) {
    expect(await repo.descendantCount(workId, idOf(alias)), `${c.caseId} descendants ${alias}`).toBe(count);
  }
  for (const op of c.ops) {
    const [kind, alias] = op.split(':');
    if (kind === 'deleteVersion') await repo.deleteVersion(workId, idOf(alias!));
    else if (kind === 'deleteWork') await repo.deleteWork(workId);
    else if (kind === 'setCurrent') await repo.setCurrent(workId, idOf(alias!));
    else if (kind === 'alsoKeep') await repo.alsoKeep(workId, idOf(alias!));
    else throw new Error(`${c.caseId}: unsupported op ${op}`);
  }

  const e = c.expect;
  expect(Object.keys(e).filter((key) => !EXPECT_KEYS.has(key)), c.caseId).toEqual([]);
  const db = await getPartitionDB();
  const work = (await db.get('studio_works', workId))!;
  expect(work, c.caseId).toBeDefined();
  expect(work.deletedAt != null, `${c.caseId} tombstone`).toBe(e.tombstone);
  expect(await repo.detail(workId) == null, `${c.caseId} detail hidden`).toBe(e.tombstone);
  expect(work.currentVersionId && aliasOf(work.currentVersionId), `${c.caseId} current`).toBe(e.currentVersionId);
  expect(work.selectedVersionIds.map(aliasOf), `${c.caseId} selected`).toEqual(e.selectedVersionIds);
  expect(work.deletedVersionIds.map(aliasOf), `${c.caseId} deleted`).toEqual(e.deletedVersionIds);
  expect(work.revision, `${c.caseId} revision`).toBe(e.revision);
  expect(work.syncState, `${c.caseId} syncState`).toBe(e.syncState);
  for (const field of ['title', 'favorite', 'source', 'chatConversationId', 'chatMessageId'] as const) {
    if (e[field] !== undefined) expect(work[field], `${c.caseId} ${field}`).toBe(e[field]);
  }
  if (e.deletedAt !== undefined) expect(work.deletedAt, `${c.caseId} deletedAt`).toBe(iso(e.deletedAt));
  if (e.updatedAt !== undefined) expect(work.updatedAt, `${c.caseId} updatedAt`).toBe(iso(e.updatedAt));

  const versions = await db.getAllFromIndex('studio_versions', 'by-work', workId);
  const rounds = await db.getAllFromIndex('studio_rounds', 'by-work', workId);
  expect(sortedAliases(versions.map((v) => v.id)), `${c.caseId} versions`).toEqual([...e.versions].sort());
  expect(sortedAliases(rounds.map((r) => r.id)), `${c.caseId} rounds`).toEqual([...e.rounds].sort());
  const seededRounds = new Set(seed.rounds.map((r) => idOf(r.id)));
  const liveRounds = new Set(rounds.map((r) => r.id));
  const refs = (await db.getAll('studio_round_refs')).filter((ref) => seededRounds.has(ref.roundId));
  expect(refs.filter((ref) => !liveRounds.has(ref.roundId)), `${c.caseId} orphan refs`).toEqual([]);

  const reclaimed = new Set(e.reclaimedAssets.map(idOf));
  await expectAssets([...reclaimed], false, `${c.caseId} reclaimed`);
  await expectAssets(assets.filter((assetId) => !reclaimed.has(assetId)), true, `${c.caseId} kept`);

  for (const [alias, number] of Object.entries(e.numbers ?? {})) {
    expect(await repo.versionNumber(workId, idOf(alias)), `${c.caseId} number ${alias}`).toBe(number);
  }
}

function chatImageConversation(id: string, localImageID: string): Conversation {
  const attachment: Attachment = {
    id: `${id}-att`, kind: 'image', fileName: 'chat.png', mimeType: 'image/png', localImageID,
  };
  const message = {
    id: `${id}-m1`, role: 'user', text: 'hi', createdAt: iso(1000), attachments: [attachment],
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
    updatedAt: iso(1000),
  };
}

/** Hand-written backup without any studio data, imported through the production preview + import path. */
async function importReplaceAllWithoutStudio() {
  const data = { providers: [], conversations: [] } as unknown as BackupFile['data'];
  const checksum = await sha256hex(new TextEncoder().encode(canonicalJSON(data)));
  const backupFile: BackupFile = {
    version: 1,
    createdAt: '2026-11-03T00:00:00Z',
    appVersion: '1.0.0',
    platform: 'iOS',
    checksum: `sha256:${checksum}`,
    containsKeys: false,
    data,
    encryptedKeys: null,
  };
  const preview = await generateImportPreview(backupFile, new Map());
  expect(preview.checksumValid).toBe(true);
  await executeImport(preview, 'replaceAll');
}

describe('studio_data_model.v1 repository deletion (card B)', () => {
  beforeEach(resetAll);

  it('deleteCases_matchFixture', async () => {
    expect(fixture.repository.deleteCases.length).toBeGreaterThan(0);
    for (const c of fixture.repository.deleteCases) {
      await resetAll();
      await runDeleteCase(c);
    }
  });

  it('deleteVersion_unknownIdNoop', async () => {
    const assets = await writeSeed('main');
    const repo = repoFor();
    const workId = idOf('W');
    const before = await snapshotStudioStores();

    expect(await repo.descendantCount(workId, createCanonicalUUID())).toBe(0);
    expect(await repo.deleteVersion(workId, createCanonicalUUID())).toStrictEqual(before.studio_works![0]);
    expect(await repo.deleteVersion(createCanonicalUUID(), idOf('V3'))).toBeNull();
    expect(await repo.deleteWork(createCanonicalUUID())).toBeNull();

    expect(await snapshotStudioStores()).toStrictEqual(before);
    await expectAssets(assets, true, 'unknown id');
  });

  it('backupReplaceAll_keepsStudioRowsAndAssets', async () => {
    const assets = await writeSeed('main');
    const chatImage = createCanonicalUUID();
    await saveImage(chatImage, new Blob(['chat'], { type: 'image/png' }), null, 'image/png', UID);
    await putConversation(chatImageConversation(createCanonicalUUID(), chatImage));
    const before = await snapshotStudioStores();

    await importReplaceAllWithoutStudio();

    // The replace path did clear the chat data it owns, so the studio rows really went through it.
    expect(await imageExists(chatImage, UID)).toBe(false);
    expect(await snapshotStudioStores()).toStrictEqual(before);
    await expectAssets(assets, true, 'after replaceAll');
  });
});
