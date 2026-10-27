import { describe, expect, it } from 'vitest';
import { SEARCH_CATALOG_PRODUCTION_KEYS } from '../catalog-keys';
import { SEARCH_CATALOG_SNAPSHOT_VIEW } from '../catalog-snapshot';
import {
  acceptSearchCatalog,
  canonicalCatalogJson,
  catalogFetchAction,
  CATALOG_SCHEMA,
  presetHostCheck,
  regionForConnection,
  regionLinks,
  verifyCatalogSignature,
  type CatalogEntry,
} from '../search-catalog';
import { HARD_LIMITS, STATIC_PARAM_WHITELIST, TRANSPORT_KIND } from '../search-transport';
import { catalogEntry, catalogRegion, loadContract } from './fixtures';

const contract = loadContract('shared/search-contracts/search_catalog_contract.v1.json');
const view = loadContract('shared/search-contracts/search_catalog_view.v1.json');
const catalog: { services: CatalogEntry[] } = contract.catalog;
// The test public key in the fixture is trusted in tests only
const TEST_KEYS: Record<string, string> = { [contract.testKeys.keyId]: contract.testKeys.publicKeyB64 };

describe('external search catalog: canonicalization, signature verification and adoption (search_catalog_contract.v1)', () => {
  it('constants match the fixture: schema, transport, hard limits, static-param allowlist', () => {
    expect(CATALOG_SCHEMA).toBe(contract.constants.schema);
    expect(TRANSPORT_KIND).toBe(contract.constants.transport);
    expect(HARD_LIMITS).toEqual(contract.constants.hardLimits);
    expect(STATIC_PARAM_WHITELIST).toEqual(contract.constants.staticParamWhitelist);
  });

  it('SRCH-CAT-01 canonicalCases: keys sorted by UTF-16 code units, JSON.stringify escaping, safe integers only', () => {
    expect(contract.canonicalCases.length).toBeGreaterThan(0);
    for (const c of contract.canonicalCases) {
      if (c.expect.error) {
        expect(c.expect.error, c.caseId).toBe('non_integer_number');
        expect(() => canonicalCatalogJson(c.input), c.caseId).toThrow(/non-integer number/);
      } else {
        expect(canonicalCatalogJson(c.input), c.caseId).toBe(c.expect.output);
      }
    }
  });

  it('SRCH-CAT-02 acceptCases: signature check, rollback protection, per-entry skipping, tombstone, hard-limit truncation', async () => {
    expect(contract.acceptCases.length).toBeGreaterThan(0);
    for (const c of contract.acceptCases) {
      const result = await acceptSearchCatalog({ state: c.state, incoming: c.incoming, source: c.source, trustedKeys: TEST_KEYS });
      if (!c.expect.accepted) expect(result.current, c.caseId).toEqual(c.state.current);
      else expect((result as { source?: string }).source, c.caseId).toBe(c.source);
      for (const key of Object.keys(c.expect)) {
        expect((result as unknown as Record<string, unknown>)[key], `${c.caseId}.${key}`).toEqual(c.expect[key]);
      }
    }
  });

  it('SRCH-CAT-03 regionCases: site chosen by connection host; hosts outside the table are not reusable', () => {
    expect(contract.regionCases.length).toBeGreaterThan(0);
    for (const c of contract.regionCases) {
      expect(regionForConnection(catalogEntry(catalog, c.serviceId), c.connectionBaseUrl), c.caseId).toBe(c.expect.region);
    }
  });

  it('SRCH-CAT-04 hostCases: bound host is compared with the catalog site host; withdrawal stops key sending', () => {
    expect(contract.hostCases.length).toBeGreaterThan(0);
    for (const c of contract.hostCases) {
      const entry = catalogEntry(catalog, c.serviceId);
      if (c.catalogHostOverride !== undefined) catalogRegion(entry, c.regionId).host = c.catalogHostOverride;
      const verdict = presetHostCheck({ boundHost: c.boundHost, entry, regionId: c.regionId, withdrawn: c.withdrawn === true });
      expect(verdict, c.caseId).toBe(c.expect.verdict);
    }
  });

  it('SRCH-CAT-05 linkCases: site links fall back to entry level key by key', () => {
    expect(contract.linkCases.length).toBeGreaterThan(0);
    for (const c of contract.linkCases) {
      const entry = catalogEntry(catalog, c.serviceId);
      if (c.regionUrlsOverride !== undefined) {
        const region = catalogRegion(entry, c.regionId);
        if (c.regionUrlsOverride === null) delete region.urls;
        else region.urls = c.regionUrlsOverride;
      }
      expect(regionLinks(entry, c.regionId), c.caseId).toEqual(c.expect.links);
    }
  });

  it('SRCH-CAT-06 fetchCases: 200 adopts, 404 withdraws presets, everything else (including 400 from older servers) keeps the current catalog', () => {
    expect(contract.fetchCases.length).toBeGreaterThan(0);
    for (const c of contract.fetchCases) {
      expect(catalogFetchAction(c.input), c.caseId).toBe(c.expect.action);
    }
  });

  it('a fixture catalog signed with the test key verifies; with the production key it fails as unknown key', async () => {
    expect(await verifyCatalogSignature(contract.catalog, TEST_KEYS)).toEqual({ ok: true, reason: null });
    expect(await verifyCatalogSignature(contract.catalog, SEARCH_CATALOG_PRODUCTION_KEYS)).toEqual({ ok: false, reason: 'signature_unknown_key' });
  });
});

describe('production public key and built-in snapshot (search_catalog_view.v1)', () => {
  const ACTIVE = ['deepseek', 'zhipu', 'kimi', 'tavily', 'exa', 'brave', 'perplexity'];

  it('production public key matches the fixture productionKeys', () => {
    expect(SEARCH_CATALOG_PRODUCTION_KEYS).toEqual(contract.productionKeys);
  });

  it('production public key verifies the ?view=search data; all 7 providers are active', async () => {
    const result = await acceptSearchCatalog({
      state: { maxSeenRevision: 0, current: null },
      incoming: view.data,
      source: 'network',
      trustedKeys: SEARCH_CATALOG_PRODUCTION_KEYS,
    });
    expect(result.accepted).toBe(true);
    if (!result.accepted) return;
    expect(result.skipped).toEqual([]);
    expect(result.current.revision).toBe(view.data.revision);
    expect(result.current.services.map((s) => s.id).sort()).toEqual([...ACTIVE].sort());
    expect(result.current.services.every((s) => s.status === 'active')).toBe(true);
  });

  it('the snapshot bundled with the app is adopted by the production public key as well', async () => {
    const snapshot = SEARCH_CATALOG_SNAPSHOT_VIEW as { data: unknown };
    const result = await acceptSearchCatalog({
      state: { maxSeenRevision: 0, current: null },
      incoming: snapshot.data,
      source: 'builtin',
      trustedKeys: SEARCH_CATALOG_PRODUCTION_KEYS,
    });
    expect(result.accepted).toBe(true);
    if (!result.accepted) return;
    expect(result.skipped).toEqual([]);
    expect(result.current.services.filter((s) => s.status === 'active')).toHaveLength(7);
  });

  it('the test public key does not accept the production signature', async () => {
    expect(await verifyCatalogSignature(view.data, TEST_KEYS)).toEqual({ ok: false, reason: 'signature_unknown_key' });
  });
});
