/**
 * Shared fixture studio_data_model.v1.json (repository, versionCases, versionCasesHarness):
 * card A cases of the Web studio work repository. Aliases resolve through repository.ids,
 * fixture times are epoch milliseconds stored as toISOString().
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  getPartitionDB,
  resetDBConnection,
  type StudioRoundRefRow,
  type StudioRoundRow,
  type StudioVersionRow,
  type StudioWorkRow,
} from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';
import { createCanonicalUUID } from '../../../utils/id-utils';
import { createStudioWorkRepository } from '../studio-work-repository';

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
interface ListCase {
  caseId: string;
  seed: string;
  op: string;
  expect: string[] | string | null;
}
interface VersionCase {
  caseId: string;
  round: { n: number; delivered: number; previous?: boolean };
  action: string;
  expect: {
    kept?: string[];
    current?: string;
    pendingPick?: number;
    numbers?: Record<string, number>;
    deletedVersionIds?: string[];
  };
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, SHARED_DIR, 'studio-contracts/studio_data_model.v1.json'), 'utf8',
)) as {
  versionCases: VersionCase[];
  repository: {
    ids: Record<string, string>;
    seeds: Record<string, Seed>;
    listCases: ListCase[];
  };
};

const { ids, seeds } = fixture.repository;
const aliasById = new Map(Object.entries(ids).map(([alias, id]) => [id, alias]));
const NOW = 9000;
const STORES = ['studio_works', 'studio_rounds', 'studio_versions', 'studio_round_refs'] as const;

function idOf(alias: string): string {
  const id = ids[alias];
  if (!id) throw new Error(`unknown alias ${alias}`);
  return id;
}
const idOrNull = (alias: string | null) => (alias == null ? null : idOf(alias));
const aliasOf = (id: string) => aliasById.get(id) ?? id;
const iso = (ms: Ms) => new Date(ms).toISOString();

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

async function clearStudioStores() {
  const db = await getPartitionDB();
  for (const store of STORES) await db.clear(store);
}

async function writeSeed(name: string) {
  const seed = seeds[name];
  if (!seed) throw new Error(`unknown seed ${name}`);
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
}

async function storedWork(id: string) {
  return (await getPartitionDB()).get('studio_works', id);
}

const repoFor = (partition: string) => createStudioWorkRepository({ now: () => NOW, partition: () => partition });

async function runVersionCase(c: VersionCase) {
  const repo = repoFor('uid-a');
  const work = await repo.createWork({ source: 'studio', title: 'Version case' });
  const localIds = new Map<string, string>();
  const localAlias = new Map<string, string>();
  const versionIdFor = (alias: string) => {
    const id = ids[alias] ?? createCanonicalUUID();
    localIds.set(alias, id);
    localAlias.set(id, alias);
    return id;
  };
  const versionIdOf = (alias: string) => {
    const id = localIds.get(alias);
    if (!id) throw new Error(`${c.caseId}: unknown version alias ${alias}`);
    return id;
  };
  let clock = 1000;
  let index = 0;
  const addRound = async (status: string, aliases: string[], baseAlias: string | null) => {
    index += 1;
    const baseVersionId = baseAlias == null ? null : versionIdOf(baseAlias);
    const round = makeRound({ id: createCanonicalUUID(), workId: work.id, index, baseVersionId, status });
    const versions = aliases.map((alias) => {
      clock += 1;
      return makeVersion({
        id: versionIdFor(alias),
        roundId: round.id,
        workId: work.id,
        parentVersionId: baseVersionId,
        assetId: createCanonicalUUID(),
        kept: false,
        createdAt: clock,
      });
    });
    expect(await repo.insertRound(round, versions, []), c.caseId).toBe(true);
    return round.id;
  };

  let testCandidates: string[] = [];
  const steps = c.action.split(';');
  if (steps[0]?.startsWith('keep_order:')) {
    const order = steps.shift()!.slice('keep_order:['.length, -1).split(',');
    for (const alias of order) {
      const roundId = await addRound('completed', [alias], null);
      await repo.finishRound(work.id, roundId);
    }
  } else {
    if (c.round.previous) {
      const roundId = await addRound('completed', ['P'], null);
      await repo.finishRound(work.id, roundId);
    }
    const { n, delivered } = c.round;
    const status = delivered === n ? 'completed' : delivered > 0 ? 'partial' : 'failed';
    const candidates = Array.from({ length: delivered }, (_, i) => `c${i + 1}`);
    const roundId = await addRound(status, candidates, c.round.previous ? 'P' : null);
    testCandidates = candidates.map(versionIdOf);
    await repo.finishRound(work.id, roundId);
  }
  for (const step of steps.flatMap((s) => s.split(','))) {
    if (step === 'finish') continue;
    if (step === 'start_next_round') await repo.resolvePendingPick(work.id);
    else if (step.startsWith('pick:')) await repo.pick(work.id, versionIdOf(step.slice(5)));
    else if (step.startsWith('also:')) await repo.alsoKeep(work.id, versionIdOf(step.slice(5)));
    else if (step.startsWith('delete:')) await repo.deleteVersion(work.id, versionIdOf(step.slice(7)));
    else throw new Error(`${c.caseId}: unsupported step ${step}`);
  }

  const detail = await repo.detail(work.id);
  expect(detail, c.caseId).not.toBeNull();
  const w = detail!.work;
  const handled = new Set(['kept', 'current', 'pendingPick', 'numbers', 'deletedVersionIds']);
  expect(Object.keys(c.expect).filter((key) => !handled.has(key)), c.caseId).toEqual([]);
  if (c.expect.kept) {
    const kept = w.selectedVersionIds.filter((id) => testCandidates.includes(id));
    expect(kept.map((id) => localAlias.get(id)), c.caseId).toEqual(c.expect.kept);
    const keptRows = detail!.versions.filter((v) => v.kept && testCandidates.includes(v.id)).map((v) => v.id);
    expect(new Set(keptRows), c.caseId).toEqual(new Set(kept));
  }
  if (c.expect.current !== undefined) {
    expect(w.currentVersionId && localAlias.get(w.currentVersionId), c.caseId).toBe(c.expect.current);
  }
  if (c.expect.pendingPick !== undefined) {
    expect(await repo.pendingPickCount(work.id), c.caseId).toBe(c.expect.pendingPick);
  }
  if (c.expect.deletedVersionIds) {
    expect(w.deletedVersionIds.map((id) => localAlias.get(id)), c.caseId).toEqual(c.expect.deletedVersionIds);
  }
  for (const [alias, number] of Object.entries(c.expect.numbers ?? {})) {
    expect(await repo.versionNumber(work.id, versionIdOf(alias)), `${c.caseId} ${alias}`).toBe(number);
  }
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('studio_data_model.v1 repository (card A)', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('uid-a');
  });

  it('versionCases_matchFixture', async () => {
    let ran = 0;
    for (const c of fixture.versionCases) {
      await clearStudioStores();
      await runVersionCase(c);
      ran += 1;
    }
    expect(ran).toBeGreaterThan(0);
  });

  it('listCases_matchFixture', async () => {
    expect(fixture.repository.listCases.length).toBeGreaterThan(0);
    for (const c of fixture.repository.listCases) {
      await clearStudioStores();
      await writeSeed(c.seed);
      const [kind, partition, alias] = c.op.split(':');
      const repo = repoFor(partition!);
      if (kind === 'list') {
        const works = await repo.list();
        expect(works.map((w) => aliasOf(w.id)), c.caseId).toEqual(c.expect);
      } else if (kind === 'get') {
        const detail = await repo.detail(idOf(alias!));
        expect(detail ? aliasOf(detail.work.id) : null, c.caseId).toEqual(c.expect);
      } else {
        throw new Error(`${c.caseId}: unsupported op ${c.op}`);
      }
    }
  });

  it('createWork_defaults', async () => {
    const repo = repoFor('uid-a');
    const work = await repo.createWork({ source: 'studio', title: 'Sunset' });
    expect(work.id).toMatch(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);
    expect(work).toStrictEqual({
      id: work.id,
      title: 'Sunset',
      currentVersionId: null,
      source: 'studio',
      chatConversationId: null,
      chatMessageId: null,
      favorite: false,
      selectedVersionIds: [],
      deletedVersionIds: [],
      createdAt: iso(NOW),
      updatedAt: iso(NOW),
      deletedAt: null,
      revision: 1,
      baseRevision: 0,
      accountPartition: 'uid-a',
      syncState: 'pending',
    });
    expect(await storedWork(work.id)).toStrictEqual(work);

    const chat = await repo.createWork({
      id: idOf('W'), source: 'chat', title: 'Chat image', chatConversationId: 'CONV-1', chatMessageId: 'MSG-1',
    });
    expect(chat).toMatchObject({
      id: idOf('W'), source: 'chat', chatConversationId: 'CONV-1', chatMessageId: 'MSG-1', revision: 1,
    });
    expect(await storedWork(idOf('W'))).toStrictEqual(chat);
  });

  it('createWork_existingIdNoRevive', async () => {
    await writeSeed('list');
    const repo = repoFor('uid-a');
    for (const alias of ['W3', 'W']) {
      const before = await storedWork(idOf(alias));
      expect(before, alias).toBeDefined();
      const result = await repo.createWork({ id: idOf(alias), source: 'chat', title: 'Revived' });
      expect(result, alias).toStrictEqual(before);
      expect(await storedWork(idOf(alias)), alias).toStrictEqual(before);
    }
    expect((await storedWork(idOf('W3')))?.deletedAt).not.toBeNull();
  });

  it('rename_sameValueNoop', async () => {
    await writeSeed('main');
    const repo = repoFor('uid-a');
    const before = (await storedWork(idOf('W')))!;
    await repo.rename(before.id, before.title);
    await repo.setFavorite(before.id, before.favorite);
    expect(await storedWork(before.id)).toStrictEqual(before);

    await repo.rename(before.id, 'Morning tea');
    expect(await storedWork(before.id)).toStrictEqual({
      ...before,
      title: 'Morning tea',
      revision: before.revision + 1,
      updatedAt: iso(NOW),
      syncState: 'pending',
    });
  });

  it('insertRound_rejectsTombstone', async () => {
    await writeSeed('list');
    const repo = repoFor('uid-a');
    const db = await getPartitionDB();
    const tombstone = (await storedWork(idOf('W3')))!;
    const roundFor = (workId: string) => makeRound({
      id: createCanonicalUUID(), workId, index: 1, baseVersionId: null, status: 'completed',
    });
    const versionFor = (round: StudioRoundRow) => makeVersion({
      id: createCanonicalUUID(), roundId: round.id, workId: round.workId, parentVersionId: null,
      assetId: createCanonicalUUID(), kept: false, createdAt: 1001,
    });
    const refFor = (round: StudioRoundRow): StudioRoundRefRow => ({
      roundId: round.id, order: 0, assetId: createCanonicalUUID(), role: 'subject',
    });

    for (const workId of [tombstone.id, createCanonicalUUID()]) {
      const round = roundFor(workId);
      expect(await repo.insertRound(round, [versionFor(round)], [refFor(round)]), workId).toBe(false);
      for (const store of ['studio_rounds', 'studio_versions', 'studio_round_refs'] as const) {
        expect(await db.count(store), `${workId} ${store}`).toBe(0);
      }
    }
    expect(await storedWork(tombstone.id)).toStrictEqual(tombstone);

    const live = idOf('W');
    const round = roundFor(live);
    const version = versionFor(round);
    const ref = refFor(round);
    expect(await repo.insertRound(round, [version], [ref])).toBe(true);
    const detail = await repo.detail(live);
    expect(detail?.rounds).toStrictEqual([round]);
    expect(detail?.versions).toStrictEqual([version]);
    expect(detail?.refs).toStrictEqual([ref]);
  });
});
