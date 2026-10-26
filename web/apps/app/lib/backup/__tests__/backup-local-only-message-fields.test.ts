import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import JSZip from 'jszip';
import type { AppPreference, ChatMessage, Conversation } from '@oriveo/shared';
import type { BackupFile } from '..';
import { getAllConversations, putConversationsBatch, resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';
import { setPreference } from '../../infra/storage/preferences';

// Message fields that live only on this device (memoryItemIds, ids of local memory items) are
// stripped on backup export and ignored on import; on merge import, when the local copy has the
// field and the backup has no key, the local value is kept.

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

const { exportBackup, generateImportPreview, executeImport } = await import('..');
const { canonicalJSON } = await import('../backup-format');
const { sha256hex } = await import('../backup-crypto');

const UID = 'guest';
const DEFAULT_PREFS: AppPreference = { theme: 'dark', language: 'system', sendShortcut: 'enter' };
const CONV_ID = 'c1a2b3c4-0000-4000-8000-000000000101';
const MSG_ID = 'c1a2b3c4-0000-4000-8000-000000000111';
const LOCAL_ITEM_IDS = ['local-memory-item-1'];

function assistant(extra: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: MSG_ID, role: 'assistant', text: 'Hello there.', state: 'delivered',
    providerKind: 'openai', createdAt: '2026-10-15T00:00:02.000Z',
    ...extra,
  } as ChatMessage;
}

function conversation(messages: ChatMessage[]): Conversation {
  return {
    id: CONV_ID, title: 'T', hasCustomTitle: false, providerID: 'p-1', modelID: 'm-1',
    providerKind: 'openai', previewText: '', estimatedCost: 0, isDraft: false, messages,
    draftText: '', createdAt: '2026-10-15T00:00:00.000Z', updatedAt: '2026-10-15T00:00:02.000Z',
  } as Conversation;
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

/** Hand-write a backup in another client's shape (with a correct checksum) and run it through the production preview + import. */
async function importHandWritten(conversations: Conversation[], mode: 'importNew' | 'merge' | 'replaceAll'): Promise<void> {
  const data = { providers: [], conversations } as unknown as BackupFile['data'];
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
  await executeImport(preview, mode);
}

describe('backup local-only message fields', () => {
  beforeEach(async () => {
    await resetDB();
    setPreference('preferences', DEFAULT_PREFS);
  });

  it('export strips local-only keys', async () => {
    await putConversationsBatch([conversation([assistant({ memoryItemIds: LOCAL_ITEM_IDS })])]);

    const exported = await readDataJson(await exportBackup({ includeApiKeys: false }));
    const [message] = exported.data.conversations[0].messages;
    expect(message.text).toBe('Hello there.');
    expect(message).not.toHaveProperty('memoryItemIds');
  });

  it('import ignores local-only keys carried by a foreign backup', async () => {
    await importHandWritten([conversation([assistant({ memoryItemIds: LOCAL_ITEM_IDS })])], 'replaceAll');

    const [imported] = await getAllConversations();
    expect(imported.messages[0].text).toBe('Hello there.');
    expect(imported.messages[0]).not.toHaveProperty('memoryItemIds');
  });

  it('merge import keeps the local value when the backup has no key', async () => {
    await putConversationsBatch([conversation([assistant({ memoryItemIds: LOCAL_ITEM_IDS })])]);

    await importHandWritten([conversation([assistant()])], 'merge');

    const [merged] = await getAllConversations();
    expect(merged.messages[0].memoryItemIds).toEqual(LOCAL_ITEM_IDS);
  });
});
