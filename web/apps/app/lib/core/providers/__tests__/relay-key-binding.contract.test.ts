// Relay multi-key contract test (RK-2), part A: binding / key operations / read model / zero migration / wiring.
// Fixture: shared test-fixtures/relay/key-binding.v1.json (same file on all three platforms).

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayKeyEntry } from '@oriveo/shared';
import {
  RELAY_IMPLICIT_KEY_ID,
  applyRelayKeyOp,
  bindRelayKey,
  relayKeyIDs,
  relayKeyRows,
  relayModelKeyState,
  relayShowsKeyUI,
  type RelayKeyOp,
} from '@oriveo/shared/relay/relay-keys';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import { createAppStore } from '../../store/app-store';
import { addManualProviderModels, enableProviderModel } from '../../provider-model-ops';
import { mergeRelayEnabledModels, refreshRelayCatalogInStore } from '../provider-sync';
import { relayProbeConnectionIdentity } from '../../relay-model-probe-ops';
import { getAllProviders, putProvider, resetDBConnection } from '../../../infra/storage/idb';
import { setActiveUID } from '../../../infra/storage/partition';

type FixtureModel = { id: string; relayKeyID?: string; relayDeniedKeyID?: string; relayTransport?: string; relayTransportSource?: string };
type FixtureCatalog = { id: string; relayListedByKeyIDs?: string[] };
type FixtureProvider = { apiKey: string; relayKeys?: RelayKeyEntry[]; models: FixtureModel[]; catalog: FixtureCatalog[] };

interface Fixture {
  implicitKeyID: string;
  bindCases: { cases: Array<{
    caseId: string; keys: string[]; catalog: FixtureCatalog[]; enabled: FixtureModel[]; target: string;
    families: Record<string, string | null>; expect: string | null;
  }> };
  opsCases: { cases: Array<{ caseId: string; op: RelayKeyOp; provider: FixtureProvider; expect: FixtureProvider | 'refused' }> };
  readCases: { cases: Array<{ caseId: string; provider: FixtureProvider; expect: {
    showsKeyUI: boolean;
    rows: Array<Record<string, unknown>>;
    models: Record<string, { boundKeyID: string; alternateKeyIDs: string[]; deniedOnCurrentKey: boolean }>;
  } }> };
  legacyCases: { cases: Array<{
    caseId: string; stored: FixtureProvider; enable?: string; refresh?: { ok: string[] } | { status: number; body: string };
    expect: {
      keyIDs?: string[]; resolve?: Record<string, string>; relayKeysPersisted?: boolean; modelKeyFieldsPersisted?: boolean; catalogIDs?: string[];
      relayKeys?: Array<{ id: string; apiKey: string; status?: { state: string; httpStatus?: number } }>;
    };
  }> };
}

const fixture: Fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'key-binding.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('key-binding.v1.json not found');
})();

const MODEL_KEY_FIELDS = ['relayKeyID', 'relayListedByKeyIDs', 'relayDeniedKeyID'] as const;

function model(input: Partial<AIModel> & { id: string }): AIModel {
  return {
    name: input.id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...input,
  } as AIModel;
}

/** Fixture connection → this platform's production-shaped Provider (fixture `catalog` is this platform's `catalogModels`). */
function relayProvider(input: FixtureProvider, id = 'relay-k'): Provider {
  return {
    id,
    kind: 'relay',
    status: { kind: 'connected' },
    apiKey: input.apiKey,
    apiKeyPreview: '',
    baseURLText: 'https://relay.example.com/v1',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    ...(input.relayKeys ? { relayKeys: input.relayKeys } : {}),
    models: input.models.map((item) => model(item as Partial<AIModel> & { id: string })),
    catalogModels: input.catalog.map((item) => model(item)),
  };
}

const MODEL_COMPARED_FIELDS = ['id', 'relayKeyID', 'relayDeniedKeyID', 'relayTransport', 'relayTransportSource', 'relayListedByKeyIDs'];

function pick(source: object, fields: readonly string[]): Record<string, unknown> {
  const record = source as Record<string, unknown>;
  return Object.fromEntries(fields.filter((field) => record[field] !== undefined).map((field) => [field, record[field]]));
}

/** Projection compared by fixture opsCases: apiKey, relayKeys, models, catalog. */
function projectOps(provider: Provider): FixtureProvider {
  return {
    apiKey: provider.apiKey,
    ...(provider.relayKeys ? { relayKeys: provider.relayKeys } : {}),
    models: provider.models.map((item) => pick(item, MODEL_COMPARED_FIELDS) as FixtureModel),
    catalog: provider.catalogModels.map((item) => pick(item, ['id', 'relayListedByKeyIDs']) as FixtureCatalog),
  };
}

function hasModelKeyFields(provider: Provider): boolean {
  return [...provider.models, ...provider.catalogModels]
    .some((item) => MODEL_KEY_FIELDS.some((field) => field in item));
}

describe('KEY-BIND（Web）', () => {
  it('implicit key id matches the fixture', () => {
    expect(RELAY_IMPLICIT_KEY_ID).toBe(fixture.implicitKeyID);
  });

  for (const c of fixture.bindCases.cases) {
    it(`KEY-BIND-${c.caseId}`, () => {
      expect(bindRelayKey({
        keys: c.keys,
        catalog: c.catalog,
        enabled: c.enabled,
        targetModelID: c.target,
        family: (id) => c.families[id] ?? null,
      })).toBe(c.expect);
    });
  }
});

describe('KEY-OPS（Web）', () => {
  for (const c of fixture.opsCases.cases) {
    it(`KEY-OPS-${c.caseId}`, () => {
      const result = applyRelayKeyOp(relayProvider(c.provider), c.op);
      if (c.expect === 'refused') {
        expect(result).toBe('refused');
        return;
      }
      expect(result).not.toBe('refused');
      const next = result as Provider;
      expect(projectOps(next)).toEqual(c.expect);
      // Invariant: the first key's value is stored empty; the primary key value lives only in apiKey.
      if (next.relayKeys) expect(next.relayKeys[0]!.apiKey).toBe('');
    });
  }
  it('KEY-OPS-implicit_single_key_refuses_rename_move_rebind (always refused when there is no key list, including targeting initial)', () => {
    const implicit = relayProvider({ apiKey: 'sk-a', models: [{ id: 'gpt-4o' }], catalog: [{ id: 'gpt-4o' }] });
    const ops: RelayKeyOp[] = [
      { type: 'rename', id: 'initial', name: 'Main' },
      { type: 'move', id: 'initial', toIndex: 0 },
      { type: 'rebind', modelID: 'gpt-4o', keyID: 'initial' },
      { type: 'rename', id: 'k-x', name: 'X' },
      { type: 'move', id: 'k-x', toIndex: 0 },
      { type: 'rebind', modelID: 'gpt-4o', keyID: 'k-x' },
    ];
    for (const op of ops) expect(applyRelayKeyOp(implicit, op)).toBe('refused');
  });
});

describe('KEY-READ（Web）', () => {
  for (const c of fixture.readCases.cases) {
    it(`KEY-READ-${c.caseId}`, () => {
      const provider = relayProvider(c.provider);
      expect(relayShowsKeyUI(provider)).toBe(c.expect.showsKeyUI);
      // The mask goes through this platform's formatApiKeyPreview and is not part of the fixture comparison.
      expect(relayKeyRows(provider).map(({ preview: _preview, ...row }) => row)).toEqual(c.expect.rows);
      for (const [modelID, state] of Object.entries(c.expect.models)) {
        expect(relayModelKeyState(provider, modelID)).toEqual(state);
      }
    });
  }
});

describe('KEY-LEGACY zero migration: production decode + production enable + production catalog merge (Web)', () => {
  beforeEach(async () => {
    resetDBConnection();
    for (const db of await indexedDB.databases()) {
      if (db.name) indexedDB.deleteDatabase(db.name);
    }
    await setActiveUID('account-a');
  });

  async function storedThroughProductionDecode(stored: FixtureProvider): Promise<Provider> {
    await putProvider(JSON.parse(JSON.stringify(relayProvider(stored))) as Provider);
    const [decoded] = await getAllProviders();
    return decoded!;
  }

  for (const c of fixture.legacyCases.cases) {
    it(`KEY-LEGACY-${c.caseId}`, async () => {
      const decoded = await storedThroughProductionDecode(c.stored);
      expect(decoded).not.toHaveProperty('relayKeys');

      if (c.expect.keyIDs) expect(relayKeyIDs(decoded)).toEqual(c.expect.keyIDs);
      for (const [modelID, secret] of Object.entries(c.expect.resolve ?? {})) {
        expect(resolveProviderAPIKey(decoded, modelID === 'null' ? null : modelID)).toBe(secret);
      }

      let after = decoded;
      if (c.enable) {
        const store = createAppStore();
        store.setState({ providers: [decoded] });
        const target = decoded.catalogModels.find((item) => item.id === c.enable)!;
        enableProviderModel(store, decoded, target);
        after = store.getState().providers[0]!;
        expect(after.models.map((item) => item.id)).toContain(c.enable);
      }
      if (c.refresh) {
        // Production catalog refresh (refreshRelayCatalogInStore): the fake relay returns the catalog or fails as the fixture says.
        const refresh = c.refresh;
        const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => ('ok' in refresh
          ? new Response(JSON.stringify({ object: 'list', data: refresh.ok.map((id) => ({ id, object: 'model' })) }), {
            status: 200, headers: { 'Content-Type': 'application/json' },
          })
          : new Response(refresh.body, { status: refresh.status, headers: { 'Content-Type': 'application/json' } })));
        try {
          const store = createAppStore();
          store.setState({ providers: [after] });
          await refreshRelayCatalogInStore(store, after);
          after = store.getState().providers[0]!;
        } finally {
          fetchMock.mockRestore();
        }
        // Before persisting, apply this platform's display sort (compareCatalogModels); the fixture only decides catalog membership.
        expect(after.catalogModels.map((item) => item.id).sort()).toEqual([...c.expect.catalogIDs!].sort());
      }
      if (c.expect.relayKeysPersisted !== undefined) {
        await putProvider(after);
        const [reloaded] = await getAllProviders();
        if (c.expect.relayKeysPersisted) {
          // checkedAt is not compared; state / httpStatus are compared as the fixture gives them.
          expect(reloaded!.relayKeys?.map((key) => ({
            id: key.id,
            apiKey: key.apiKey,
            ...(key.status ? { status: {
              state: key.status.state,
              ...(c.expect.relayKeys?.find((item) => item.id === key.id)?.status?.httpStatus !== undefined
                ? { httpStatus: key.status.httpStatus }
                : {}),
            } } : {}),
          }))).toEqual(c.expect.relayKeys);
        } else {
          expect(reloaded).not.toHaveProperty('relayKeys');
        }
        expect(hasModelKeyFields(reloaded!)).toBe(c.expect.modelKeyFieldsPersisted);
      }
    });
  }
});

describe('RK-2 wiring: multi-key connection enable / manual add writes binding (Web)', () => {
  const twoKeys: FixtureProvider = {
    apiKey: 'sk-a',
    relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-claude', name: 'Claude', apiKey: 'sk-claude' }],
    models: [{ id: 'gpt-4.1', relayKeyID: 'initial' }],
    catalog: [
      { id: 'gpt-4o', relayListedByKeyIDs: ['initial'] },
      { id: 'claude-sonnet-4-5', relayListedByKeyIDs: ['k-claude'] },
      { id: 'claude-opus-4', relayListedByKeyIDs: ['initial', 'k-claude'] },
    ],
  };

  it('enabling a catalog model listed by only one key → bind that key; an already-enabled same family follows', () => {
    const provider = relayProvider(twoKeys);
    const store = createAppStore();
    store.setState({ providers: [provider] });
    enableProviderModel(store, provider, provider.catalogModels[1]!);
    enableProviderModel(store, provider, provider.catalogModels[2]!);
    const models = store.getState().providers[0]!.models;
    expect(models.find((item) => item.id === 'claude-sonnet-4-5')?.relayKeyID).toBe('k-claude');
    // Both keys list claude-opus-4: follow the already-enabled same-family claude-sonnet-4-5 to k-claude.
    expect(models.find((item) => item.id === 'claude-opus-4')?.relayKeyID).toBe('k-claude');
    expect(models.find((item) => item.id === 'gpt-4.1')?.relayKeyID).toBe('initial');
    expect(resolveProviderAPIKey(store.getState().providers[0]!, 'claude-opus-4')).toBe('sk-claude');
  });

  it('manual add: the key of an already-enabled same-family model, otherwise the primary key', () => {
    const provider = relayProvider({ ...twoKeys, models: [{ id: 'claude-sonnet-4-5', relayKeyID: 'k-claude' }] });
    const store = createAppStore();
    store.setState({ providers: [provider] });
    addManualProviderModels(store, provider, ['claude-private-1', 'my-model']);
    const models = store.getState().providers[0]!.models;
    expect(models.find((item) => item.id === 'claude-private-1')?.relayKeyID).toBe('k-claude');
    expect(models.find((item) => item.id === 'my-model')?.relayKeyID).toBe('initial');
  });

  it('undoing a removal restores the original binding: a relayKeyID already in the list is not recomputed', () => {
    const provider = relayProvider(twoKeys);
    const store = createAppStore();
    store.setState({ providers: [provider] });
    enableProviderModel(store, provider, model({ id: 'gpt-4o', relayKeyID: 'k-claude' }));
    expect(store.getState().providers[0]!.models.find((item) => item.id === 'gpt-4o')?.relayKeyID).toBe('k-claude');
  });

  it('catalog merge carries back the three local fields by id', () => {
    const enabled = [model({ id: 'gpt-4o', relayKeyID: 'k-claude', relayDeniedKeyID: 'initial', relayListedByKeyIDs: ['initial'] })];
    const [merged] = mergeRelayEnabledModels(enabled, [model({ id: 'gpt-4o' })]);
    expect(pick(merged!, MODEL_KEY_FIELDS)).toEqual({
      relayKeyID: 'k-claude', relayDeniedKeyID: 'initial', relayListedByKeyIDs: ['initial'],
    });
    const [fresh] = mergeRelayEnabledModels(enabled, [model({ id: 'gpt-4o', relayListedByKeyIDs: ['initial', 'k-claude'] })]);
    expect(fresh!.relayListedByKeyIDs).toEqual(['initial', 'k-claude']);
  });

  it('probe write-back identity follows the probed model\'s effective key, excluding key name and status', () => {
    const provider = relayProvider({ ...twoKeys, models: [{ id: 'gpt-4.1', relayKeyID: 'initial' }, { id: 'claude-sonnet-4-5', relayKeyID: 'k-claude' }] });
    expect(relayProbeConnectionIdentity(provider, 'gpt-4.1')).not.toBe(relayProbeConnectionIdentity(provider, 'claude-sonnet-4-5'));
    const renamed: Provider = {
      ...provider,
      relayKeys: [
        { id: 'initial', name: 'Main', apiKey: '', status: { state: 'ok', httpStatus: 200 } },
        { id: 'k-claude', name: 'Other', apiKey: 'sk-claude', status: { state: 'invalid', httpStatus: 401 } },
      ],
    };
    expect(relayProbeConnectionIdentity(renamed, 'claude-sonnet-4-5')).toBe(relayProbeConnectionIdentity(provider, 'claude-sonnet-4-5'));
    // The value of the key bound to the probed model changed → identity changes.
    const replaced = applyRelayKeyOp(provider, { type: 'replaceSecret', id: 'k-claude', apiKey: 'sk-claude-2' }) as Provider;
    expect(relayProbeConnectionIdentity(replaced, 'claude-sonnet-4-5')).not.toBe(relayProbeConnectionIdentity(provider, 'claude-sonnet-4-5'));
    expect(relayProbeConnectionIdentity(replaced, 'gpt-4.1')).toBe(relayProbeConnectionIdentity(provider, 'gpt-4.1'));
  });
  it('connection-level catalog failure redaction list contains all keys (production catalog refresh)', async () => {
    const provider = relayProvider(twoKeys);
    const store = createAppStore();
    store.setState({ providers: [provider] });
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(
      JSON.stringify({ error: { message: 'bad keys sk-a and sk-claude' } }),
      { status: 401, headers: { 'Content-Type': 'application/json' } },
    ));
    try {
      const result = await refreshRelayCatalogInStore(store, provider);
      expect(result.state).toBe('failed');
      const error = (result as { error: { detail?: string } }).error;
      expect(error.detail).toBeDefined();
      expect(error.detail).not.toContain('sk-claude');
      expect(error.detail).not.toContain('sk-a ');
    } finally {
      fetchMock.mockRestore();
    }
  });
});
