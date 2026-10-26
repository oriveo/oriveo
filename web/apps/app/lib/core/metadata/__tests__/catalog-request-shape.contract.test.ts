import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Shared fixture catalog-request-shape.v1.json:
 * split-view metadata requests are addressed by revision. A catalog request carries rev=<the catalogRevision the index registers for that provider>;
 * after a revision mismatch, the one index refetch carries fresh=<one-time value> to reach the origin, and regular index fetches do not.
 * Goes through the production refreshMetadata path and asserts the URLs the fetch stub actually received.
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

type Announces = Record<string, string | null>;

interface RequestShape { provider?: string; rev?: string | null; fresh?: string | null }

interface RequestShapeCase {
  id: string;
  indexAnnounces?: Announces;
  firstCatalogResponseRevision?: string;
  indexAfterRefetch?: Announces;
  expect: {
    catalogRequest?: RequestShape;
    indexRequest?: RequestShape;
    firstCatalogRequest?: RequestShape;
    indexRefetch?: { fresh: 'non-empty' };
    secondCatalogRequest?: RequestShape;
    outcome?: 'accept';
    report?: string | null;
  };
}

interface CatalogContractFixture {
  indexResponse: { data: Record<string, unknown> & { providers: Record<string, Record<string, unknown>> } };
  catalogResponses: Record<string, { data: Record<string, unknown> & { catalogRevision: string } }>;
}

const FIXTURE = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-catalog/catalog-request-shape.v1.json'), 'utf8',
)) as { params: { catalogRevision: string; cacheBust: string }; cases: RequestShapeCase[] };
const REV = FIXTURE.params.catalogRevision;
const FRESH = FIXTURE.params.cacheBust;

const CORPUS = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/model-contracts/metadata_catalog_contract.v1.json'), 'utf8',
)) as CatalogContractFixture;

const KIND = 'openAI';
const SEED_REVISION = `sha256:${'0'.repeat(64)}`;

function json(body: unknown, etag: string, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: etag, ...extraHeaders },
  });
}

let indexSerial = 0;

/** Fixture indexAnnounces: a null value = the index registers no catalogRevision for that provider. */
function indexAnnouncing(announces: Announces) {
  const data = CORPUS.indexResponse.data;
  const providers = { ...data.providers };
  for (const [kind, revision] of Object.entries(announces)) {
    const { catalogRevision: _drop, ...rest } = providers[kind] ?? {};
    providers[kind] = revision === null ? rest : { ...rest, catalogRevision: revision };
  }
  indexSerial += 1;
  return json({ data: { ...data, providers } }, `"index-${indexSerial}"`);
}

function catalogAt(catalogRevision: string, etag: string) {
  return json(
    { data: { ...CORPUS.catalogResponses[KIND].data, catalogRevision } },
    etag,
    { 'X-Metadata-Catalog-Revision': catalogRevision },
  );
}

function params(url: string): URLSearchParams {
  return new URL(url, 'https://metadata.test').searchParams;
}

function view(url: string): string | null {
  return params(url).get('view');
}

/** The parts of the requests actually sent that match the fixture; missing params are recorded as null. */
function shapeOf(url: string): RequestShape {
  const query = params(url);
  return {
    ...(query.get('provider') !== null ? { provider: query.get('provider')! } : {}),
    rev: query.get(REV),
    fresh: query.get(FRESH),
  };
}

function expectShape(url: string | undefined, expected: RequestShape) {
  expect(url).toBeDefined();
  const actual = shapeOf(url!);
  if (expected.provider !== undefined) expect(actual.provider).toBe(expected.provider);
  if (expected.rev !== undefined) expect(actual.rev).toBe(expected.rev);
  if (expected.fresh !== undefined) expect(actual.fresh).toBe(expected.fresh);
}

async function clearCaches(): Promise<void> {
  await pruneBlobs('oriveo:metadata:', []);
  localStorage.clear();
}

async function settle(): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, 30));
}

type MetadataClientModule = typeof import('../metadata-client');
let metadataInstance: MetadataClientModule | null = null;

async function freshClient(): Promise<MetadataClientModule> {
  vi.resetModules();
  metadataInstance = await import('../metadata-client');
  metadataInstance.__resetMetadataClientForTest();
  return metadataInstance;
}

/**
 * First seed the cache with SEED_REVISION (a catalog is in hand, so the later sync fetches per the index registration),
 * then clear the records, run one sync round, and return the URLs actually sent in that round.
 */
async function runSync(
  route: (url: string, sent: string[]) => Response,
): Promise<{ sent: string[]; metadata: MetadataClientModule }> {
  let phase: 'seed' | 'sync' = 'seed';
  const sent: string[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
    const url = String(input);
    if (phase === 'seed') {
      if (view(url) === 'index') return indexAnnouncing({ [KIND]: SEED_REVISION });
      if (view(url) === 'catalog' && params(url).get('provider') === KIND) return catalogAt(SEED_REVISION, '"catalog-seed"');
      throw new Error(`unexpected metadata request ${url}`);
    }
    sent.push(url);
    return route(url, sent);
  });
  const metadata = await freshClient();
  metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [KIND], hasRelay: false }));
  await metadata.refreshMetadata();
  await settle();
  phase = 'sync';
  trackEvent.mockClear();
  await metadata.refreshMetadata();
  await settle();
  return { sent, metadata };
}

const byId = new Map(FIXTURE.cases.map((entry) => [entry.id, entry]));
function fixtureCase(id: string): RequestShapeCase {
  const entry = byId.get(id);
  if (!entry) throw new Error(`fixture case ${id} missing`);
  return entry;
}

describe('catalog-request-shape.v1', () => {
  beforeEach(async () => {
    trackEvent.mockClear();
    await clearCaches();
  });

  afterEach(async () => {
    if (metadataInstance) {
      await metadataInstance.__settleMetadataBackgroundWorkForTest();
      metadataInstance.__resetMetadataClientForTest();
      metadataInstance = null;
    }
    vi.restoreAllMocks();
    await clearCaches();
  });

  it('CATALOG-REQUEST-SHAPE-catalog_request_carries_index_revision', async () => {
    const entry = fixtureCase('catalog_request_carries_index_revision');
    const announced = entry.indexAnnounces![KIND]!;
    const { sent } = await runSync((url) => (view(url) === 'index'
      ? indexAnnouncing(entry.indexAnnounces!)
      : catalogAt(announced, '"catalog-new"')));
    const catalogs = sent.filter((url) => view(url) === 'catalog');
    expect(catalogs).toHaveLength(1);
    expectShape(catalogs[0], entry.expect.catalogRequest!);
  });

  it('CATALOG-REQUEST-SHAPE-catalog_request_without_announced_revision_omits_rev', async () => {
    const entry = fixtureCase('catalog_request_without_announced_revision_omits_rev');
    const { sent } = await runSync((url) => (view(url) === 'index'
      ? indexAnnouncing(entry.indexAnnounces!)
      : catalogAt(SEED_REVISION, '"catalog-seed"')));
    const catalogs = sent.filter((url) => view(url) === 'catalog' && params(url).get('provider') === KIND);
    // Web ensureCatalog treats a provider whose revision the index does not register as absent and sends no catalog request;
    // no catalog request that is sent may carry rev.
    expect(sent.some((url) => view(url) === 'index')).toBe(true);
    for (const url of catalogs) expectShape(url, entry.expect.catalogRequest!);
    expect(catalogs.every((url) => !params(url).has(REV))).toBe(true);
  });

  it('CATALOG-REQUEST-SHAPE-regular_index_fetch_has_no_cache_bust', async () => {
    const entry = fixtureCase('regular_index_fetch_has_no_cache_bust');
    const { sent } = await runSync((url) => (view(url) === 'index'
      ? indexAnnouncing({ [KIND]: SEED_REVISION })
      : catalogAt(SEED_REVISION, '"catalog-seed"')));
    const indexes = sent.filter((url) => view(url) === 'index');
    expect(indexes.length).toBeGreaterThan(0);
    for (const url of indexes) expectShape(url, entry.expect.indexRequest!);
  });

  it('CATALOG-REQUEST-SHAPE-mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision', async () => {
    const entry = fixtureCase('mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision');
    const staleIndex = entry.indexAnnounces!;
    const freshIndex = entry.indexAfterRefetch!;
    const responseRevision = entry.firstCatalogResponseRevision!;
    let indexCalls = 0;
    const { sent, metadata } = await runSync((url) => {
      if (view(url) === 'index') {
        indexCalls += 1;
        return indexAnnouncing(indexCalls > 1 ? freshIndex : staleIndex);
      }
      // The origin is already at the new revision: both catalog requests return the new content (the first one is judged a mismatch by the old index cached at the edge).
      return catalogAt(responseRevision, '"catalog-new"');
    });
    const indexes = sent.filter((url) => view(url) === 'index');
    const catalogs = sent.filter((url) => view(url) === 'catalog');
    expect(indexes).toHaveLength(2);
    expect(catalogs).toHaveLength(2);
    expectShape(indexes[0], { fresh: null });
    expectShape(catalogs[0], entry.expect.firstCatalogRequest!);
    expect(sent.indexOf(indexes[1])).toBeGreaterThan(sent.indexOf(catalogs[0]));
    expect(shapeOf(indexes[1]).fresh ?? '').not.toBe('');
    expectShape(catalogs[1], entry.expect.secondCatalogRequest!);

    const held = (await (await metadata.__readSplitMetadataCacheForTest()).catalog(KIND))?.value;
    expect(entry.expect.outcome).toBe('accept');
    expect(held).toMatchObject({ revision: responseRevision, etag: '"catalog-new"' });
    const reports = trackEvent.mock.calls.filter(([name]) => name === 'metadata_catalog_rejected');
    expect(entry.expect.report).toBeNull();
    expect(reports).toEqual([]);
  });

  it('every one of the four fixture cases has a matching test', () => {
    expect(FIXTURE.cases.map((entry) => entry.id).sort()).toEqual([
      'catalog_request_carries_index_revision',
      'catalog_request_without_announced_revision_omits_rev',
      'mismatch_refetch_bypasses_edge_then_catalog_uses_new_revision',
      'regular_index_fetch_has_no_cache_bust',
    ]);
  });
});
