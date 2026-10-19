import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import type { AppPreference } from '@oriveo/shared';
import { ContextHash } from '@oriveo/core/context/hash';
import { MemoryItems } from '@oriveo/core/context/memory-items';
import { resetDBConnection } from '../../../infra/storage/idb';
import {
  copyGuestMemoryItemRows,
  getAllMemoryItemRows,
  putMemoryItemRows,
} from '../../../infra/storage/memory-item-store';
import { setActiveUID } from '../../../infra/storage/partition';
import { createMemoryItemRepository, type MemoryPreferenceStore } from '../memory-item-repository';
import { createAppStore } from '../../store/app-store';

const UID = 'user-1';
const NOW = '2026-10-16T08:00:00.000Z';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function fakeStore(initial: Partial<AppPreference>) {
  let preferences = { theme: 'dark', language: 'system', sendShortcut: 'cmdEnter', ...initial } as AppPreference;
  const store: MemoryPreferenceStore = {
    getState: () => ({
      preferences,
      setPreferences: (patch) => {
        preferences = { ...preferences, ...patch };
      },
    }),
  };
  return {
    store,
    prefs: () => preferences,
    edit: (patch: Partial<AppPreference>) => {
      preferences = { ...preferences, ...patch };
    },
  };
}

function setup(initial: Partial<AppPreference>, deviceId = 'device-a', uid = UID) {
  const prefs = fakeStore(initial);
  const pushed: Array<Record<string, unknown>> = [];
  let counter = 0;
  const repository = createMemoryItemRepository({
    store: prefs.store,
    uid,
    deviceId,
    now: () => new Date(NOW),
    newId: () => `00000000-0000-4000-8000-${String(++counter).padStart(12, '0')}`,
    sync: () => ({ didUpdatePreferences: (patch) => pushed.push(patch) }),
  });
  return { ...prefs, pushed, repository };
}

async function resetDevice() {
  resetDBConnection();
  await clearAllDatabases();
  localStorage.clear();
  await setActiveUID(UID);
}

describe('memory item repository', () => {
  beforeEach(async () => {
    await resetDevice();
  });

  it('migration_diff_zero', async () => {
    const memoryText = '  I prefer short answers.\nUse metric units.  ';
    const { repository, prefs, pushed } = setup({
      memoryText,
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Always answer in English.',
      memoryUpdatedAt: '2026-01-01T00:00:00.000Z',
    });

    const plan = await repository.reconcileLegacy();

    expect(plan.create.map((m) => m.id)).toEqual([
      MemoryItems.memoryTextItemId(UID),
      MemoryItems.antiForgetItemId(UID),
    ]);
    const rows = await getAllMemoryItemRows(UID);
    const items = rows.map((row) => row.item);
    expect(rows.every((row) => row.syncState === 'pending')).toBe(true);
    // After migration the compiled result is byte-for-byte identical to the original memoryText: zero diff.
    expect(MemoryItems.compileLegacy({ uid: UID, items }).memoryText).toBe(memoryText);
    expect(prefs().memoryText).toBe(memoryText);
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex(memoryText));
    // Body unchanged and only the digest is filled in: written locally only, no timestamp refresh and no push.
    expect(prefs().memoryUpdatedAt).toBe('2026-01-01T00:00:00.000Z');
    expect(pushed).toEqual([]);
    expect((await repository.list()).map((m) => m.content).sort()).toEqual(
      ['Always answer in English.', memoryText].sort(),
    );
  });

  it('migration_idempotent_two_devices', async () => {
    const legacy = { memoryText: 'Shared memory', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' };
    const deviceA = setup(legacy, 'device-a');
    await deviceA.repository.reconcileLegacy();
    const rowsA = await getAllMemoryItemRows(UID);

    // A second device of the same account takes the same old prefs and migrates independently.
    await resetDevice();
    const deviceB = setup(legacy, 'device-b');
    await deviceB.repository.reconcileLegacy();
    const rowsB = await getAllMemoryItemRows(UID);

    expect(rowsB.map((r) => r.id)).toEqual(rowsA.map((r) => r.id));
    expect(rowsB.map((r) => r.item.mutationId)).toEqual(rowsA.map((r) => r.item.mutationId));
    expect(rowsB.map((r) => r.item.content)).toEqual(['Shared memory']);
    expect(deviceB.prefs().memoryTextDigest).toBe(deviceA.prefs().memoryTextDigest);

    // Run again: no new items and no new writes.
    const again = await deviceB.repository.reconcileLegacy();
    expect(again).toEqual({ create: [], update: [], writePrefs: null });
    expect(await getAllMemoryItemRows(UID)).toEqual(rowsB);
    expect(deviceB.pushed).toEqual([]);
  });

  it('dual_write_compile', async () => {
    const { repository, prefs, pushed } = setup({ memoryText: 'First', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' });
    await repository.reconcileLegacy();
    // textChanged = false (the compiled result equals the local memoryText): only the digest is filled in locally.
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex('First'));
    expect(prefs().memoryUpdatedAt).toBe('2026-01-01T00:00:00.000Z');
    expect(pushed).toEqual([]);

    // textChanged = true: refresh the timestamp and push.
    const created = await repository.create({ kind: 'preference', content: 'Second' });
    expect(created.createdAt).toBe(NOW);
    const expected = 'First\n\nSecond';
    expect(prefs().memoryText).toBe(expected);
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex(expected));
    expect(prefs().memoryUpdatedAt).toBe(NOW);
    expect(pushed).toHaveLength(1);
    const last = pushed[pushed.length - 1];
    expect(last).toEqual({ memoryText: expected, memoryTextDigest: ContextHash.sha256Hex(expected), memoryUpdatedAt: NOW });
    expect(Object.keys(last).some((key) => key.startsWith('memoryAntiForget'))).toBe(false);

    // No write when the compiled result is unchanged (restricted items do not enter memoryText).
    const before = pushed.length;
    await repository.create({ kind: 'fact', content: 'Secret', sensitivity: 'restricted' });
    expect(pushed).toHaveLength(before);
    expect(prefs().memoryText).toBe(expected);
  });

  it('digest_only_write_stays_local', async () => {
    // New device with empty prefs: only an empty-string digest is filled in locally, no push and no memoryUpdatedAt write.
    const { repository, prefs, pushed, edit } = setup({});
    const plan = await repository.reconcileLegacy();
    expect(plan.writePrefs).toEqual({ memoryText: '', memoryTextDigest: ContextHash.sha256Hex(''), textChanged: false });
    expect(prefs().memoryText).toBe('');
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex(''));
    expect(prefs().memoryUpdatedAt).toBeUndefined();
    expect(pushed).toEqual([]);

    // After an item write the compiled result is unchanged and only the digest is missing: likewise filled in locally only.
    const kept = await repository.create({ kind: 'fact', content: 'Kept' });
    expect(pushed).toHaveLength(1);
    edit({ memoryTextDigest: undefined, memoryUpdatedAt: '2026-03-01T00:00:00.000Z' });
    await repository.create({ kind: 'fact', content: 'Secret', sensitivity: 'restricted' });
    expect(prefs().memoryText).toBe(kept.content);
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex(kept.content));
    expect(prefs().memoryUpdatedAt).toBe('2026-03-01T00:00:00.000Z');
    expect(pushed).toHaveLength(1);
  });

  it('text_change_bumps_and_pushes', async () => {
    const { repository, prefs, pushed, edit } = setup({ memoryText: 'Before', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' });
    await repository.reconcileLegacy();
    const [migrated] = await getAllMemoryItemRows(UID);
    expect(pushed).toEqual([]);

    // Local item change: compiled result != local memoryText -> refresh the timestamp and push.
    await repository.update(migrated.id, { content: 'After' });
    expect(prefs().memoryUpdatedAt).toBe(NOW);
    expect(pushed).toEqual([{ memoryText: 'After', memoryTextDigest: ContextHash.sha256Hex('After'), memoryUpdatedAt: NOW }]);

    // After an older client's edit flows back, the compiled result gains other items -> likewise refresh the timestamp and push.
    await repository.create({ kind: 'preference', content: 'Concise answers.' });
    edit({ memoryText: 'Old client text', memoryUpdatedAt: '2026-02-01T00:00:00.000Z' });
    const plan = await repository.reconcileLegacy();
    const expected = 'Old client text\n\nConcise answers.';
    expect(plan.writePrefs).toEqual({ memoryText: expected, memoryTextDigest: ContextHash.sha256Hex(expected), textChanged: true });
    expect(prefs().memoryText).toBe(expected);
    expect(prefs().memoryUpdatedAt).toBe(NOW);
    expect(pushed[pushed.length - 1]).toEqual({ memoryText: expected, memoryTextDigest: ContextHash.sha256Hex(expected), memoryUpdatedAt: NOW });
  });

  it('old_client_edit_flows_back', async () => {
    const { repository, prefs, edit } = setup({ memoryText: 'Original', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' });
    await repository.reconcileLegacy();
    const [migrated] = await getAllMemoryItemRows(UID);

    // The older client only changed memoryText and left the digest at the old value; the remote text lands unchanged (not trimmed).
    const oldClientText = 'Edited by old client \n';
    edit({ memoryText: oldClientText, memoryUpdatedAt: '2026-02-01T00:00:00.000Z' });
    const plan = await repository.reconcileLegacy();

    expect(plan.create).toEqual([]);
    expect(plan.update).toHaveLength(1);
    const [row] = await getAllMemoryItemRows(UID);
    expect(row.id).toBe(migrated.id);
    expect(row.syncState).toBe('pending');
    expect(row.item.content).toBe(oldClientText);
    expect(row.item.baseRevision).toBe(migrated.item.revision);
    expect(row.item.mutationId).not.toBe(migrated.item.mutationId);
    expect(prefs().memoryText).toBe(oldClientText);
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex(oldClientText));
  });

  it('delete_writes_tombstone', async () => {
    const { repository, prefs } = setup({});
    await repository.reconcileLegacy();
    const keep = await repository.create({ kind: 'fact', content: 'Keep' });
    const drop = await repository.create({ kind: 'fact', content: 'Drop' });

    const tombstone = await repository.remove(drop.id);

    const row = (await getAllMemoryItemRows(UID)).find((r) => r.id === drop.id);
    expect(row?.syncState).toBe('pending');
    expect(row?.item).toEqual(tombstone);
    expect(row?.item.status).toBe('deleted');
    expect(row?.item.content).toBe('');
    expect(row?.item.deletedAt).toBe(NOW);
    expect(row?.item.createdAt).toBe(drop.createdAt);
    expect(row?.item.baseRevision).toBe(drop.revision);
    expect((await repository.list()).map((m) => m.id)).toEqual([keep.id]);
    expect(prefs().memoryText).toBe('Keep');
    expect(await repository.remove(drop.id)).toBeNull();
  });

  it('local_write_refreshes_store_slice', async () => {
    // After a write the repository refreshes store.memoryItems as a whole (no tombstones, list order), and injection reads it.
    const store = createAppStore();
    let counter = 0;
    const repository = createMemoryItemRepository({
      store,
      uid: UID,
      deviceId: 'device-a',
      now: () => new Date(NOW),
      newId: () => `00000000-0000-4000-8000-${String(++counter).padStart(12, '0')}`,
      sync: () => null,
    });
    const keep = await repository.create({ kind: 'fact', content: 'Keep' });
    const drop = await repository.create({ kind: 'fact', content: 'Drop' });
    expect(store.getState().memoryItems).toEqual([keep, drop]);
    const pinned = await repository.setPinned(drop.id, true);
    expect(store.getState().memoryItems).toEqual([pinned, keep]);
    await repository.remove(drop.id);
    expect(store.getState().memoryItems).toEqual([keep]);
  });

  it('edit_marks_pending', async () => {
    const { repository, prefs } = setup({ memoryText: 'Before', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' });
    await repository.reconcileLegacy();
    const [migrated] = await getAllMemoryItemRows(UID);
    // Simulate the cloud having confirmed revision 3.
    const synced = { ...migrated.item, revision: 3, baseRevision: 2 };
    await putMemoryItemRows([{ id: synced.id, item: synced, syncState: 'synced' }], UID);

    const updated = await repository.update(synced.id, { content: 'After' });

    const [row] = await getAllMemoryItemRows(UID);
    expect(row.syncState).toBe('pending');
    expect(row.item).toEqual(updated);
    expect(row.item.content).toBe('After');
    expect(row.item.revision).toBe(3);
    expect(row.item.baseRevision).toBe(3);
    expect(row.item.deviceId).toBe('device-a');
    expect(row.item.mutationId).toMatch(/^[0-9a-f-]{36}$/);
    expect(row.item.mutationId).not.toBe(synced.mutationId);
    expect(prefs().memoryText).toBe('After');

    const pinned = await repository.setPinned(synced.id, true);
    expect(pinned?.pinned).toBe(true);
    expect(pinned?.baseRevision).toBe(3);
    expect(pinned?.mutationId).not.toBe(row.item.mutationId);
  });

  it('guest_partition_migrates', async () => {
    await setActiveUID('guest');
    const { repository, prefs } = setup({ memoryText: 'Guest memory', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' }, 'device-a', 'guest');

    const plan = await repository.reconcileLegacy();

    expect(plan.create.map((m) => m.id)).toEqual([MemoryItems.memoryTextItemId('guest')]);
    const rows = await getAllMemoryItemRows('guest');
    expect(rows.map((r) => r.item.content)).toEqual(['Guest memory']);
    expect(rows[0].syncState).toBe('pending');
    expect(prefs().memoryText).toBe('Guest memory');
    expect(prefs().memoryTextDigest).toBe(ContextHash.sha256Hex('Guest memory'));
  });

  it('guest_items_follow_login', async () => {
    await setActiveUID('guest');
    const guest = setup({ memoryText: 'Guest memory', memoryUpdatedAt: '2026-01-01T00:00:00.000Z' }, 'device-a', 'guest');
    await guest.repository.reconcileLegacy();
    const kept = await guest.repository.create({ kind: 'fact', content: 'Kept' });
    const dropped = await guest.repository.create({ kind: 'fact', content: 'Dropped' });
    await guest.repository.remove(dropped.id);
    const guestRows = await getAllMemoryItemRows('guest');

    resetDBConnection();
    await setActiveUID(UID);
    const copied = await copyGuestMemoryItemRows(UID);

    const rows = await getAllMemoryItemRows(UID);
    expect(copied).toBe(2);
    expect(rows.map((r) => r.id).sort()).toEqual([MemoryItems.memoryTextItemId('guest'), kept.id].sort());
    expect(rows.every((r) => r.syncState === 'pending')).toBe(true);
    for (const row of rows) {
      expect(row.item).toEqual(guestRows.find((g) => g.id === row.id)?.item);
    }
    expect(rows.some((r) => r.id === dropped.id)).toBe(false);
    // Moving again neither duplicates nor overwrites.
    expect(await copyGuestMemoryItemRows(UID)).toBe(0);
  });

  it('episodic_create_defaults_occurred_at', async () => {
    const { repository } = setup({});
    const episodic = await repository.create({ kind: 'event', content: 'Shipped v2.3 to beta testers', layer: 'episodic' });
    const given = await repository.create({
      kind: 'event', content: 'Kickoff meeting with vendor', layer: 'episodic', occurredAt: '2026-09-01T00:00:00Z',
    });
    const semantic = await repository.create({ kind: 'fact', content: 'Prefers metric units' });
    expect(episodic.occurredAt).toBe(NOW);
    expect(given.occurredAt).toBe('2026-09-01T00:00:00Z');
    expect(semantic.occurredAt).toBeNull();
  });

  async function conflictedPair() {
    const ctx = setup({});
    const older = await ctx.repository.create({
      kind: 'decision', content: 'We chose Postgres for the billing database', layer: 'episodic',
    });
    const newer = await ctx.repository.create({
      kind: 'decision', content: 'We chose MySQL for the billing database', layer: 'episodic',
    });
    return { ...ctx, older, newer };
  }

  it('episodic_conflict_marks_both', async () => {
    const { repository, older, newer } = await conflictedPair();
    expect(newer.status).toBe('conflicted');
    expect(newer.conflictGroupId).toBe(older.id);
    const rows = await getAllMemoryItemRows(UID);
    const stored = rows.find((r) => r.id === older.id)!;
    expect(stored.item.status).toBe('conflicted');
    expect(stored.item.conflictGroupId).toBe(older.id);
    expect(stored.syncState).toBe('pending');
    expect((await repository.list()).map((m) => m.status)).toEqual(['conflicted', 'conflicted']);
  });

  it('resolve_l3_conflict_use_new', async () => {
    const { repository, older, newer } = await conflictedPair();
    const result = await repository.resolveL3Conflict(newer.id, older.id, 'useNew');
    expect(result?.map((m) => [m.id, m.status, m.conflictGroupId, m.supersedes])).toEqual([
      [newer.id, 'active', null, [older.id]],
      [older.id, 'superseded', null, []],
    ]);
    const rows = await getAllMemoryItemRows(UID);
    expect(rows.find((r) => r.id === older.id)?.item.status).toBe('superseded');
    expect(rows.find((r) => r.id === newer.id)?.item.baseRevision).toBe(newer.revision);
  });

  it('resolve_l3_conflict_keep_both', async () => {
    const { repository, older, newer } = await conflictedPair();
    const result = await repository.resolveL3Conflict(newer.id, older.id, 'keepBoth');
    expect(result?.map((m) => [m.status, m.conflictGroupId, m.supersedes])).toEqual([
      ['active', null, []],
      ['active', null, []],
    ]);
  });

  it('resolve_l3_conflict_use_old', async () => {
    const { repository, older, newer } = await conflictedPair();
    const result = await repository.resolveL3Conflict(newer.id, older.id, 'useOld');
    expect(result?.map((m) => [m.id, m.status])).toEqual([
      [newer.id, 'superseded'],
      [older.id, 'active'],
    ]);
    expect(await repository.resolveL3Conflict(newer.id, 'missing', 'useOld')).toBeNull();
  });
});
