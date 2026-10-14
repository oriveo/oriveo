// Relay address normalization in one place: the add page preview root address and the root address of every catalog GET.
// Fixture: test-fixtures/relay/address-normalize.v1.json (previewCases / catalogCases).

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Provider, RelayRequestedConfig } from '@oriveo/shared';

vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import { createAppStore } from '../../store/app-store';
import { refreshRelayCatalogInStore } from '../provider-sync';
import { catalogAPIRoot, previewAPIRoot } from '../probe/endpoint-normalizer';

interface CatalogCase {
  caseId: string;
  provider: { baseURL: string; relayRequested: Partial<RelayRequestedConfig> };
  expect: { catalogURL: string };
}

interface Fixture {
  previewCases: Array<{ caseId: string; input: string; expect: string | null }>;
  catalogCases: CatalogCase[];
}

const fixture: Fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'address-normalize.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('address-normalize.v1.json not found');
})();

function relayProvider(c: CatalogCase): Provider {
  return {
    id: `relay-${c.caseId}`,
    kind: 'relay',
    status: { kind: 'connected' },
    apiKey: 'sk-relay',
    apiKeyPreview: '',
    baseURLText: c.provider.baseURL,
    relayRequested: { authMode: 'auto', ...c.provider.relayRequested } as RelayRequestedConfig,
    models: [],
    catalogModels: [],
  };
}

describe('RD2-ADDR preview root address (previewAPIRoot)', () => {
  for (const c of fixture.previewCases) {
    it(`RD2-ADDR-PREVIEW-${c.caseId}`, () => {
      expect(previewAPIRoot(c.input)).toBe(c.expect);
    });
  }
});

describe('RD2-ADDR catalog root address (catalogAPIRoot)', () => {
  for (const c of fixture.catalogCases) {
    it(`RD2-ADDR-CATALOG-${c.caseId}`, () => {
      expect(`${catalogAPIRoot(relayProvider(c))}/models`).toBe(c.expect.catalogURL);
    });
  }
});

/* -- Production catalog refresh path: assert the catalog URL actually sent -- */

const requestedURLs: string[] = [];

beforeEach(() => {
  requestedURLs.length = 0;
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    // A public address is forwarded via /api/relay/forward, and the target URL is in X-Relay-Upstream-URL.
    requestedURLs.push(new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input));
    return new Response(
      JSON.stringify({ object: 'list', data: [{ id: 'model-a', object: 'model' }] }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('RD2-REFRESH catalog refresh goes through catalogAPIRoot + /models', () => {
  for (const c of fixture.catalogCases) {
    it(`RD2-REFRESH-${c.caseId}`, async () => {
      const provider = relayProvider(c);
      const store = createAppStore();
      store.setState({ providers: [provider] });

      const result = await refreshRelayCatalogInStore(store, provider);

      expect(requestedURLs).toEqual([c.expect.catalogURL]);
      expect(result.state).toBe('loaded');
      expect(store.getState().providers[0]!.catalogModels.map((model) => model.id)).toEqual(['model-a']);
    });
  }
});
