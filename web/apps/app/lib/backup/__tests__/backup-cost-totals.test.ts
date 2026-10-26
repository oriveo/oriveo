import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import JSZip from 'jszip';
import type { Conversation } from '@oriveo/shared';
import { getAllConversations, putConversationsBatch, resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';

// Conversation totals travel in the backup: a conversation with no non-USD part exports an explicit "nonUsdCostTotals":{}; on merge import
// the newer backup's totals (USD and non-USD) win, {} clears the local non-USD totals, and a newer local copy keeps its own.

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

const CONV_ID = '0b6f2c64-7a51-4c1e-9f0d-2b8e5d1a00c1';

function conversation(overrides: Partial<Conversation> = {}): Conversation {
  const conv = {
    id: CONV_ID,
    title: 'Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-10-02T00:00:00.000Z',
    createdAt: '2026-10-01T00:00:00.000Z',
    ...overrides,
  } as Conversation;
  // Simulate an old conversation / never set: the key is absent from storage altogether.
  if (!('instructions' in overrides)) delete (conv as { instructions?: string }).instructions;
  return conv;
}

async function resetDB(): Promise<void> {
  resetDBConnection();
  resetImageDBConnection();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
  await setActiveUID('guest');
}

async function readDataJson(blob: Blob): Promise<string> {
  const zip = await JSZip.loadAsync(await blob.arrayBuffer());
  return zip.file('data.json')!.async('string');
}

describe('backup conversation cost totals', () => {
  beforeEach(resetDB);

  it('a conversation without non-USD totals exports "nonUsdCostTotals":{}', async () => {
    await putConversationsBatch([conversation({ estimatedCost: 1.2 })]);
    const json = await readDataJson(await exportBackup({ includeApiKeys: false }));
    const file = JSON.parse(json) as { data: { conversations: Record<string, unknown>[] } };
    expect(file.data.conversations[0]).toHaveProperty('nonUsdCostTotals', {});
    expect(file.data.conversations[0]).toHaveProperty('estimatedCost', 1.2);
  });

  it('newer backup with non-USD {}: merge import takes the backup USD total and clears the local non-USD totals', async () => {
    await putConversationsBatch([conversation({ estimatedCost: 1.2, updatedAt: '2026-10-03T00:00:00.000Z' })]);
    const blob = await exportBackup({ includeApiKeys: false });

    await resetDB();
    await putConversationsBatch([conversation({ estimatedCost: 9, nonUsdCostTotals: { CNY: 9 } })]);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'chat.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'merge');

    const [merged] = await getAllConversations();
    expect(merged?.estimatedCost).toBe(1.2);
    expect(merged && 'nonUsdCostTotals' in merged).toBe(false);
  });

  it('newer backup carrying non-USD totals: merge import takes the backup non-USD totals', async () => {
    await putConversationsBatch([conversation({
      estimatedCost: 0.5, nonUsdCostTotals: { CNY: 3.5 }, updatedAt: '2026-10-03T00:00:00.000Z',
    })]);
    const blob = await exportBackup({ includeApiKeys: false });

    await resetDB();
    await putConversationsBatch([conversation({ estimatedCost: 9, nonUsdCostTotals: { CNY: 9, EUR: 1 } })]);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'chat.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'merge');

    const [merged] = await getAllConversations();
    expect(merged?.estimatedCost).toBe(0.5);
    expect(merged?.nonUsdCostTotals).toEqual({ CNY: 3.5 });
  });

  it('newer local copy: merge import keeps the local totals', async () => {
    await putConversationsBatch([conversation({ estimatedCost: 1.2, updatedAt: '2026-10-01T12:00:00.000Z' })]);
    const blob = await exportBackup({ includeApiKeys: false });

    await resetDB();
    await putConversationsBatch([conversation({ estimatedCost: 9, nonUsdCostTotals: { CNY: 9 } })]);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'chat.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'merge');

    const [merged] = await getAllConversations();
    expect(merged?.estimatedCost).toBe(9);
    expect(merged?.nonUsdCostTotals).toEqual({ CNY: 9 });
  });

  it('importing a new conversation: a backup {} leaves no key locally', async () => {
    await putConversationsBatch([conversation({ estimatedCost: 1.2 })]);
    const blob = await exportBackup({ includeApiKeys: false });

    await resetDB();
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'chat.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'merge');

    const [imported] = await getAllConversations();
    expect(imported?.estimatedCost).toBe(1.2);
    expect(imported && 'nonUsdCostTotals' in imported).toBe(false);
  });
});
