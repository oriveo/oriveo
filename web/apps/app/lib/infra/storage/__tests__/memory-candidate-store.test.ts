import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import type { MemoryCandidateRecord, MemoryCandidateStatus } from '@oriveo/core/context/memory-intent';
import { resetDBConnection } from '../idb';
import {
  deleteMemoryCandidateRows,
  getAllMemoryCandidateRows,
  getMemoryCandidateRow,
  putMemoryCandidateRows,
  type MemoryCandidateRow,
} from '../memory-candidate-store';
import { setActiveUID } from '../partition';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function makeRow(id: string, status: MemoryCandidateStatus = 'pending'): MemoryCandidateRow {
  const candidate = {
    id,
    status,
    proposedLayer: 'semantic',
    proposedKind: 'preference',
    content: `\u5185\u5bb9 ${id}`,
    scope: { type: 'global' },
    source: { type: 'conversation', conversationId: 'c1', messageIds: ['m1'], observedAtMs: 1_000 },
    sensitivity: 'normal',
    confidence: 0.9,
    fingerprint: `fp-${id}`,
    createdAtMs: 1_000,
    expiresAtMs: 2_000,
    resolvedAtMs: null,
  } as unknown as MemoryCandidateRecord;
  return { id, status, candidate };
}

describe('memory-candidate-store', () => {
  beforeEach(async () => {
    resetDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('put / get / list / delete round-trip', async () => {
    await putMemoryCandidateRows([makeRow('a'), makeRow('b', 'rejected')]);

    expect(await getMemoryCandidateRow('a')).toEqual(makeRow('a'));
    expect((await getAllMemoryCandidateRows()).map((row) => row.id).sort()).toEqual(['a', 'b']);

    // Writing the same id overwrites.
    await putMemoryCandidateRows([makeRow('a', 'rejected')]);
    expect((await getMemoryCandidateRow('a'))?.status).toBe('rejected');
    expect((await getMemoryCandidateRow('a'))?.candidate.status).toBe('rejected');

    await deleteMemoryCandidateRows(['a', 'missing']);
    expect(await getMemoryCandidateRow('a')).toBeUndefined();
    expect((await getAllMemoryCandidateRows()).map((row) => row.id)).toEqual(['b']);
  });

  it('empty put / delete are no-ops', async () => {
    await putMemoryCandidateRows([]);
    await deleteMemoryCandidateRows([]);
    expect(await getAllMemoryCandidateRows()).toEqual([]);
  });

  it('rows are isolated per partition', async () => {
    await setActiveUID('user-a');
    await putMemoryCandidateRows([makeRow('a')]);

    await setActiveUID('user-b');
    expect(await getAllMemoryCandidateRows()).toEqual([]);
    expect(await getMemoryCandidateRow('a')).toBeUndefined();
    await putMemoryCandidateRows([makeRow('b')]);

    await setActiveUID('user-a');
    expect((await getAllMemoryCandidateRows()).map((row) => row.id)).toEqual(['a']);
  });
});
