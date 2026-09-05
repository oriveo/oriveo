import 'fake-indexeddb/auto';

import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import type { Conversation, Provider } from '@oriveo/shared';
import { putConversation, putProvider, resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';
import {
  exportBackupToAutomaticStorage,
  type AutomaticBackupChunkWriter,
  type AutomaticBackupStorage,
} from '../backup-export';

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1',
    title: 'Chat 1',
    hasCustomTitle: false,
    providerID: 'provider-1',
    modelID: 'model-1',
    previewText: 'hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'provider-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••••test',
    ...overrides,
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('backup-export streamed automatic path', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('uses streamed writer for automatic backups instead of blob generateAsync path', async () => {
    await putConversation(makeConversation());
    await putProvider(makeProvider());

    const chunks: Uint8Array[] = [];
    const writer: AutomaticBackupChunkWriter = {
      write: vi.fn(async (chunk: Uint8Array) => {
        chunks.push(chunk);
      }),
      close: vi.fn(async () => ({
        storage: 'idb',
        fileName: 'merge-auto.oriveo',
        fileSizeBytes: chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0),
      })),
      abort: vi.fn(async () => {}),
    };
    const storage: AutomaticBackupStorage = {
      createWriter: vi.fn(async () => writer),
    };

    const generateAsyncSpy = vi.spyOn(JSZip.prototype, 'generateAsync').mockImplementation(async () => {
      throw new Error('generateAsync should not be called for automatic streamed backup');
    });

    const result = await exportBackupToAutomaticStorage(
      { includeApiKeys: false },
      {
        storage,
        fileName: 'merge-auto.oriveo',
      },
    );

    expect(generateAsyncSpy).not.toHaveBeenCalled();
    expect(storage.createWriter).toHaveBeenCalledWith('merge-auto.oriveo');
    expect(writer.write).toHaveBeenCalled();
    expect(chunks.length).toBeGreaterThan(0);
    expect(result.storage).toBe('idb');
    expect(result.fileName).toBe('merge-auto.oriveo');
    expect(result.fileSizeBytes).toBeGreaterThan(0);
  });

  it('exports Relay through the real streamed path without credentials or URL secrets', async () => {
    await putProvider(makeProvider({
      kind: 'relay',
      relayKind: 'custom',
      baseURLText: 'https://user:pass@relay.example.com/v1?token=secret#setup',
      relayResolvedBaseURLText: 'https://relay.example.com/codex?token=secret#runtime',
      relayRequested: {
        transport: 'openai_responses',
        authMode: 'bearer',
        stream: true,
        reasoningEffort: 'automatic',
        headers: [{ key: 'X-Second-Key', value: 'secret-2' }],
        queryParams: [{ key: 'api-key', value: 'secret-3' }],
        resolvedAPIBaseURL: 'https://user:pass@relay.example.com/codex?key=secret#runtime',
      },
    }));

    const chunks: Uint8Array[] = [];
    const writer: AutomaticBackupChunkWriter = {
      write: vi.fn(async (chunk: Uint8Array) => { chunks.push(chunk); }),
      close: vi.fn(async () => ({
        storage: 'idb',
        fileName: 'relay.oriveo',
        fileSizeBytes: chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0),
      })),
      abort: vi.fn(async () => {}),
    };

    await exportBackupToAutomaticStorage(
      { includeApiKeys: true, password: 'relay-backup-password' },
      {
        storage: { createWriter: vi.fn(async () => writer) },
        fileName: 'relay.oriveo',
      },
    );

    const zip = await JSZip.loadAsync(new Blob(chunks));
    const backup = JSON.parse(await zip.file('data.json')!.async('string')) as {
      containsKeys: boolean;
      encryptedKeys: string | null;
      data: { providers: Provider[] };
    };
    const exported = backup.data.providers[0];
    expect(exported.apiKey).toBe('');
    expect(exported.apiKeyPreview).toBe('');
    expect(exported.baseURLText).toBe('https://relay.example.com/v1');
    expect(exported.relayResolvedBaseURLText).toBe('https://relay.example.com/codex');
    expect(exported.relayRequested?.resolvedAPIBaseURL).toBe('https://relay.example.com/codex');
    expect(exported.relayRequested).not.toHaveProperty('headers');
    expect(exported.relayRequested).not.toHaveProperty('queryParams');
    expect(JSON.stringify(exported)).not.toContain('secret');
    expect(backup.containsKeys).toBe(false);
    expect(backup.encryptedKeys).toBeNull();
  });
});
