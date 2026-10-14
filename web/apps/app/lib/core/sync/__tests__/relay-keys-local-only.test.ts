// The relay key list is stored on this device only (fixture portable-config.v1.json connectionFields):
// the local storage round trip and backup export / import are each exercised.

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

import { getAllProviders, putProvider, resetDBConnection } from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';
import { resetImageDBConnection } from '../../../infra/storage/image-store';
import { sanitizeProviders } from '../../../backup/backup-export';

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', { value: nodeCrypto.webcrypto, writable: true, configurable: true });
}
const { executeImport, generateImportPreview } = await import('../../../backup');

const contract = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'portable-config.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as { connectionFields: { all: string[]; portable: string[]; localOnly: string[] } };
    }
    dir = path.dirname(dir);
  }
  throw new Error('portable-config.v1.json not found');
})();

const SECONDARY_SECRET = 'sk-b';

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return {
    id, name: id, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '', ...extra,
  } as AIModel;
}

function multiKeyRelay(): Provider {
  return {
    id: 'relay-keys',
    kind: 'relay',
    status: { kind: 'connected' },
    apiKey: 'sk-a',
    apiKeyPreview: '••••',
    baseURLText: 'https://relay.example.com/v1',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    relayKeys: [
      { id: 'initial', name: 'OpenAI', apiKey: '', status: { state: 'ok', httpStatus: 200 } },
      { id: 'k-b', name: 'Claude', apiKey: SECONDARY_SECRET, status: { state: 'invalid', httpStatus: 401 } },
    ],
    models: [model('gpt-4o', { relayKeyID: 'initial' }), model('claude-opus-4', { relayKeyID: 'k-b' })],
    catalogModels: [
      model('gpt-4o', { relayListedByKeyIDs: ['initial'] }),
      model('claude-opus-4', { relayListedByKeyIDs: ['k-b'] }),
    ],
  };
}

describe('KEY-SYNC (Web)', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    for (const db of await indexedDB.databases()) {
      if (db.name) indexedDB.deleteDatabase(db.name);
    }
    await setActiveUID('guest');
  });

  it('fixture connectionFields registers only relayKeys and keeps it local-only', () => {
    expect(contract.connectionFields).toMatchObject({ all: ['relayKeys'], portable: [], localOnly: ['relayKeys'] });
  });

  it('KEY-SYNC-relay_keys_local_only', async () => {
    const provider = multiKeyRelay();

    // 1. Local storage round trip: the list and non-primary key values are unchanged.
    await putProvider(provider);
    const [stored] = await getAllProviders();
    expect(stored!.relayKeys).toEqual(provider.relayKeys);
    expect(stored!.models.map((m) => m.relayKeyID)).toEqual(['initial', 'k-b']);

    // 2. Production backup export: no relayKeys key, and no non-primary key value can be found.
    const [exported] = sanitizeProviders([stored!]);
    expect(exported).not.toHaveProperty('relayKeys');
    expect(JSON.stringify(exported)).not.toContain(SECONDARY_SECRET);

    // 3. Backup import does not write relayKeys (dropped even if the file carries it); a dangling relayKeyID falls back to the primary key on read.
    resetDBConnection();
    for (const db of await indexedDB.databases()) {
      if (db.name) indexedDB.deleteDatabase(db.name);
    }
    await setActiveUID('guest');
    const backup = {
      version: 1,
      exportedAt: new Date().toISOString(),
      containsKeys: false,
      data: { conversations: [], providers: [{ ...exported!, relayKeys: provider.relayKeys }], folders: [], skills: [] },
    };
    const preview = await generateImportPreview(backup as never, new Map());
    await executeImport(preview, 'importNew');
    const [imported] = await getAllProviders();
    expect(imported!.id).toBe(provider.id);
    expect(imported).not.toHaveProperty('relayKeys');
    expect(JSON.stringify(imported)).not.toContain(SECONDARY_SECRET);
  });

  it('local storage read-back: a malformed relayKeys is dropped as a whole or per entry, and the first key value is stored empty', async () => {
    await putProvider({ ...multiKeyRelay(), id: 'bad-shape', relayKeys: 'oops' as never });
    await putProvider({
      ...multiKeyRelay(),
      id: 'mixed',
      relayKeys: [
        { id: 'initial', apiKey: 'stale-copy' },
        { id: 42, apiKey: 'x' },
        { id: 'k-b', apiKey: SECONDARY_SECRET, status: { state: 'weird' } },
        { id: 'k-b', apiKey: 'dup' },
      ] as never,
    });
    const providers = await getAllProviders();
    expect(providers.find((p) => p.id === 'bad-shape')).not.toHaveProperty('relayKeys');
    expect(providers.find((p) => p.id === 'mixed')!.relayKeys).toEqual([
      { id: 'initial', apiKey: '' },
      { id: 'k-b', apiKey: SECONDARY_SECRET },
    ]);
  });
});
