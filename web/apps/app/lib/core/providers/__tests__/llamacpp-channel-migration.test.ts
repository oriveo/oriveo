import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Existing llama.cpp native-channel connections are migrated to the chat channel exactly once.
// The pure function is checked against each llamacppMigrationCases entry; the production entry
// persists through updateProviderRelaySettings.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { updateProviderRelaySettings } from '../../provider-ops';
import {
  migrateLlamacppConnectionsToChatChannelIfNeeded,
  planLlamacppChannelMigration,
} from '../llamacpp-channel-migration';

const partitionMocks = vi.hoisted(() => ({ uid: 'user-1' }));

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  getActiveUIDSync: () => partitionMocks.uid,
  getActiveUID: async () => partitionMocks.uid,
}));

type MigrationCase = {
  caseId: string;
  before: { engineProfile: string | null; transport: string; resolvedAPIBaseURL: string };
  alreadyMigrated: boolean;
  expect: { transport: string; resolvedAPIBaseURL: string; changed: boolean };
};

const migrationCases = loadJSON<{ llamacppMigrationCases: MigrationCase[] }>(
  'generation_parameter_contract.v1.cases.json',
).llamacppMigrationCases;

describe('llamacppMigrationCases (pure function)', () => {
  for (const testCase of migrationCases) {
    it(testCase.caseId, () => {
      expect(planLlamacppChannelMigration(testCase.before, testCase.alreadyMigrated)).toEqual(testCase.expect);
    });
  }

  it('has 5 cases and none are skipped', () => {
    expect(migrationCases).toHaveLength(5);
  });

  it('does not append /v1 when the API root already ends with it; an empty address only switches the channel and writes no address', () => {
    expect(planLlamacppChannelMigration(
      { engineProfile: 'llamacpp', transport: 'llamacpp_native', resolvedAPIBaseURL: 'http://h:8080/v1' }, false,
    )).toEqual({ transport: 'openai_chat_completions', resolvedAPIBaseURL: 'http://h:8080/v1', changed: true });
    expect(planLlamacppChannelMigration(
      { engineProfile: 'llamacpp', transport: 'llamacpp_native', resolvedAPIBaseURL: null }, false,
    )).toEqual({ transport: 'openai_chat_completions', resolvedAPIBaseURL: null, changed: true });
  });
});

function nativeProvider(): Provider {
  return {
    id: 'local-llama',
    kind: 'relay',
    customName: 'Local llama.cpp',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: 'http://127.0.0.1:8080',
    relayKind: 'openai_compatible',
    relayResolvedTransport: 'llamacpp_native',
    relayRequested: {
      transport: 'llamacpp_native',
      engineProfile: 'llamacpp',
      authMode: 'none',
      resolvedAPIBaseURL: 'http://127.0.0.1:8080',
    },
    createdAt: '',
    updatedAt: '',
  } as unknown as Provider;
}

describe('production persistence entry', () => {
  beforeEach(() => {
    localStorage.clear();
    partitionMocks.uid = 'user-1';
  });

  it('native channel -> chat + /v1; running again changes nothing; a later manual native choice is not migrated again', async () => {
    const store = createAppStore();
    store.getState().addProvider(nativeProvider());

    await migrateLlamacppConnectionsToChatChannelIfNeeded(store);
    let saved = store.getState().providers[0];
    expect(saved.relayRequested?.transport).toBe('openai_chat_completions');
    expect(saved.relayRequested?.resolvedAPIBaseURL).toBe('http://127.0.0.1:8080/v1');
    expect(saved.relayResolvedTransport).toBe('openai_chat_completions');

    await migrateLlamacppConnectionsToChatChannelIfNeeded(store);
    expect(store.getState().providers[0]).toEqual(saved);

    // The user switches back to the native channel through the same edit entry
    await updateProviderRelaySettings(store, saved, {
      relayKind: 'openai_compatible',
      relayRequested: { ...saved.relayRequested!, transport: 'llamacpp_native', resolvedAPIBaseURL: 'http://127.0.0.1:8080' },
      relayResolvedTransport: 'llamacpp_native',
    });
    await migrateLlamacppConnectionsToChatChannelIfNeeded(store);
    saved = store.getState().providers[0];
    expect(saved.relayRequested?.transport).toBe('llamacpp_native');
    expect(saved.relayRequested?.resolvedAPIBaseURL).toBe('http://127.0.0.1:8080');
  });

  it('the flag is partitioned per identity: another identity still migrates once on its first load', async () => {
    const store = createAppStore();
    store.getState().addProvider(nativeProvider());
    await migrateLlamacppConnectionsToChatChannelIfNeeded(store);

    partitionMocks.uid = 'user-2';
    const other = createAppStore();
    other.getState().addProvider(nativeProvider());
    await migrateLlamacppConnectionsToChatChannelIfNeeded(other);
    expect(other.getState().providers[0].relayRequested?.transport).toBe('openai_chat_completions');
  });
});

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`shared contract ${fileName} not found`);
    current = parent;
  }
}
