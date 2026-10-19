import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import type { AppPreference, ChatMessage, Conversation } from '@oriveo/shared';
import { MemoryItems, type MemoryItem, type MemoryItemInput } from '@oriveo/core/context/memory-items';
import { ContextHash } from '@oriveo/core/context/hash';
import { ContextContractFixture } from '@oriveo/core/context/__tests__/fixture';
import type { BackupFile } from '..';
import { getAllConversations, putConversationsBatch, resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { getAllMemoryItemRows, putMemoryItemRows, type MemoryItemRow } from '../../infra/storage/memory-item-store';
import { setActiveUID } from '../../infra/storage/partition';
import { getPreference, setPreference } from '../../infra/storage/preferences';

// Memory item v2 backup: export writes memorySchemaVersion + memoryItems (including tombstones);
// import merge keeps the higher revision, replace swaps the whole table, legacy backups migrate from preferences; imported rows are always pending, and memoryText is dual-written.

const didUpdatePreferences = vi.fn();
vi.mock('../../core/sync-port', async () => {
  const actual = await vi.importActual<typeof import('../../core/sync-port')>('../../core/sync-port');
  return { ...actual, getSyncAdapter: () => ({ didUpdatePreferences }) };
});

if (typeof Blob.prototype.arrayBuffer !== 'function') {
  Blob.prototype.arrayBuffer = function () {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as ArrayBuffer);
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

const { exportBackup, parseBackupFile, generateImportPreview, executeImport } = await import('..');
const { canonicalJSON } = await import('../backup-format');
const { getOrCreateStableWebDeviceId } = await import('../../core/bootstrap');
const { sha256hex } = await import('../backup-crypto');

const UID = 'guest';
const DEFAULT_PREFS: AppPreference = { theme: 'dark', language: 'system', sendShortcut: 'enter' };

const ID_A = '0b6f2c64-7a51-4c1e-9f0d-2b8e5d1a0001';
const ID_B = '0b6f2c64-7a51-4c1e-9f0d-2b8e5d1a0002';
const ID_C = '0b6f2c64-7a51-4c1e-9f0d-2b8e5d1a0003';
const ID_D = '0b6f2c64-7a51-4c1e-9f0d-2b8e5d1a0004';

function item(input: Partial<MemoryItemInput> & Pick<MemoryItemInput, 'id' | 'content'>): MemoryItem {
  return MemoryItems.canonical({
    kind: 'fact',
    mutationId: `${input.id.slice(0, -4)}m${input.revision ?? 1}00`,
    deviceId: 'device-backup',
    createdAt: '2026-10-01T08:00:00.000Z',
    ...input,
  });
}

function deleted(input: Partial<MemoryItemInput> & Pick<MemoryItemInput, 'id'>): MemoryItem {
  return item({ status: 'deleted', deletedAt: '2026-10-02T08:00:00.000Z', ...input, content: '' });
}

function synced(...items: MemoryItem[]): MemoryItemRow[] {
  return items.map((m) => ({ id: m.id, item: m, syncState: 'synced' }));
}

async function rowsById(): Promise<Map<string, MemoryItemRow>> {
  return new Map((await getAllMemoryItemRows(UID)).map((row) => [row.id, row]));
}

function localPrefs(): AppPreference {
  return getPreference<AppPreference>('preferences', DEFAULT_PREFS);
}

async function resetDB(): Promise<void> {
  resetDBConnection();
  resetImageDBConnection();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
  await setActiveUID(UID);
}

async function readDataJson(blob: Blob): Promise<BackupFile> {
  const zip = await JSZip.loadAsync(await blob.arrayBuffer());
  return JSON.parse(await zip.file('data.json')!.async('string'));
}

/** Hand-writes a backup in another client's shape (with a correct checksum) and runs it through the production preview + import. */
async function importHandWritten(
  extra: Record<string, unknown>,
  mode: 'importNew' | 'merge' | 'replaceAll',
  now?: () => Date,
): Promise<void> {
  const data = { providers: [], conversations: [], ...extra } as unknown as BackupFile['data'];
  const checksum = await sha256hex(new TextEncoder().encode(canonicalJSON(data)));
  const backupFile: BackupFile = {
    version: 1,
    createdAt: '2026-10-15T00:00:00Z',
    appVersion: '1.0.0',
    platform: 'iOS',
    checksum: `sha256:${checksum}`,
    containsKeys: false,
    data,
    encryptedKeys: null,
  };
  const preview = await generateImportPreview(backupFile, new Map());
  expect(preview.checksumValid).toBe(true);
  await executeImport(preview, mode, undefined, undefined, now ? { now } : undefined);
}

function expectCompiled(memoryText: string): void {
  const prefs = localPrefs();
  expect(prefs.memoryText).toBe(memoryText);
  expect(prefs.memoryTextDigest).toBe(ContextHash.sha256Hex(memoryText));
  expect(didUpdatePreferences).toHaveBeenCalledWith(expect.objectContaining({
    memoryText,
    memoryTextDigest: ContextHash.sha256Hex(memoryText),
  }));
}

describe('backup memory items', () => {
  beforeEach(async () => {
    await resetDB();
    didUpdatePreferences.mockReset();
    setPreference('preferences', DEFAULT_PREFS);
  });

  it('round_trip_replace', async () => {
    const active = item({ id: ID_A, content: 'Lives in Berlin.', revision: 2, baseRevision: 1 });
    const tomb = deleted({ id: ID_B, revision: 3, baseRevision: 3 });
    const pinned = item({ id: ID_C, kind: 'instruction', content: 'Answer briefly.', pinned: true });
    await putMemoryItemRows(synced(active, tomb, pinned), UID);

    const blob = await exportBackup({ includeApiKeys: false });
    const exported = await readDataJson(blob);
    expect(exported.data.memorySchemaVersion).toBe(2);
    expect(exported.data.memoryItems).toEqual(MemoryItems.backupSection([active, tomb, pinned]).memoryItems);

    await resetDB();
    setPreference('preferences', DEFAULT_PREFS);
    const stray = item({ id: ID_D, content: 'Only on this device.' });
    await putMemoryItemRows(synced(stray), UID);

    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'memory.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'replaceAll');

    const rows = await rowsById();
    // A stray item that exists locally but not in the backup becomes a tombstone (details in replace_tombstones_local_only_items).
    expect([...rows.keys()].sort()).toEqual([ID_A, ID_B, ID_C, ID_D]);
    expect(rows.get(ID_D)?.item).toMatchObject({ status: 'deleted', content: '', revision: 1 });
    expect(rows.get(ID_A)?.item).toEqual(active);
    expect(rows.get(ID_B)?.item).toEqual(tomb);
    expect(rows.get(ID_C)?.item).toEqual(pinned);
    expect([...rows.values()].every((row) => row.syncState === 'pending')).toBe(true);
    expectCompiled(MemoryItems.compileLegacy({ uid: UID, items: [active, tomb, pinned] }).memoryText);
  });

  it('replace_tombstones_local_only_items', async () => {
    const localA = item({ id: ID_A, content: 'Uses vim.', revision: 3, baseRevision: 3 });
    const localOnly = item({ id: ID_C, content: 'Has a cat.', revision: 2, baseRevision: 2 });
    const localTomb = deleted({ id: ID_D, revision: 4, baseRevision: 4 });
    await putMemoryItemRows(synced(localA, localOnly, localTomb), UID);

    const backupA = item({ id: ID_A, content: 'Uses helix.', revision: 2, baseRevision: 1 });
    const backupB = item({ id: ID_B, content: 'Lives in Berlin.' });
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [backupA, backupB] }, 'replaceAll');

    const rows = await rowsById();
    expect([...rows.keys()].sort()).toEqual([ID_A, ID_B, ID_C, ID_D]);
    expect(rows.get(ID_A)).toEqual({ id: ID_A, item: backupA, syncState: 'pending' });
    expect(rows.get(ID_B)).toEqual({ id: ID_B, item: backupB, syncState: 'pending' });
    // A live item that exists locally but not in the backup becomes a pending tombstone: new mutationId, this device's deviceId, deletedAt = the import time.
    const tomb = rows.get(ID_C)!;
    expect(tomb.syncState).toBe('pending');
    expect(tomb.item).toEqual(MemoryItems.tombstone({
      item: localOnly,
      mutationId: tomb.item.mutationId,
      deviceId: getOrCreateStableWebDeviceId(),
      deletedAt: tomb.item.deletedAt!,
    }));
    expect(tomb.item).toMatchObject({ status: 'deleted', content: '', revision: 2, baseRevision: 2 });
    expect(tomb.item.mutationId).not.toBe(localOnly.mutationId);
    expect(tomb.item.mutationId).toMatch(/^[0-9a-f-]{36}$/);
    expect(Date.parse(tomb.item.deletedAt!)).toBeGreaterThan(Date.parse('2026-10-15T00:00:00Z'));
    // Existing tombstones are kept as they are.
    expect(rows.get(ID_D)).toEqual({ id: ID_D, item: localTomb, syncState: 'synced' });
    expectCompiled(MemoryItems.compileLegacy({ uid: UID, items: [backupA, backupB] }).memoryText);
  });

  it('import_tombstone_uses_injected_clock', async () => {
    const localOnly = item({ id: ID_C, content: 'Has a cat.', revision: 2, baseRevision: 2 });
    await putMemoryItemRows(synced(localOnly), UID);
    const backupB = item({ id: ID_B, content: 'Lives in Berlin.' });
    const clock = '2031-02-03T04:05:06.000Z';
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [backupB] }, 'replaceAll', () => new Date(clock));

    // The deletedAt of a tombstone for a local-only item uses the clock injected into the import.
    expect((await rowsById()).get(ID_C)?.item).toMatchObject({ status: 'deleted', deletedAt: clock });
  });

  it('export_strips_memory_item_ids', async () => {
    // memoryItemIds stay on this device: export strips them, and import drops them even if a backup from elsewhere carries them.
    const user: ChatMessage = {
      id: 'c1a2b3c4-0000-4000-8000-000000000011', role: 'user', text: 'Where do I live?', state: 'delivered',
      providerKind: 'openAI', createdAt: '2026-10-15T00:00:01.000Z',
    } as ChatMessage;
    const assistant: ChatMessage = {
      id: 'c1a2b3c4-0000-4000-8000-000000000012', role: 'assistant', text: 'Berlin.', state: 'delivered',
      providerKind: 'openAI', createdAt: '2026-10-15T00:00:02.000Z', memoryItemIds: [ID_A],
    } as ChatMessage;
    const conversation = {
      id: 'c1a2b3c4-0000-4000-8000-000000000001', title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'm-1',
      providerKind: 'openAI', previewText: '', estimatedCost: 0, isDraft: false, messages: [user, assistant],
      draftText: '', createdAt: '2026-10-15T00:00:00.000Z', updatedAt: '2026-10-15T00:00:02.000Z',
    } as Conversation;
    await putConversationsBatch([conversation]);

    const exported = await readDataJson(await exportBackup({ includeApiKeys: false }));
    const exportedMessages = exported.data.conversations[0].messages;
    expect(exportedMessages.map((m) => m.text)).toEqual(['Where do I live?', 'Berlin.']);
    expect(exportedMessages.every((m) => !('memoryItemIds' in m))).toBe(true);

    await resetDB();
    setPreference('preferences', DEFAULT_PREFS);
    await importHandWritten({ conversations: [conversation] }, 'replaceAll');
    const [imported] = await getAllConversations();
    expect(imported.messages.map((m) => m.text)).toEqual(['Where do I live?', 'Berlin.']);
    expect(imported.messages.every((m) => !('memoryItemIds' in m))).toBe(true);
  });

  it('merge_keeps_newer_and_tombstones', async () => {
    const localTomb = deleted({ id: ID_A, revision: 3, baseRevision: 3 });
    const localOld = item({ id: ID_B, content: 'Uses vim.' });
    const localOnly = item({ id: ID_C, content: 'Has a cat.' });
    await putMemoryItemRows(synced(localTomb, localOld, localOnly), UID);

    const staleA = item({ id: ID_A, content: 'Stale copy of a deleted memory.', revision: 2, baseRevision: 1 });
    const newerB = item({ id: ID_B, content: 'Uses helix.', revision: 2, baseRevision: 1 });
    const backupTomb = deleted({ id: ID_D, revision: 2, baseRevision: 2 });
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [staleA, newerB, backupTomb] }, 'merge');

    const rows = await rowsById();
    expect(rows.get(ID_A)).toEqual({ id: ID_A, item: localTomb, syncState: 'synced' });
    expect(rows.get(ID_B)).toEqual({ id: ID_B, item: newerB, syncState: 'pending' });
    expect(rows.get(ID_C)).toEqual({ id: ID_C, item: localOnly, syncState: 'synced' });
    expect(rows.get(ID_D)).toEqual({ id: ID_D, item: backupTomb, syncState: 'pending' });
    expectCompiled(MemoryItems.compileLegacy({ uid: UID, items: [localTomb, newerB, localOnly, backupTomb] }).memoryText);
  });

  it('restricted_to_normal_via_import', async () => {
    // Locally marked restricted (excluded from injection and from compilation); the newer version with the same id in the backup is normal, and import turns it back to normal.
    const localRestricted = item({ id: ID_A, content: 'Takes insulin daily.', sensitivity: 'restricted' });
    await putMemoryItemRows(synced(localRestricted), UID);
    expect(MemoryItems.compileLegacy({ uid: UID, items: [localRestricted] }).memoryText).toBe('');

    const backupNormal = item({ id: ID_A, content: 'Takes insulin daily.', sensitivity: 'normal', revision: 2, baseRevision: 1 });
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [backupNormal] }, 'merge');

    const rows = await rowsById();
    expect(rows.get(ID_A)).toEqual({ id: ID_A, item: backupNormal, syncState: 'pending' });
    expect(rows.get(ID_A)?.item.sensitivity).toBe('normal');
    expectCompiled(MemoryItems.compileLegacy({ uid: UID, items: [backupNormal] }).memoryText);
    expect(localPrefs().memoryText).toContain('Takes insulin daily.');
  });

  it('legacy_backup_migrates', async () => {
    const memoryTextId = MemoryItems.memoryTextItemId(UID);
    const antiForgetId = MemoryItems.antiForgetItemId(UID);
    const localFact = item({ id: memoryTextId, content: 'Local fact.', revision: 2, baseRevision: 1 });
    await putMemoryItemRows(synced(localFact), UID);

    await importHandWritten({
      preferences: {
        theme: 'dark',
        language: 'system',
        memoryText: 'Backup fact.',
        memoryAntiForgetEnabled: true,
        memoryAntiForgetText: 'Always answer in English.',
        memoryUpdatedAt: '2026-09-30T12:34:56Z',
      },
    }, 'merge');

    const rows = await rowsById();
    // create-if-absent: an item already migrated locally is not overwritten by a legacy backup.
    expect(rows.get(memoryTextId)).toEqual({ id: memoryTextId, item: localFact, syncState: 'synced' });
    expect(rows.get(antiForgetId)).toMatchObject({
      syncState: 'pending',
      item: {
        kind: 'instruction',
        status: 'active',
        content: 'Always answer in English.',
        source: { type: 'migration', observedAt: '2026-09-30T12:34:56.000Z' },
        revision: 1,
        baseRevision: 0,
      },
    });
    // The dual-write compile overwrites the stale memoryText in the backup; Anti-Forget does not enter the compiled result.
    expectCompiled('Local fact.');
  });

  it('imported_items_pending', async () => {
    const fact = item({ id: ID_A, content: 'Prefers tea.', revision: 4, baseRevision: 3 });
    const episode = item({ id: ID_B, layer: 'episodic', kind: 'event', content: 'Visited Kyoto.' });
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [fact, episode] }, 'importNew');

    const rows = await rowsById();
    expect(rows.get(ID_A)).toEqual({ id: ID_A, item: fact, syncState: 'pending' });
    expect(rows.get(ID_B)).toEqual({ id: ID_B, item: episode, syncState: 'pending' });
    expectCompiled('Prefers tea.');
  });

  it('import_with_section_marks_migrated', async () => {
    // A backup with an item section is authoritative data: after import it is marked as migrated, so reconcile no longer migrates the backup memoryText into a duplicate item
    setPreference('memoryItems.migrated', false, UID); // marker left by earlier cases (localStorage is not cleared between cases)
    expect(getPreference<boolean>('memoryItems.migrated', false, UID)).toBe(false);
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [item({ id: ID_C, content: 'Has a cat.' })] }, 'merge');
    expect(getPreference<boolean>('memoryItems.migrated', false, UID)).toBe(true);
  });

  it('legacy_backup_leaves_migration_to_reconcile', async () => {
    setPreference('memoryItems.migrated', false, UID);
    await importHandWritten({ preferences: { theme: 'dark', language: 'system', memoryText: 'Old text.' } }, 'merge');
    expect(getPreference<boolean>('memoryItems.migrated', false, UID)).toBe(false);
  });

  it('import_new_only_adds_missing', async () => {
    const localTomb = deleted({ id: ID_A, revision: 3, baseRevision: 3 });
    const localOld = item({ id: ID_B, content: 'Uses vim.' });
    await putMemoryItemRows(synced(localTomb, localOld), UID);

    // Even a higher revision of the same id in the backup leaves the local item alone (a tombstone counts as present); only ids missing locally are added.
    const newerA = item({ id: ID_A, content: 'Revived from backup.', revision: 5, baseRevision: 4 });
    const newerB = item({ id: ID_B, content: 'Uses helix.', revision: 2, baseRevision: 1 });
    const missing = item({ id: ID_C, content: 'Has a cat.' });
    await importHandWritten({ memorySchemaVersion: 2, memoryItems: [newerA, newerB, missing] }, 'importNew');

    const rows = await rowsById();
    expect(rows.get(ID_A)).toEqual({ id: ID_A, item: localTomb, syncState: 'synced' });
    expect(rows.get(ID_B)).toEqual({ id: ID_B, item: localOld, syncState: 'synced' });
    expect(rows.get(ID_C)).toEqual({ id: ID_C, item: missing, syncState: 'pending' });
    expectCompiled(MemoryItems.compileLegacy({ uid: UID, items: [localTomb, localOld, missing] }).memoryText);
  });

  it('cross_end_backup_decodes', async () => {
    // The memory section exported by another client (the expectation of the contract fixture export_section), run through production import and export again, must be equal field by field.
    const contract = ContextContractFixture.load<{ backupCases: Array<{ id: string; expected: Record<string, unknown> }> }>(
      'memory-items.v2.json',
    );
    const section = contract.backupCases.find((c) => c.id === 'export_section')!.expected as {
      memorySchemaVersion: number;
      memoryItems: Array<Record<string, unknown>>;
    };
    expect(section.memoryItems.length).toBeGreaterThan(0);
    await importHandWritten(structuredClone(section), 'importNew');

    const exported = (await readDataJson(await exportBackup({ includeApiKeys: false }))).data;
    expect(exported.memorySchemaVersion).toBe(section.memorySchemaVersion);
    const items = exported.memoryItems as unknown as Array<Record<string, unknown>>;
    expect(items.map((m) => m.id)).toEqual(section.memoryItems.map((m) => m.id));
    section.memoryItems.forEach((expected, i) => {
      // data.json goes through canonicalJSON (sorted keys), so compare only the key sets, not the key order.
      expect(Object.keys(items[i]).sort()).toEqual(Object.keys(expected).sort());
      for (const key of Object.keys(expected)) {
        expect({ id: expected.id, key, value: items[i][key] }).toEqual({ id: expected.id, key, value: expected[key] });
      }
    });
  });
});
