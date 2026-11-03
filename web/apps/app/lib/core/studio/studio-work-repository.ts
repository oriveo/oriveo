/**
 * Local studio work repository (studio_data_model.v1 repository.rules and versionCasesHarness).
 *
 * - Works live in the partition database; lists and detail only show rows whose
 *   accountPartition equals the active partition and that are not tombstones.
 * - Every change to a synced work field bumps revision, sets updatedAt = now and
 *   syncState = pending in the same transaction; ops that change nothing leave the row untouched.
 * - Deletion removes rows in one multi-store transaction; assets of the removed rows are handed to the
 *   orphan sweeper only after it commits, and a sweeper failure never rolls the deletion back.
 */
import {
  getPartitionDB,
  type StudioRoundRefRow,
  type StudioRoundRow,
  type StudioVersionRow,
  type StudioWorkRow,
} from '../../infra/storage/idb';
import { purgeUnreferencedImages } from '../../infra/storage/image-orphan-sweeper';
import { getActiveUID } from '../../infra/storage/partition';
import { createCanonicalUUID } from '../../utils/id-utils';

export interface StudioWorkDetail {
  work: StudioWorkRow;
  /** Ordered by round index. */
  rounds: StudioRoundRow[];
  /** Ordered by createdAt, then id. */
  versions: StudioVersionRow[];
  /** Grouped by round in round order, then by ref order. */
  refs: StudioRoundRefRow[];
}

export interface CreateStudioWorkInput {
  /** Null or absent creates a new upper-case canonical UUID. */
  id?: string | null;
  source: StudioWorkRow['source'];
  title: string;
  chatConversationId?: string | null;
  chatMessageId?: string | null;
}

export interface StudioWorkRepositoryOptions {
  /** Clock in epoch milliseconds; stored as toISOString(). */
  now?: () => number;
  /** Active partition; defaults to getActiveUID(). */
  partition?: () => string | Promise<string>;
}

export interface StudioWorkRepository {
  /** Returns the existing row unchanged when the id already exists (tombstones are never revived). */
  createWork(input: CreateStudioWorkInput): Promise<StudioWorkRow>;
  rename(workId: string, title: string): Promise<StudioWorkRow | null>;
  setFavorite(workId: string, favorite: boolean): Promise<StudioWorkRow | null>;
  list(): Promise<StudioWorkRow[]>;
  detail(workId: string): Promise<StudioWorkDetail | null>;
  /** Writes the round, its versions and refs in one transaction; false (nothing written) when the work is missing or a tombstone. */
  insertRound(
    round: StudioRoundRow,
    versions: readonly StudioVersionRow[],
    refs: readonly StudioRoundRefRow[],
  ): Promise<boolean>;
  finishRound(workId: string, roundId: string): Promise<StudioWorkRow | null>;
  pick(workId: string, versionId: string): Promise<StudioWorkRow | null>;
  alsoKeep(workId: string, versionId: string): Promise<StudioWorkRow | null>;
  setCurrent(workId: string, versionId: string): Promise<StudioWorkRow | null>;
  resolvePendingPick(workId: string): Promise<StudioWorkRow | null>;
  pendingPickCount(workId: string): Promise<number>;
  versionNumber(workId: string, versionId: string): Promise<number | null>;
  /**
   * Removes the version and its whole subtree (rules 3-6); returns the resulting work row (a tombstone
   * when the work went with it), the stored row unchanged for an unknown version, null for a missing work.
   */
  deleteVersion(workId: string, versionId: string): Promise<StudioWorkRow | null>;
  /** Writes a local tombstone and removes all rows of the work (rule 7); null when the work is missing. */
  deleteWork(workId: string): Promise<StudioWorkRow | null>;
  /** Kept versions below the version (itself excluded) that a deleteVersion would take along. */
  descendantCount(workId: string, versionId: string): Promise<number>;
}

const SYNCED_ROUND_STATUS = new Set(['completed', 'partial', 'failed', 'cancelled', 'interrupted', 'expired']);

type SyncedWorkField = 'title' | 'favorite' | 'currentVersionId' | 'selectedVersionIds' | 'deletedVersionIds' | 'deletedAt';
const SYNCED_WORK_FIELDS: readonly SyncedWorkField[] = [
  'title', 'favorite', 'currentVersionId', 'selectedVersionIds', 'deletedVersionIds', 'deletedAt',
];

const syncedSnapshot = (work: StudioWorkRow) => JSON.stringify(SYNCED_WORK_FIELDS.map((field) => work[field]));

function byCreated(a: StudioVersionRow, b: StudioVersionRow): number {
  if (a.createdAt !== b.createdAt) return a.createdAt < b.createdAt ? -1 : 1;
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

function candidatesOf(versions: readonly StudioVersionRow[], roundId: string): StudioVersionRow[] {
  return versions.filter((version) => version.roundId === roundId).sort(byCreated);
}

const byIndexDesc = (a: StudioRoundRow, b: StudioRoundRow) => b.index - a.index;

/** Rolls back a transaction after a failure; a transaction that already ended is ignored. */
function abortQuietly(tx: { abort(): void; done: Promise<void> }) {
  void tx.done.catch(() => undefined);
  try {
    tx.abort();
  } catch {
    // The transaction already finished (and rolled back on its own).
  }
}

/** Mutable view of a work handed to a version op; kept flags are written back only when they change. */
interface WorkMutation {
  work: StudioWorkRow;
  rounds: StudioRoundRow[];
  versions: StudioVersionRow[];
  changedVersions: Set<StudioVersionRow>;
}

function keep(mutation: WorkMutation, versionId: string) {
  const version = mutation.versions.find((row) => row.id === versionId);
  if (!version) throw new Error(`Studio version ${versionId} is not in work ${mutation.work.id}`);
  if (!version.kept) {
    version.kept = true;
    mutation.changedVersions.add(version);
  }
  if (!mutation.work.selectedVersionIds.includes(versionId)) {
    mutation.work.selectedVersionIds = [...mutation.work.selectedVersionIds, versionId];
  }
}

function pickVersion(mutation: WorkMutation, versionId: string) {
  keep(mutation, versionId);
  mutation.work.currentVersionId = versionId;
}

const STUDIO_STORES = ['studio_works', 'studio_rounds', 'studio_versions', 'studio_round_refs'] as const;

/** The version and every version whose parentVersionId chain reaches it. */
function subtreeOf(versions: readonly StudioVersionRow[], versionId: string): Set<string> {
  const subtree = new Set([versionId]);
  for (let grew = true; grew;) {
    grew = false;
    for (const version of versions) {
      if (!subtree.has(version.id) && version.parentVersionId != null && subtree.has(version.parentVersionId)) {
        subtree.add(version.id);
        grew = true;
      }
    }
  }
  return subtree;
}

/** Rule 6: parent if left, else the latest kept entry not deleted, else the first candidate of the highest round. */
function fallbackCover(
  work: StudioWorkRow,
  removedCurrent: StudioVersionRow | undefined,
  versions: readonly StudioVersionRow[],
  rounds: readonly StudioRoundRow[],
): string | null {
  const left = new Set(versions.map((version) => version.id));
  const parent = removedCurrent?.parentVersionId;
  if (parent != null && left.has(parent)) return parent;
  const kept = [...work.selectedVersionIds].reverse()
    .find((id) => left.has(id) && !work.deletedVersionIds.includes(id));
  if (kept) return kept;
  for (const round of [...rounds].sort(byIndexDesc)) {
    const first = candidatesOf(versions, round.id)[0];
    if (first) return first.id;
  }
  return null;
}

export function createStudioWorkRepository(options: StudioWorkRepositoryOptions = {}): StudioWorkRepository {
  const now = options.now ?? Date.now;
  const nowISO = () => new Date(now()).toISOString();

  async function open() {
    const partition = options.partition ? await options.partition() : await getActiveUID();
    // With the default partition the database must still belong to it when the op runs.
    const db = await getPartitionDB(options.partition ? undefined : partition);
    return { db, partition };
  }

  const isVisible = (work: StudioWorkRow | undefined, partition: string): work is StudioWorkRow =>
    work !== undefined && work.deletedAt == null && work.accountPartition === partition;

  /** Reads a visible work and its rows, applies the op and writes only what changed, in one transaction. */
  async function mutateWork(
    workId: string,
    apply: (mutation: WorkMutation) => void,
  ): Promise<StudioWorkRow | null> {
    const { db, partition } = await open();
    const tx = db.transaction(['studio_works', 'studio_rounds', 'studio_versions'], 'readwrite');
    try {
      const works = tx.objectStore('studio_works');
      const stored = await works.get(workId);
      if (!isVisible(stored, partition)) {
        await tx.done;
        return null;
      }
      const versionStore = tx.objectStore('studio_versions');
      const mutation: WorkMutation = {
        work: { ...stored },
        rounds: await tx.objectStore('studio_rounds').index('by-work').getAll(workId),
        versions: await versionStore.index('by-work').getAll(workId),
        changedVersions: new Set(),
      };
      apply(mutation);
      let result = stored;
      if (syncedSnapshot(mutation.work) !== syncedSnapshot(stored)) {
        result = {
          ...mutation.work,
          revision: stored.revision + 1,
          updatedAt: nowISO(),
          syncState: 'pending',
        };
        await works.put(result);
      }
      for (const version of mutation.changedVersions) await versionStore.put(version);
      await tx.done;
      return result;
    } catch (error) {
      abortQuietly(tx);
      throw error;
    }
  }

  function bumped(stored: StudioWorkRow, next: StudioWorkRow): StudioWorkRow {
    if (syncedSnapshot(next) === syncedSnapshot(stored)) return stored;
    return { ...next, revision: stored.revision + 1, updatedAt: nowISO(), syncState: 'pending' };
  }

  function tombstoneOf(stored: StudioWorkRow): StudioWorkRow {
    return bumped(stored, {
      ...stored,
      title: '',
      favorite: false,
      currentVersionId: null,
      selectedVersionIds: [],
      deletedVersionIds: [],
      deletedAt: nowISO(),
    });
  }

  /** Hands the assets of committed row deletions to the orphan sweeper; failures only log, never roll back. */
  async function reclaim(assetIds: ReadonlySet<string>, partition: string) {
    if (assetIds.size === 0) return;
    try {
      await purgeUnreferencedImages(assetIds, partition);
    } catch (error) {
      console.warn(`[StudioWorkRepository] asset purge failed candidates=${assetIds.size}`, error);
    }
  }

  /**
   * Removes the given versions (the whole work when `wholeWork`), rounds that lost their base or their
   * last version, and their refs, then writes the work row, all in one transaction. Assets are reclaimed
   * after commit.
   */
  async function deleteRows(
    workId: string,
    plan: (state: { work: StudioWorkRow; rounds: StudioRoundRow[]; versions: StudioVersionRow[] }) =>
      { removed: Set<string>; wholeWork: boolean } | null,
  ): Promise<StudioWorkRow | null> {
    const { db, partition } = await open();
    const tx = db.transaction(STUDIO_STORES, 'readwrite');
    const assets = new Set<string>();
    let result: StudioWorkRow;
    try {
      const works = tx.objectStore('studio_works');
      const stored = await works.get(workId);
      if (!isVisible(stored, partition)) {
        await tx.done;
        return null;
      }
      const roundStore = tx.objectStore('studio_rounds');
      const versionStore = tx.objectStore('studio_versions');
      const refStore = tx.objectStore('studio_round_refs');
      const rounds = await roundStore.index('by-work').getAll(workId);
      const versions = await versionStore.index('by-work').getAll(workId);
      const decision = plan({ work: stored, rounds, versions });
      if (!decision) {
        await tx.done;
        return stored;
      }
      const removedVersions = versions.filter((version) => decision.removed.has(version.id));
      const keptVersionLeft = versions.some((version) => version.kept && !decision.removed.has(version.id));
      const wholeWork = decision.wholeWork
        || removedVersions.length === versions.length
        || (removedVersions.some((version) => version.kept) && !keptVersionLeft);
      const leftVersions = wholeWork ? [] : versions.filter((version) => !decision.removed.has(version.id));
      const goneRounds = rounds.filter((round) => wholeWork
        || (round.baseVersionId != null && decision.removed.has(round.baseVersionId))
        || (versions.some((version) => version.roundId === round.id)
          && !leftVersions.some((version) => version.roundId === round.id)));

      if (wholeWork) {
        result = tombstoneOf(stored);
      } else {
        const removedIds = new Set(removedVersions.map((version) => version.id));
        const next: StudioWorkRow = {
          ...stored,
          deletedVersionIds: [
            ...stored.deletedVersionIds,
            ...stored.selectedVersionIds.filter((id) => removedIds.has(id) && !stored.deletedVersionIds.includes(id)),
          ],
        };
        if (stored.currentVersionId != null && removedIds.has(stored.currentVersionId)) {
          const removedCurrent = removedVersions.find((version) => version.id === stored.currentVersionId);
          const goneRoundIds = new Set(goneRounds.map((round) => round.id));
          next.currentVersionId = fallbackCover(
            next, removedCurrent, leftVersions, rounds.filter((round) => !goneRoundIds.has(round.id)),
          );
        }
        result = bumped(stored, next);
      }

      for (const version of wholeWork ? versions : removedVersions) {
        assets.add(version.assetId);
        await versionStore.delete(version.id);
      }
      for (const round of goneRounds) {
        for (const ref of await refStore.index('by-round').getAll(round.id)) {
          assets.add(ref.assetId);
          await refStore.delete([ref.roundId, ref.order]);
        }
        await roundStore.delete(round.id);
      }
      if (result !== stored) await works.put(result);
      await tx.done;
    } catch (error) {
      abortQuietly(tx);
      throw error;
    }
    await reclaim(assets, partition);
    return result;
  }

  async function readWork(workId: string) {
    const { db, partition } = await open();
    const tx = db.transaction(['studio_works', 'studio_rounds', 'studio_versions'], 'readonly');
    const work = await tx.objectStore('studio_works').get(workId);
    if (!isVisible(work, partition)) {
      await tx.done;
      return null;
    }
    const rounds = await tx.objectStore('studio_rounds').index('by-work').getAll(workId);
    const versions = await tx.objectStore('studio_versions').index('by-work').getAll(workId);
    await tx.done;
    return { work, rounds, versions };
  }

  return {
    async createWork(input) {
      const { db, partition } = await open();
      const id = input.id ?? createCanonicalUUID();
      const tx = db.transaction('studio_works', 'readwrite');
      try {
        const existing = await tx.store.get(id);
        if (existing) {
          await tx.done;
          return existing;
        }
        const time = nowISO();
        const work: StudioWorkRow = {
          id,
          title: input.title,
          currentVersionId: null,
          source: input.source,
          chatConversationId: input.chatConversationId ?? null,
          chatMessageId: input.chatMessageId ?? null,
          favorite: false,
          selectedVersionIds: [],
          deletedVersionIds: [],
          createdAt: time,
          updatedAt: time,
          deletedAt: null,
          revision: 1,
          baseRevision: 0,
          accountPartition: partition,
          syncState: 'pending',
        };
        await tx.store.put(work);
        await tx.done;
        return work;
      } catch (error) {
        abortQuietly(tx);
        throw error;
      }
    },

    rename(workId, title) {
      return mutateWork(workId, (mutation) => {
        mutation.work.title = title;
      });
    },

    setFavorite(workId, favorite) {
      return mutateWork(workId, (mutation) => {
        mutation.work.favorite = favorite;
      });
    },

    async list() {
      const { db, partition } = await open();
      const works = await db.getAll('studio_works');
      return works
        .filter((work) => isVisible(work, partition))
        .sort((a, b) => {
          if (a.updatedAt !== b.updatedAt) return a.updatedAt < b.updatedAt ? 1 : -1;
          return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
        });
    },

    async detail(workId) {
      const { db, partition } = await open();
      const tx = db.transaction(['studio_works', 'studio_rounds', 'studio_versions', 'studio_round_refs'], 'readonly');
      const work = await tx.objectStore('studio_works').get(workId);
      if (!isVisible(work, partition)) {
        await tx.done;
        return null;
      }
      const rounds = (await tx.objectStore('studio_rounds').index('by-work').getAll(workId))
        .sort((a, b) => a.index - b.index);
      const versions = (await tx.objectStore('studio_versions').index('by-work').getAll(workId)).sort(byCreated);
      const refIndex = tx.objectStore('studio_round_refs').index('by-round');
      const refs: StudioRoundRefRow[] = [];
      for (const round of rounds) {
        refs.push(...(await refIndex.getAll(round.id)).sort((a, b) => a.order - b.order));
      }
      await tx.done;
      return { work, rounds, versions, refs };
    },

    async insertRound(round, versions, refs) {
      const { db, partition } = await open();
      const tx = db.transaction(['studio_works', 'studio_rounds', 'studio_versions', 'studio_round_refs'], 'readwrite');
      const requests: Promise<unknown>[] = [];
      try {
        const work = await tx.objectStore('studio_works').get(round.workId);
        if (!isVisible(work, partition)) {
          await tx.done;
          return false;
        }
        if (versions.some((version) => version.roundId !== round.id || version.workId !== round.workId)
          || refs.some((ref) => ref.roundId !== round.id)) {
          throw new Error(`Studio round ${round.id} has rows of another round or work`);
        }
        const versionStore = tx.objectStore('studio_versions');
        const refStore = tx.objectStore('studio_round_refs');
        requests.push(tx.objectStore('studio_rounds').put(round));
        for (const version of versions) requests.push(versionStore.put(version));
        for (const ref of refs) requests.push(refStore.put(ref));
      } catch (error) {
        // Requests already issued die with the transaction: settle their rejections, then roll back.
        void Promise.allSettled(requests);
        abortQuietly(tx);
        throw error;
      }
      await Promise.all([...requests, tx.done]);
      return true;
    },

    finishRound(workId, roundId) {
      return mutateWork(workId, (mutation) => {
        const candidates = candidatesOf(mutation.versions, roundId);
        if (candidates.length === 1) {
          pickVersion(mutation, candidates[0]!.id);
        } else if (candidates.length > 1 && mutation.work.currentVersionId == null) {
          mutation.work.currentVersionId = candidates[0]!.id;
        }
      });
    },

    pick(workId, versionId) {
      return mutateWork(workId, (mutation) => pickVersion(mutation, versionId));
    },

    alsoKeep(workId, versionId) {
      return mutateWork(workId, (mutation) => keep(mutation, versionId));
    },

    setCurrent(workId, versionId) {
      return mutateWork(workId, (mutation) => {
        const version = mutation.versions.find((row) => row.id === versionId);
        if (!version?.kept) throw new Error(`Studio version ${versionId} is not a kept version of work ${workId}`);
        mutation.work.currentVersionId = versionId;
      });
    },

    resolvePendingPick(workId) {
      return mutateWork(workId, (mutation) => {
        const latest = mutation.rounds
          .filter((round) => candidatesOf(mutation.versions, round.id).length > 0)
          .sort(byIndexDesc)[0];
        if (!latest) return;
        const candidates = candidatesOf(mutation.versions, latest.id);
        if (candidates.length > 1 && !candidates.some((version) => version.kept)) {
          pickVersion(mutation, candidates[0]!.id);
        }
      });
    },

    async pendingPickCount(workId) {
      const state = await readWork(workId);
      if (!state) return 0;
      const latest = state.rounds.filter((round) => SYNCED_ROUND_STATUS.has(round.status)).sort(byIndexDesc)[0];
      if (!latest) return 0;
      const candidates = candidatesOf(state.versions, latest.id);
      return candidates.length > 1 && !candidates.some((version) => version.kept) ? candidates.length : 0;
    },

    async versionNumber(workId, versionId) {
      const { db, partition } = await open();
      const work = await db.get('studio_works', workId);
      if (!isVisible(work, partition)) return null;
      const position = work.selectedVersionIds.indexOf(versionId);
      return position < 0 ? null : position + 1;
    },

    deleteVersion(workId, versionId) {
      return deleteRows(workId, ({ versions }) => (versions.some((version) => version.id === versionId)
        ? { removed: subtreeOf(versions, versionId), wholeWork: false }
        : null));
    },

    deleteWork(workId) {
      return deleteRows(workId, () => ({ removed: new Set(), wholeWork: true }));
    },

    async descendantCount(workId, versionId) {
      const state = await readWork(workId);
      if (!state?.versions.some((version) => version.id === versionId)) return 0;
      const subtree = subtreeOf(state.versions, versionId);
      return state.versions.filter((version) => version.id !== versionId && version.kept && subtree.has(version.id))
        .length;
    },
  };
}
