// Relay multi-key (RK-2) part B: per-key catalog fetch and merge, refresh decode shells, replacing a key does not clear the catalog.
// Fixture: shared test-fixtures/relay/key-binding.v1.json (catalogCases / shellCases).

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayKeyEntry } from '@oriveo/shared';
import { mergeRelayKeyCatalogs, type RelayKeyCatalogResult } from '@oriveo/core/providers/relay-key-catalog';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import { createAppStore } from '../../store/app-store';
import {
  decodeRelayCatalogEntries,
  refreshRelayCatalogInStore,
  resyncProviderInStore,
  verifyRelayProviderCandidate,
  verifyRelayProviderInStore,
} from '../provider-sync';
import { updateProviderKey } from '../../provider-ops';
import { applyRelayKeyOperation } from '../../relay-model-probe-ops';
import { compareCatalogModels } from '../adapters/openai-compatible';

type FixtureCatalog = { id: string; relayListedByKeyIDs?: string[] };

interface Fixture {
  catalogCases: { cases: Array<{
    caseId: string;
    keys: string[];
    previous: FixtureCatalog[];
    results: Record<string, RelayKeyCatalogResult>;
    expect: { catalog: Array<{ id: string; relayListedByKeyIDs: string[] }>; statuses: Record<string, string> };
  }> };
  shellCases: { cases: Array<{ caseId: string; body: string; expect: string[] }> };
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

describe('KEY-CATALOG per-key merge (pure function mergeRelayKeyCatalogs)', () => {
  for (const c of fixture.catalogCases.cases) {
    it(`KEY-CATALOG-${c.caseId}`, () => {
      expect(mergeRelayKeyCatalogs(c.keys, c.previous, c.results)).toEqual(c.expect);
    });
  }
});

/* ── production refresh / key replacement paths ─────────────────────────── */

function model(id: string, extra: Partial<AIModel> = {}): AIModel {
  return {
    id, name: id, capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '',
    ...extra,
  } as AIModel;
}

function relayProvider(input: {
  apiKey: string; relayKeys?: RelayKeyEntry[]; models?: AIModel[]; catalog?: AIModel[];
}): Provider {
  return {
    id: 'relay-kc',
    kind: 'relay',
    status: { kind: 'connected' },
    apiKey: input.apiKey,
    apiKeyPreview: '',
    baseURLText: 'https://relay.example.com/v1',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
    ...(input.relayKeys ? { relayKeys: input.relayKeys } : {}),
    models: input.models ?? [],
    catalogModels: input.catalog ?? [],
  };
}

/** The key actually sent with the request: direct reads Authorization; via server forwarding reads apiKey in the proxy config (the server builds the Bearer from it). */
function authorizationOf(init?: RequestInit): string {
  const headers = new Headers(init?.headers);
  const direct = headers.get('Authorization');
  if (direct) return direct;
  const proxy = headers.get('X-Relay-Proxy-Config');
  return proxy ? `Bearer ${(JSON.parse(proxy) as { apiKey: string }).apiKey}` : '';
}

const requests: string[] = [];
let respond: (authorization: string, url: string) => Response = () => new Response('not found', { status: 404 });

const listing = (ids: string[]) => new Response(
  JSON.stringify({ object: 'list', data: ids.map((id) => ({ id, object: 'model' })) }),
  { status: 200, headers: { 'Content-Type': 'application/json' } },
);

beforeEach(() => {
  requests.length = 0;
  vi.stubGlobal('fetch', vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    const authorization = authorizationOf(init);
    const url = new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(_input);
    requests.push(authorization);
    return respond(authorization, url);
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('KEY-CATALOG production refresh: each of two keys sends once, merged and written back', () => {
  it('KEY-CATALOG-production_refresh_two_keys', async () => {
    const provider = relayProvider({
      apiKey: 'sk-a',
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-claude', apiKey: 'sk-claude' }],
      models: [model('gpt-4o', { relayKeyID: 'initial' })],
      catalog: [model('gpt-4o', { relayListedByKeyIDs: ['initial'] })],
    });
    const store = createAppStore();
    store.setState({ providers: [provider] });
    respond = (authorization) => (authorization === 'Bearer sk-a'
      ? listing(['gpt-4o', 'gpt-4.1'])
      : listing(['claude-sonnet-4-5', 'gpt-4o']));

    const result = await refreshRelayCatalogInStore(store, provider);

    expect(result.state).toBe('loaded');
    expect(requests).toEqual(['Bearer sk-a', 'Bearer sk-claude']);
    const after = store.getState().providers[0]!;
    // Listed models follow the merge result; order uses the same display sort as the single-key path (compareCatalogModels).
    expect(Object.fromEntries(after.catalogModels.map((item) => [item.id, item.relayListedByKeyIDs]))).toEqual({
      'gpt-4o': ['initial', 'k-claude'],
      'gpt-4.1': ['initial'],
      'claude-sonnet-4-5': ['k-claude'],
    });
    expect(after.catalogModels.map((item) => item.id)).toEqual(['claude-sonnet-4-5', 'gpt-4.1', 'gpt-4o']);
    expect(after.catalogModels).toEqual([...after.catalogModels].sort(compareCatalogModels));
    expect(after.relayKeys!.map((key) => key.status?.state)).toEqual(['ok', 'ok']);
    // Enabled models keep their binding; listed ones follow the catalog.
    expect(after.models).toEqual([expect.objectContaining({
      id: 'gpt-4o', relayKeyID: 'initial', relayListedByKeyIDs: ['initial', 'k-claude'],
    })]);
  });

  it('KEY-CATALOG-production_refresh_secret_changed_in_flight_is_skipped', async () => {
    const provider = relayProvider({
      apiKey: 'sk-a',
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-b', apiKey: 'sk-b' }],
      catalog: [model('old-b', { relayListedByKeyIDs: ['k-b'] })],
    });
    const store = createAppStore();
    store.setState({ providers: [provider] });
    respond = (authorization) => {
      if (authorization === 'Bearer sk-b') {
        // The user replaced k-b's value in flight: this key's result is discarded and the previous listing is kept as skipped.
        store.getState().updateProvider(provider.id, {
          relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-b', apiKey: 'sk-b2' }],
        });
        return listing(['new-b']);
      }
      return listing(['gpt-4o']);
    };

    const result = await refreshRelayCatalogInStore(store, provider);

    expect(result.state).toBe('loaded');
    const after = store.getState().providers[0]!;
    expect(after.catalogModels.map((item) => item.id)).toEqual(['gpt-4o', 'old-b']);
    expect(after.relayKeys![1]).toEqual({ id: 'k-b', apiKey: 'sk-b2' });
  });
});

describe('KEY-CATALOG other refresh entry points also persist per-key status', () => {
  const twoKeys = () => relayProvider({
    apiKey: 'sk-a',
    relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-b', apiKey: 'sk-b' }],
    models: [model('gpt-4o', { relayKeyID: 'initial' })],
    catalog: [model('gpt-4o', { relayListedByKeyIDs: ['initial'] }), model('claude-opus-4', { relayListedByKeyIDs: ['k-b'] })],
  });
  const failAll = (authorization: string) => (authorization === 'Bearer sk-a'
    ? new Response(JSON.stringify({ error: 'Invalid API key' }), { status: 401 })
    : new Response(JSON.stringify({ code: 'INSUFFICIENT_BALANCE', message: 'Insufficient balance' }), { status: 403 }));

  it('KEY-CATALOG-resync_all_failed_writes_statuses_keeps_catalog', async () => {
    const provider = twoKeys();
    const store = createAppStore();
    store.setState({ providers: [provider] });
    respond = failAll;
    await resyncProviderInStore(store, provider);
    const after = store.getState().providers[0]!;
    expect(after.catalogModels.map((item) => item.id)).toEqual(['gpt-4o', 'claude-opus-4']);
    expect(after.relayKeys!.map((key) => [key.status?.state, key.status?.httpStatus])).toEqual([['invalid', 401], ['limited', 403]]);
  });

  it('KEY-CATALOG-verify_candidate_carries_statuses', async () => {
    const provider = twoKeys();
    // 1-token verification succeeds, then the catalog is pulled per key: primary key succeeds, k-b has no permission.
    respond = (authorization, url) => {
      if (!url.endsWith('/models')) return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
      return authorization === 'Bearer sk-a' ? listing(['gpt-4o']) : new Response('Forbidden', { status: 403 });
    };
    const ok = await verifyRelayProviderCandidate(provider, { refreshCatalog: true });
    expect(ok.ok).toBe(true);
    expect(ok.relayKeys!.map((key) => key.status?.state)).toEqual(['ok', 'denied']);

    respond = (authorization, url) => (url.endsWith('/models')
      ? failAll(authorization)
      : new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 }));
    const failed = await verifyRelayProviderCandidate(provider, { refreshCatalog: true });
    expect(failed).toMatchObject({ ok: false, phase: 'catalog' });
    expect(failed.relayKeys!.map((key) => key.status?.state)).toEqual(['invalid', 'limited']);
  });
});

describe('RL2-GUIDE-19 catalog sync receives a Codex identity 403', () => {
  it('RL2-GUIDE-19 catalog /models with unclear protocol → still rejected (headers and query parameters), does not let the model transport change', async () => {
    const provider = relayProvider({ apiKey: 'sk-a' });
    const store = createAppStore();
    store.setState({ providers: [provider] });
    respond = () => new Response('{"error":{"message":"Only Codex official clients are allowed"}}', { status: 403 });

    const result = await refreshRelayCatalogInStore(store, provider);

    expect(result.state).toBe('failed');
    const message = (result as { error: { message: string } }).error.message;
    expect(message).toContain('still rejects Oriveo\'s Codex client identity');
    expect(message).not.toContain('set Protocol to OpenAI Responses');
  });
});

describe('KEY-SHELL production refresh decoder accepts three shells', () => {
  for (const c of fixture.shellCases.cases) {
    it(`KEY-SHELL-${c.caseId}`, async () => {
      // The decoder yields ids in upstream order.
      expect(decodeRelayCatalogEntries(JSON.parse(c.body)).map((entry) => entry.id)).toEqual(c.expect);
      // The whole production refresh path accepts this shell; the Web catalog is then sorted by the existing display sort (buildModelsFromCatalog), so compare only as a set.
      const provider = relayProvider({ apiKey: 'sk-a' });
      const store = createAppStore();
      store.setState({ providers: [provider] });
      respond = () => new Response(c.body, { status: 200, headers: { 'Content-Type': 'application/json' } });
      const result = await refreshRelayCatalogInStore(store, provider);
      expect(result.state).toBe('loaded');
      expect(store.getState().providers[0]!.catalogModels.map((item) => item.id).sort()).toEqual([...c.expect].sort());
    });
  }
});

describe('KEY-REPLACE replacing a key does not clear the catalog', () => {
  it('KEY-REPLACE-single_key_keeps_catalog', async () => {
    const catalog = [model('gpt-4o'), model('gpt-4.1')];
    const provider = relayProvider({ apiKey: 'sk-a', models: [model('gpt-4o')], catalog });
    const store = createAppStore();
    store.setState({ providers: [provider] });

    // Production key replacement entry: write the new value, mark unverified; the re-verification then fails.
    expect(await updateProviderKey(store, provider, 'sk-new')).toBe(true);
    const saved = store.getState().providers[0]!;
    expect(saved.apiKey).toBe('sk-new');
    expect(saved.status).toEqual({ kind: 'issue', message: expect.any(String) });
    expect(saved.catalogModels).toEqual(catalog);
    respond = () => new Response(JSON.stringify({ error: { message: 'Invalid API key' } }), { status: 401 });
    await expect(verifyRelayProviderInStore(store, saved)).rejects.toBeDefined();

    const after = store.getState().providers[0]!;
    expect(after.catalogModels).toEqual(catalog);
    // Re-verification 401 writes the primary key status: a single key materializes as one entry, and no key fields are written on models.
    expect(after.relayKeys).toEqual([
      { id: 'initial', apiKey: '', status: { state: 'invalid', httpStatus: 401, checkedAt: expect.any(String) } },
    ]);
    expect(after.models.every((item) => !('relayKeyID' in item))).toBe(true);
  });

  it('KEY-REPLACE-multi_refetches_only_that_key', async () => {
    const provider = relayProvider({
      apiKey: 'sk-a',
      relayKeys: [
        { id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: '2026-10-01T00:00:00.000Z' } },
        { id: 'k-b', apiKey: 'sk-b', status: { state: 'invalid', httpStatus: 401 } },
      ],
      models: [model('claude-opus-4', { relayKeyID: 'k-b', relayDeniedKeyID: 'k-b' })],
      catalog: [
        model('gpt-4o', { relayListedByKeyIDs: ['initial'] }),
        model('claude-opus-4', { relayListedByKeyIDs: ['k-b'] }),
      ],
    });
    const store = createAppStore();
    store.setState({ providers: [provider] });
    respond = () => listing(['claude-opus-4', 'claude-sonnet-4-5']);

    expect(await applyRelayKeyOperation(store, provider, { type: 'replaceSecret', id: 'k-b', apiKey: 'sk-b2' })).toBe(true);

    expect(requests).toEqual(['Bearer sk-b2']);
    const after = store.getState().providers[0]!;
    expect(after.catalogModels.map((item) => [item.id, item.relayListedByKeyIDs])).toEqual([
      ['claude-opus-4', ['k-b']],
      ['claude-sonnet-4-5', ['k-b']],
      ['gpt-4o', ['initial']],
    ]);
    expect(after.relayKeys![0]).toEqual(provider.relayKeys![0]);
    expect(after.relayKeys![1]).toEqual({ id: 'k-b', apiKey: 'sk-b2', status: { state: 'ok', checkedAt: expect.any(String) } });
    expect(after.models[0]).not.toHaveProperty('relayDeniedKeyID');
  });

  it('KEY-OPS-rebind_lazy_probe (data-layer entry: after rebinding, a model with no transport is still enabled with lazy verification)', async () => {
    const provider: Provider = {
      ...relayProvider({
        apiKey: 'sk-a',
        relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k-b', apiKey: 'sk-b' }],
        models: [model('gpt-4o', {
          relayKeyID: 'initial', relayDeniedKeyID: 'initial',
          relayTransport: 'openai_chat_completions', relayTransportSource: 'reachable',
        })],
      }),
      // Lazy verification is sent only on auto-detected connections (when the user selected the connection transport, no probe).
      relayRequested: { transport: 'auto', authMode: 'bearer' },
    };
    const store = createAppStore();
    store.setState({ providers: [provider] });
    const ping = vi.fn(async (_input: { apiKey: string; modelID: string }) => ({ ok: true }));

    expect(await applyRelayKeyOperation(store, provider, { type: 'rebind', modelID: 'gpt-4o', keyID: 'k-b' }, {
      ping, lookupFamily: async () => undefined,
    })).toBe(true);

    expect(ping).toHaveBeenCalledTimes(1);
    expect(ping.mock.calls[0]![0]).toMatchObject({ apiKey: 'sk-b', modelID: 'gpt-4o' });
    expect(requests).toEqual([]);
    const after = store.getState().providers[0]!.models[0]!;
    expect(after.relayKeyID).toBe('k-b');
    expect(after).not.toHaveProperty('relayDeniedKeyID');
    expect(after.relayTransportSource).toBe('reachable');
  });

  it('KEY-OPS-refused_writes_nothing (delete the last key)', async () => {
    const provider = relayProvider({ apiKey: 'sk-a' });
    const store = createAppStore();
    store.setState({ providers: [provider] });
    expect(await applyRelayKeyOperation(store, provider, { type: 'delete', id: 'initial' })).toBe(false);
    expect(store.getState().providers[0]).toBe(provider);
    expect(requests).toEqual([]);
  });
});
