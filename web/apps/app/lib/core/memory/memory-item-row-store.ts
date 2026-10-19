/**
 * Local row storage for memory items: a thin wrapper over the per-uid IndexedDB partition,
 * plus the exclusive lock that serializes read-modify-write sequences.
 */

import {
  getAllMemoryItemRows,
  getMemoryItemRow,
  putMemoryItemRows,
  putMemoryItemRowsConsumingCandidates,
  type MemoryItemRow,
} from '../../infra/storage/memory-item-store';

/** What the repository requires of local rows. The production implementation uses the uid-bound IndexedDB partition. */
export interface MemoryItemRowStore {
  all(): Promise<MemoryItemRow[]>;
  get(id: string): Promise<MemoryItemRow | undefined>;
  put(rows: readonly MemoryItemRow[]): Promise<void>;
  /** Writes item rows and deletes these candidate rows in one transaction; stores without it cannot accept candidates. */
  putConsumingCandidates?(rows: readonly MemoryItemRow[], candidateIds: readonly string[]): Promise<void>;
  /** Runs a read-modify-write sequence serially on this store. Must not be nested. */
  exclusive<T>(op: () => Promise<T>): Promise<T>;
}

function createExclusive(): <T>(op: () => Promise<T>) => Promise<T> {
  let tail: Promise<unknown> = Promise.resolve();
  return <T>(op: () => Promise<T>) => {
    const run = tail.then(op, op);
    tail = run.catch(() => undefined);
    return run;
  };
}

/** Every caller for the same uid must share one lock. */
const idbLocks = new Map<string, <T>(op: () => Promise<T>) => Promise<T>>();

export function createIdbMemoryItemRowStore(uid: string): MemoryItemRowStore {
  let exclusive = idbLocks.get(uid);
  if (!exclusive) {
    exclusive = createExclusive();
    idbLocks.set(uid, exclusive);
  }
  return {
    all: () => getAllMemoryItemRows(uid),
    get: (id) => getMemoryItemRow(id, uid),
    put: (rows) => putMemoryItemRows(rows, uid),
    putConsumingCandidates: (rows, candidateIds) => putMemoryItemRowsConsumingCandidates(rows, candidateIds, uid),
    exclusive,
  };
}
