import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Shared fixture catalog-revision-report.v1.json: per-provider catalog revision
 * criteria and report counts. Goes through the production refreshMetadata path and asserts the catalog actually left in the cache and the trackEvent reports.
 *
 * The fixture integer revision lands in two places on Web: the schema 2 envelope metadataRevision of the catalog (forward-only rule),
 * and the catalogRevision string registered by the index / self-reported by the catalog (derived from the same integer). A cached revision of 0 means
 * the bundled snapshot: its catalogRevision never equals any index registration, so a fetch always happens.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pruneBlobs } from '../../../infra/storage/blob-cache';

const trackEvent = vi.fn();
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: (...args: unknown[]) => trackEvent(...args),
}));

const ROOT = resolve(__dirname, '../../../../../../..');

interface RevisionReportCase {
  id: string;
  cachedCatalogRevision: number;
  indexAnnounces: number;
  // null = the fixture declares that no catalog request is sent (expect.requestSent=false); any catalog request is a regression
  responseRevision: number | null;
  indexAfterRefetch: number | null;
  expect: {
    outcome: 'accept' | 'reject' | 'unchanged';
    report: string | null;
    reports?: number;
    etag?: 'refreshed' | 'unchanged';
    requestSent?: boolean;
  };
}

interface CatalogContractFixture {
  indexResponse: { data: Record<string, unknown> & { providers: Record<string, Record<string, unknown>> } };
  catalogResponses: Record<string, { data: Record<string, unknown> & { catalogRevision: string } }>;
}

const CASES = (JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-catalog/catalog-revision-report.v1.json'), 'utf8',
)) as { cases: RevisionReportCase[] }).cases;

const CORPUS = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/model-contracts/metadata_catalog_contract.v1.json'), 'utf8',
)) as CatalogContractFixture;

const KIND = 'openAI';

/** The catalogRevision string derived from one integer revision; the bundled snapshot gets a separate value the index never registers. */
function catalogRevisionOf(revision: number | 'bundled'): string {
  const seed = revision === 'bundled' ? 'b' : revision.toString(16);
  return `sha256:${seed.padStart(64, '0')}`;
}

function schema2<T extends Record<string, unknown>>(data: T, metadataRevision: number) {
  return { ...data, metadataSchema: 2, metadataRevision, generatedAt: '2026-10-19T00:00:00Z' };
}

function json(body: unknown, etag: string, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: etag, ...extraHeaders },
  });
}

function indexAnnouncing(revision: number | 'bundled') {
  const data = CORPUS.indexResponse.data;
  return json({
    data: {
      ...data,
      providers: { ...data.providers, [KIND]: { ...data.providers[KIND], catalogRevision: catalogRevisionOf(revision) } },
    },
  }, `"index-${revision}"`);
}

function catalogAt(revision: number | 'bundled', metadataRevision: number, etag: string) {
  const catalogRevision = catalogRevisionOf(revision);
  return json(
    { data: schema2({ ...CORPUS.catalogResponses[KIND].data, catalogRevision }, metadataRevision) },
    etag,
    { 'X-Metadata-Catalog-Revision': catalogRevision },
  );
}

function catalogKind(url: string): string | null {
  const match = /view=catalog&provider=([^&]+)/.exec(url);
  return match ? decodeURIComponent(match[1]) : null;
}

function isIndex(url: string): boolean {
  // After a mismatch the index refetch carries &fresh= (see catalog-request-shape); judge by the view param, not by how the URL ends.
  return new URL(url, 'https://metadata.test').searchParams.get('view') === 'index';
}

type Route = (url: string) => Response;

function mockFetch(route: Route) {
  return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => route(String(input)));
}

async function freshClient() {
  vi.resetModules();
  const metadata = await importMetadataClient();
  metadata.__resetMetadataClientForTest();
  return metadata;
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 30));
}

async function clearCaches(): Promise<void> {
  await pruneBlobs('oriveo:metadata:', []);
  localStorage.clear();
}

type MetadataClientModule = typeof import('../metadata-client');

// The latest instance dynamically imported after vi.resetModules in a case; afterEach waits for its background refresh / persistence to settle before restoring,
// so nothing leaks into the next case.
let metadataInstance: MetadataClientModule | null = null;

async function importMetadataClient(): Promise<MetadataClientModule> {
  metadataInstance = await import('../metadata-client');
  return metadataInstance;
}

async function restoreMetadataInstance(): Promise<void> {
  if (!metadataInstance) return;
  await metadataInstance.__settleMetadataBackgroundWorkForTest();
  metadataInstance.__resetMetadataClientForTest();
  metadataInstance = null;
}

describe('catalog-revision-report.v1', () => {
  beforeEach(async () => {
    trackEvent.mockClear();
    await clearCaches();
  });

  afterEach(async () => {
    await restoreMetadataInstance();
    vi.restoreAllMocks();
    await clearCaches();
  });

  for (const entry of CASES) {
    it(`CATALOG-REVISION-REPORT-${entry.id}`, async () => {
      // First let the cache hold the catalog at cachedCatalogRevision
      const cachedLabel = entry.cachedCatalogRevision === 0 ? 'bundled' : entry.cachedCatalogRevision;
      let phase: 'seed' | 'sync' = 'seed';
      let indexCalls = 0;
      let catalogCalls = 0;
      const responseEtag = `"catalog-${entry.responseRevision}"`;
      mockFetch((url) => {
        if (isIndex(url)) {
          if (phase === 'seed') return indexAnnouncing(cachedLabel);
          indexCalls += 1;
          return indexAnnouncing(indexCalls > 1 && entry.indexAfterRefetch !== null
            ? entry.indexAfterRefetch
            : entry.indexAnnounces);
        }
        if (catalogKind(url) === KIND) {
          if (phase === 'seed') return catalogAt(cachedLabel, entry.cachedCatalogRevision, '"catalog-seed"');
          catalogCalls += 1;
          if (entry.responseRevision === null) throw new Error(`catalog request not expected for ${entry.id}`);
          return catalogAt(entry.responseRevision, entry.responseRevision, responseEtag);
        }
        throw new Error(`unexpected metadata request ${url}`);
      });
      const metadata = await freshClient();
      metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [KIND], hasRelay: false }));
      await metadata.refreshMetadata();
      await settle();
      const held = (await (await metadata.__readSplitMetadataCacheForTest()).catalog(KIND))?.value;
      expect(held).toMatchObject({
        metadataRevision: entry.cachedCatalogRevision,
        revision: catalogRevisionOf(cachedLabel),
        etag: '"catalog-seed"',
      });

      phase = 'sync';
      trackEvent.mockClear();
      await metadata.refreshMetadata();
      await settle();
      const after = (await (await metadata.__readSplitMetadataCacheForTest()).catalog(KIND))?.value;

      // Index registration matches the cache: zero catalog requests; index announces another revision: it must fetch (so a "never fetches again" regression cannot pass silently).
      // The bundled snapshot (cache 0) catalogRevision is never registered by the index, so it is treated as an announced update.
      const indexMatchesCache = catalogRevisionOf(entry.indexAnnounces) === catalogRevisionOf(cachedLabel);
      if (indexMatchesCache) expect(catalogCalls).toBe(0);
      else expect(catalogCalls).toBeGreaterThan(0);
      // Cases where the fixture explicitly declares requestSent=false: announce the revision truthfully and assert zero requests from the fixture field
      if (entry.expect.requestSent === false) {
        expect(indexMatchesCache).toBe(true);
        expect(indexCalls).toBeGreaterThan(0); // the sync really ran, so zero requests is not the result of a whole-round short circuit
        expect(catalogCalls).toBe(0);
      }

      if (entry.expect.outcome === 'accept') {
        expect(after).toMatchObject({
          metadataRevision: entry.responseRevision,
          revision: catalogRevisionOf(entry.responseRevision),
          etag: responseEtag,
        });
      } else {
        // reject / unchanged: the catalog in hand is kept as is
        expect(after).toMatchObject({
          metadataRevision: entry.cachedCatalogRevision,
          revision: catalogRevisionOf(cachedLabel),
        });
        // A rejection leaves the ETag alone. expect.etag = 'refreshed': the new ETag from a 200 with an equal revision is persisted atomically first,
        // and is not rolled back even if it later mismatches the index and goes revision_mismatch; when index and cache agree there are zero catalog requests and the ETag stays (expect.etag = 'unchanged').
        if (entry.expect.outcome === 'reject') expect(after?.etag).toBe('"catalog-seed"');
        if (entry.expect.etag === 'refreshed') expect(after?.etag).toBe(responseEtag);
        if (entry.expect.etag === 'unchanged') expect(after?.etag).toBe('"catalog-seed"');
      }
      expect(metadata.resolveCatalogModel(Object.keys(CORPUS.catalogResponses[KIND].data.models as object)[0], KIND))
        .not.toBeNull();

      const reports = trackEvent.mock.calls
        .filter(([name, props]) => name === 'metadata_catalog_rejected'
          && (props as { provider_kind?: string }).provider_kind === 'openai')
        .map(([, props]) => (props as { reason: string }).reason);
      expect(reports).not.toContain('catalog_revision');
      if (entry.expect.report === null) {
        expect(reports).toEqual([]);
      } else {
        expect(reports).toEqual(Array(entry.expect.reports ?? 1).fill(entry.expect.report));
      }
    });
  }
});
