import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import JSZip from 'jszip';
import type { Conversation } from '@oriveo/shared';
import { getAllConversations, putConversationsBatch, resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';

// Backup export always writes the instructions key, writing "" when unset: a missing key means
// "leave the local value alone" on merge import, so omitting it on export would make it impossible
// to clear the other side's old instructions when this side has none.

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

describe('backup export instructions key', () => {
  beforeEach(resetDB);

  it('a conversation without instructions exports "instructions":""', async () => {
    await putConversationsBatch([conversation()]);
    const blob = await exportBackup({ includeApiKeys: false });
    const json = await readDataJson(blob);
    const file = JSON.parse(json) as { data: { conversations: Record<string, unknown>[] } };
    expect(file.data.conversations[0]).toHaveProperty('instructions', '');
    expect(json).toContain('"instructions":""');
  });

  it('an export then merge-import round trip clears the other side\'s local instructions', async () => {
    await putConversationsBatch([conversation({ updatedAt: '2026-10-03T00:00:00.000Z' })]);
    const blob = await exportBackup({ includeApiKeys: false });

    // The other side: the same conversation with older local instructions and an earlier updatedAt.
    await resetDB();
    await putConversationsBatch([conversation({ instructions: 'old rules', updatedAt: '2026-10-02T00:00:00.000Z' })]);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'chat.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'merge');

    const [merged] = await getAllConversations();
    expect(merged?.instructions).toBe('');
  });
});
