import 'fake-indexeddb/auto';

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { beforeEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { getAllProviders, putProvider, resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';
import { sanitizeProviders } from '../backup-export';

interface ModelCase {
  caseId: string;
  model: Record<string, unknown>;
  expect: Record<string, unknown>;
}

function loadContract(): { modelFields: { all: string[] }; modelCases: ModelCase[] } {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'portable-config.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8'));
    dir = path.dirname(dir);
  }
  throw new Error('portable-config.v1.json not found');
}

const contract = loadContract();

function makeModel(id: string, extra: Record<string, unknown> = {}): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    isManual: true,
    ...extra,
  } as AIModel;
}

function makeRelayProvider(models: AIModel[]): Provider {
  return {
    id: 'relay-1',
    kind: 'relay',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: 'sk-test',
    apiKeyPreview: '••••test',
    baseURLText: 'https://relay.example.com',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
  };
}

function relayFieldsOf(model: AIModel): Record<string, unknown> {
  const source = model as unknown as Record<string, unknown>;
  return Object.fromEntries(
    contract.modelFields.all.filter((field) => field in source).map((field) => [field, source[field]]),
  );
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

describe('Relay model-level fields: local storage round trip and backup', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  it('RL2-MIGRATE-02 the three fields survive a local storage write/read round trip unchanged, and backup export carries them too', async () => {
    const full = contract.modelCases.find((item) => item.caseId === 'all_three_fields_round_trip')!;
    await putProvider(makeRelayProvider([makeModel('claude-x', full.model), makeModel('plain')]));

    const [stored] = await getAllProviders();
    expect(relayFieldsOf(stored!.models[0]!)).toEqual(full.expect);
    expect(relayFieldsOf(stored!.catalogModels[0]!)).toEqual(full.expect);
    expect(relayFieldsOf(stored!.models[1]!)).toEqual({});

    // A backup is the user's own file: the three fields are exported together with the Provider, while secrets are stripped as usual.
    const [exported] = sanitizeProviders([stored!]);
    expect(exported!.apiKey).toBe('');
    expect(relayFieldsOf(exported!.models[0]!)).toEqual(full.expect);
    expect(relayFieldsOf(exported!.catalogModels[0]!)).toEqual(full.expect);
  });

  for (const item of contract.modelCases) {
    it(`RL2-DATA-01 ${item.caseId} local storage read-back goes through production sanitizing`, async () => {
      // Write a raw row as another version / a backup file would have, then read it back through the production read entry.
      await putProvider(makeRelayProvider([makeModel('m', item.model)]));
      const [stored] = await getAllProviders();
      expect(relayFieldsOf(stored!.models[0]!)).toEqual(item.expect);
      expect(relayFieldsOf(stored!.catalogModels[0]!)).toEqual(item.expect);
      expect(stored!.models[0]!.id).toBe('m');
    });
  }
});
