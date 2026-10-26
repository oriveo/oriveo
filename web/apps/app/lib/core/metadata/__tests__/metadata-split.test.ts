import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Web client contract tests for the metadata index + per-provider catalog.
 *
 * The corpus only uses the shared fixture generated directly by the server tests (metadata_catalog_contract.v1.json); no synonymous
 * fixture is invented. Both sides of the equivalence assertions go through the production decoding path: the split view is assembled via refreshMetadata, and the lean view goes through
 * the lean path after the index 400 fallback; the final comparison is on the objects production APIs such as resolveCatalogModel actually produce.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { expandMetadataCatalog } from '../metadata-split';

const trackEvent = vi.fn();
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: (...args: unknown[]) => trackEvent(...args),
}));

interface CatalogContractFixture {
  indexResponse: { data: Record<string, unknown> & { providers: Record<string, Record<string, unknown>> } };
  catalogResponses: Record<string, { data: Record<string, unknown> & { catalogRevision: string } }>;
  leanEquivalent: { data: Record<string, unknown> & { providers: Record<string, { models: Record<string, unknown> }> } };
  leanV1DroppedFields: LeanV1DroppedFields;
  negativeCases: {
    unresolvedRef: { catalog: Record<string, unknown>; provider: string };
    revisionMismatch: { indexCatalogRevision: string; provider: string };
  };
}

function loadFixture(): CatalogContractFixture {
  return JSON.parse(readFileSync(
    '../../../shared/model-contracts/metadata_catalog_contract.v1.json',
    'utf8',
  )) as CatalogContractFixture;
}

interface LeanV1DroppedFields { model?: string[]; capabilityControls?: string[] }

/**
 * Golden sample leanV1DroppedFields: fields lean v1 intentionally does not project and that only appear in the catalog.
 * Removed from the models of the expanded result before comparing (field names are always read from the golden sample); an emptied capabilityControls is removed entirely.
 */
function stripLeanV1Dropped<T>(model: T, dropped: LeanV1DroppedFields): T {
  if (!model || typeof model !== 'object') return model;
  const out = { ...(model as Record<string, unknown>) };
  for (const key of dropped.model ?? []) delete out[key];
  const controls = out.capabilityControls;
  if (controls && typeof controls === 'object') {
    const rest = { ...(controls as Record<string, unknown>) };
    for (const key of dropped.capabilityControls ?? []) delete rest[key];
    if (Object.keys(rest).length === 0) delete out.capabilityControls;
    else out.capabilityControls = rest;
  }
  return out as T;
}

/** The catalog omits a canonicalModelId that equals the tree id (corpus $comment): filled in as the tree id before comparing. */
function withDefaultCanonicalModelId<T>(id: string, model: T): T {
  if (!model || typeof model !== 'object' || 'canonicalModelId' in model) return model;
  return { ...(model as Record<string, unknown>), canonicalModelId: id } as T;
}

function stripProviderModels<T>(provider: T, dropped: LeanV1DroppedFields): T {
  const models = (provider as { models?: Record<string, unknown> } | undefined)?.models;
  if (!models) return provider;
  return {
    ...(provider as Record<string, unknown>),
    models: Object.fromEntries(Object.entries(models)
      .map(([id, model]) => [id, withDefaultCanonicalModelId(id, stripLeanV1Dropped(model, dropped))])),
  } as T;
}

/** Real model ids from the corpus: always read from the corpus, never hardcoded (the corpus follows production snapshots). */
function catalogModelIds(fixture: CatalogContractFixture, kind: string): string[] {
  return Object.keys((fixture.catalogResponses[kind].data as { models: Record<string, unknown> }).models);
}

interface RevisionCase { name: string; cached: number | null; incoming: number; expect: 'accept' | 'unchanged' | 'reject' }

const REVISION_CASES = (JSON.parse(readFileSync(
  '../../../shared/model-contracts/metadata_payload.v2.cases.json',
  'utf8',
)) as { revisionCases: RevisionCase[] }).revisionCases;

const SPLIT_HEAD_KEY = 'oriveo:metadata:split:c1:head';
const LEGACY_SPLIT_INDEX_KEY = 'oriveo:metadata:split:c1:index';
const LEGACY_SPLIT_MANIFEST_KEY = 'oriveo:metadata:split:c1:manifest';

async function readRawBlob(key: string) {
  const { readBlob } = await import('../../../infra/storage/blob-cache');
  return readBlob<Record<string, unknown>>(key);
}

/** schema 2 envelope: the index / catalog as is, plus metadataSchema, metadataRevision and generatedAt. */
function schema2<T extends Record<string, unknown>>(data: T, metadataRevision: number) {
  return { ...data, metadataSchema: 2, metadataRevision, generatedAt: '2026-10-19T00:00:00Z' };
}

const CORPUS = loadFixture();
const OPENAI_MODEL = catalogModelIds(CORPUS, 'openAI')[0];
const ANTHROPIC_MODEL = catalogModelIds(CORPUS, 'anthropic')[0];
const MISSING_MODEL = 'model-not-in-any-corpus-catalog';
/** A moment inside the validity window of the corpus evidence: just after its latest observedAt (see the equivalence test). */
const PINNED_NOW = (() => {
  let latest = 0;
  const walk = (node: unknown): void => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (!node || typeof node !== 'object') return;
    for (const [key, value] of Object.entries(node)) {
      if (key === 'observedAt' && typeof value === 'number') latest = Math.max(latest, value);
      else walk(value);
    }
  };
  walk(CORPUS);
  return new Date(latest + 1000);
})();

function json(body: unknown, etag?: string, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...(etag ? { ETag: etag } : {}), ...extraHeaders },
  });
}

type Route = (url: string, init?: RequestInit) => Response | Promise<Response>;

function mockFetch(route: Route) {
  return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => route(String(input), init));
}

function urls(spy: ReturnType<typeof mockFetch>): string[] {
  return spy.mock.calls.map(([input]) => {
    const url = String(input);
    return url.slice(url.indexOf('/api/metadata'));
  });
}

/** A catalog request carries rev=<the catalogRevision the index registers for that provider> (addressed by revision to bypass stale edge copies). */
function catalogURL(kind: string, revision: string): string {
  return `/api/metadata?view=catalog&provider=${kind}&schema=3&rev=${encodeURIComponent(revision)}`;
}

function announcedRevision(fixture: CatalogContractFixture, kind: string): string {
  return String(fixture.indexResponse.data.providers[kind].catalogRevision);
}

function catalogKind(url: string): string | null {
  const match = /view=catalog&provider=([^&]+)/.exec(url);
  return match ? decodeURIComponent(match[1]) : null;
}

/** A healthy server that serves the index / catalogs from the fixture. */
function splitServer(fixture: CatalogContractFixture, overrides: {
  index?: () => Response;
  catalog?: (kind: string) => Response | undefined;
} = {}): Route {
  return (url) => {
    // The index refetch after a mismatch carries &fresh=: judge by the view param.
    if (new URL(url, 'https://metadata.test').searchParams.get('view') === 'index') {
      return overrides.index?.() ?? json(fixture.indexResponse, '"index-r1"');
    }
    const kind = catalogKind(url);
    if (kind) {
      const custom = overrides.catalog?.(kind);
      if (custom) return custom;
      const catalog = fixture.catalogResponses[kind];
      if (!catalog) return new Response(null, { status: 404 });
      return json(catalog, `"catalog-${kind}"`, { 'X-Metadata-Catalog-Revision': catalog.data.catalogRevision });
    }
    throw new Error(`unexpected metadata request ${url}`);
  };
}

async function freshClient() {
  vi.resetModules();
  const metadata = await importMetadataClient();
  metadata.__resetMetadataClientForTest();
  return metadata;
}

async function settle(): Promise<void> {
  // Persistence goes through requestIdleCallback/setTimeout(0); wait for it to land
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

describe('metadata index + per-provider catalog', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    trackEvent.mockClear();
    await settle();
    await clearCaches();
  });

  afterEach(async () => {
    vi.useRealTimers();
    await restoreMetadataInstance();
    await settle();
    await clearCaches();
  });

  it('expands index + catalogs into exactly leanEquivalent (apart from view)', async () => {
    const fixture = loadFixture();
    const split = await import('../metadata-split');
    const index = fixture.indexResponse.data;
    expect(split.isMetadataIndexPayload(index)).toBe(true);
    const catalogs = new Map<string, ReturnType<typeof expandOk>>();
    function expandOk(kind: string) {
      const result = split.expandMetadataCatalog(fixture.catalogResponses[kind].data, {
        provider: kind,
        revision: split.indexCatalogRevision(index as never, kind),
      });
      if (!result.ok) throw new Error(`catalog ${kind} rejected: ${result.reason}`);
      return result.catalog;
    }
    for (const kind of Object.keys(fixture.catalogResponses)) catalogs.set(kind, expandOk(kind));

    const assembled = split.assembleLeanFromSplit(index as never, catalogs);
    const { view: _assembledView, ...assembledRest } = JSON.parse(JSON.stringify(assembled));
    assembledRest.providers = Object.fromEntries(Object.entries(assembledRest.providers as Record<string, unknown>)
      .map(([kind, provider]) => [kind, stripProviderModels(provider, fixture.leanV1DroppedFields)]));
    const { view: _leanView, ...leanRest } = JSON.parse(JSON.stringify(fixture.leanEquivalent.data));
    expect(assembledRest).toEqual(leanRest);
  });

  it('production decoding reaches the same result for every model from the split and lean views', async () => {
    // Evidence in the corpus carries expiresAt; pin the clock inside its validity window so the
    // evidence assertions below never depend on the day the suite runs.
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(PINNED_NOW);
    const fixture = loadFixture();
    const kinds = Object.keys(fixture.leanEquivalent.data.providers);

    async function collect(metadata: Awaited<ReturnType<typeof freshClient>>) {
      const models: Record<string, unknown> = {};
      for (const kind of kinds) {
        for (const modelId of Object.keys(fixture.leanEquivalent.data.providers[kind].models)) {
          const resolved = metadata.resolveCatalogModel(modelId, kind);
          models[`${kind}/${modelId}`] = {
            resolved,
            generation: metadata.resolveGenerationProfileRef(resolved?.profiles.generation),
            pricing: metadata.lookupPricing(modelId, kind),
            capabilities: metadata.lookupCapabilities(modelId, kind),
          };
        }
      }
      const snapshot = metadata.getMetadataSnapshot();
      return {
        models,
        providers: snapshot?.providers,
        capabilityRuntime: metadata.getCapabilityRuntime(),
        whitelist: metadata.getRelayRuntimeConfig().officialProviderWhitelist,
        validation: kinds.map((kind) => metadata.getProviderValidation(kind)),
        defaults: kinds.map((kind) => metadata.getProviderDefaultModelId(kind)),
        listed: kinds.map((kind) => metadata.listProviderModelIds(kind)),
        pending: snapshot?.catalogPendingProviders ?? [],
      };
    }

    // Split view (the same ETag value, so metadataRevision, an ETag-derived field, is comparable)
    const splitFetch = mockFetch(splitServer(fixture, { index: () => json(fixture.indexResponse, '"r1"') }));
    const splitClient = await freshClient();
    splitClient.setMetadataCatalogDemandSource(() => ({ providerKinds: kinds, hasRelay: false }));
    await splitClient.refreshMetadata();
    const fromSplit = await collect(splitClient);
    // The two catalogs are fetched in parallel, in no fixed order
    expect(urls(splitFetch)[0]).toBe('/api/metadata?view=index&schema=3');
    expect(urls(splitFetch).slice(1).sort()).toEqual([
      catalogURL('anthropic', announcedRevision(fixture, 'anthropic')),
      catalogURL('openAI', announcedRevision(fixture, 'openAI')),
    ]);
    splitFetch.mockRestore();
    await settle();
    await clearCaches();

    // Lean view: an old server answers the index with 400 -> fall back to lean
    const leanFetch = mockFetch((url) => (
      url.includes('view=index')
        ? new Response(null, { status: 400 })
        : json(fixture.leanEquivalent, '"r1"')
    ));
    const leanClient = await freshClient();
    await leanClient.refreshMetadata();
    const fromLean = await collect(leanClient);
    expect(urls(leanFetch)).toEqual(['/api/metadata?view=index&schema=3', '/api/metadata?view=lean']);

    // Objects actually produced by production code: the split and lean paths must match field by field
    const dropped = fixture.leanV1DroppedFields;
    const splitComparable = {
      ...fromSplit,
      models: Object.fromEntries(Object.entries(fromSplit.models).map(([key, entry]) => {
        const value = entry as { resolved: unknown };
        return [key, { ...value, resolved: stripLeanV1Dropped(value.resolved, dropped) }];
      })),
      providers: fromSplit.providers && Object.fromEntries(Object.entries(fromSplit.providers)
        .map(([kind, provider]) => [kind, stripProviderModels(provider, dropped)])),
    };
    expect(splitComparable).toEqual(fromLean);
    expect(fromSplit.pending).toEqual([]);
    // The expanded result matches the raw fields of the lean equivalent in the corpus (not just compared with itself)
    const leanModel = fixture.leanEquivalent.data.providers.openAI.models[OPENAI_MODEL] as {
      capabilityControls?: unknown;
      capabilityEvidenceView?: { candidates?: Array<{ key: string }> };
      profiles?: { generation?: { parametersRef?: string } };
    };
    const produced = fromSplit.models[`openAI/${OPENAI_MODEL}`] as {
      resolved: { capabilityControls?: unknown; capabilityEvidenceCandidates?: Array<Record<string, unknown>> } | null;
      generation?: { parameters: Array<{ id: string }> };
    };
    expect(produced.resolved).not.toBeNull();
    expect(stripLeanV1Dropped(produced.resolved, dropped)?.capabilityControls).toEqual(leanModel.capabilityControls);
    const leanKeys = (leanModel.capabilityEvidenceView?.candidates ?? []).map((candidate) => candidate.key);
    if (leanKeys.length > 0) {
      expect(produced.resolved?.capabilityEvidenceCandidates?.length ?? 0).toBeGreaterThan(0);
    }
    for (const candidate of produced.resolved?.capabilityEvidenceCandidates ?? []) {
      expect(leanKeys).toContain(candidate.key);
      expect(candidate).toMatchObject({ providerKind: 'openAI', modelId: OPENAI_MODEL, metadataRevision: '"r1"' });
    }
    const parametersRef = leanModel.profiles?.generation?.parametersRef;
    if (parametersRef) {
      const table = (fixture.leanEquivalent.data.generationParameterTables as Record<string, Array<{ id: string }>>)[parametersRef];
      expect(produced.generation?.parameters.map((parameter) => parameter.id)).toEqual(table.map((entry) => entry.id));
    }
  });

  it('rejects the whole catalog on an unresolved ref, keeps last-good and records a redacted diagnostic', async () => {
    const fixture = loadFixture();
    const { provider, catalog } = fixture.negativeCases.unresolvedRef;
    // last-good comes from an old lean cache (the corpus leanEquivalent as is); the new catalog is the corpus unresolvedRef as is
    const seeder = await freshClient();
    await seeder.__seedMetadataCacheForTest({ data: fixture.leanEquivalent.data as never, etag: '"lean-old"' });
    await settle();
    const fetchSpy = mockFetch(splitServer(fixture, {
      catalog: (kind) => (kind === provider ? json({ code: 0, data: catalog }, '"bad"') : undefined),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.initMetadata();
    const ids = catalogModelIds(fixture, provider);
    const lastGood = ids.map((id) => metadata.resolveCatalogModel(id, provider));
    expect(lastGood.every(Boolean)).toBe(true);

    await metadata.refreshMetadata();

    expect(urls(fetchSpy).filter((url) => url.includes(`provider=${provider}`)).length).toBeGreaterThan(0);
    // The whole payload is rejected: every model is still last-good, instead of dropping only the one with the broken ref
    const after = ids.map((id) => metadata.resolveCatalogModel(id, provider));
    expect(after.every(Boolean)).toBe(true);
    expect(after.map((model) => model?.capabilityControls)).toEqual(lastGood.map((model) => model?.capabilityControls));
    expect(metadata.getProviderCatalogStatus(provider)).toBe('loaded');
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: provider.toLowerCase(),
      reason: 'unresolved_ref',
    });
  });

  it('stays pending on an unresolved ref with no last-good, instead of treating it as an empty catalog', async () => {
    const fixture = loadFixture();
    mockFetch(splitServer(fixture, {
      catalog: (kind) => (kind === 'openAI' ? json({ data: fixture.negativeCases.unresolvedRef.catalog }) : undefined),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));
    await metadata.refreshMetadata();

    expect(metadata.resolveCatalogModel(OPENAI_MODEL, 'openAI')).toBeNull();
    expect(metadata.getProviderCatalogStatus('openAI')).toBe('pending');
    expect(metadata.getMetadataSnapshot()?.catalogPendingProviders).toContain('openAI');
  });

  it('refetches the index once on a revision mismatch and keeps last-good when it still does not match', async () => {
    const fixture = loadFixture();
    const { indexCatalogRevision, provider } = fixture.negativeCases.revisionMismatch;
    let stale = false;
    const fetchSpy = mockFetch(splitServer(fixture, {
      index: () => {
        if (!stale) return json(fixture.indexResponse, '"index-v1"');
        const next = structuredClone(fixture.indexResponse);
        next.data.providers[provider].catalogRevision = indexCatalogRevision;
        return json(next, '"index-stale"');
      },
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.refreshMetadata();
    const lastGood = metadata.resolveCatalogModel(OPENAI_MODEL, provider);
    expect(lastGood).not.toBeNull();

    stale = true;
    fetchSpy.mockClear();
    await metadata.refreshMetadata();

    const sent = urls(fetchSpy);
    expect(sent).toHaveLength(4);
    expect(sent[0]).toBe('/api/metadata?view=index&schema=3');
    expect(sent[1]).toBe(catalogURL(provider, indexCatalogRevision));
    // The one index refetch after a mismatch carries a one-time fresh value to reach the origin
    expect(sent[2]).toMatch(/^\/api\/metadata\?view=index&schema=3&fresh=[^&]+$/);
    expect(sent[3]).toBe(catalogURL(provider, indexCatalogRevision));
    expect(metadata.resolveCatalogModel(OPENAI_MODEL, provider)?.displayName).toBe(lastGood?.displayName);
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: provider.toLowerCase(),
      reason: 'revision_mismatch',
    });
  });

  it('does not read a catalog 404 as an empty catalog: the provider stays pending and enabled models are not manual', async () => {
    const fixture = loadFixture();
    mockFetch(splitServer(fixture, {
      catalog: (kind) => (kind === 'anthropic' ? new Response(null, { status: 404 }) : undefined),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['anthropic'], hasRelay: false }));
    await metadata.refreshMetadata();

    expect(metadata.getProviderCatalogStatus('anthropic')).toBe('pending');
    const { resolveProviderCatalog } = await import('../../providers/catalog-resolver');
    const catalog = resolveProviderCatalog({
      kind: 'anthropic',
      models: [{
        id: ANTHROPIC_MODEL,
        name: ANTHROPIC_MODEL,
        capabilities: ['text'],
        isAvailable: true,
        isDefault: true,
        isRecommended: false,
        priceTier: '',
        reasoningModeAvailable: false,
      }] as never,
      catalogModels: [],
    }, metadata.getMetadataSnapshot() as never);
    expect(catalog.catalogPending).toBe(true);
    expect(catalog.enabledModels.map((model) => model.isManual)).toEqual([false]);
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: 'anthropic',
      reason: 'not_found',
    });
  });

  it('makes no catalog request when revisions match the index, and an index 304 only updates timestamps', async () => {
    const fixture = loadFixture();
    let indexNotModified = false;
    const fetchSpy = mockFetch(splitServer(fixture, {
      index: () => (indexNotModified
        ? new Response(null, { status: 304 })
        : json(fixture.indexResponse, '"index-r1"')),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI', 'anthropic'], hasRelay: false }));
    await metadata.refreshMetadata();

    // The same index (200): both revisions unchanged -> only one index request
    fetchSpy.mockClear();
    await metadata.refreshMetadata();
    expect(urls(fetchSpy)).toEqual(['/api/metadata?view=index&schema=3']);
    await settle();
    const before = await metadata.__readSplitMetadataCacheForTest();
    expect(before.index?.etag).toBe('"index-r1"');
    const catalogBefore = await before.catalog('openAI');
    expect(catalogBefore?.value.revision).toBe(fixture.catalogResponses.openAI.data.catalogRevision);

    // Index 304: carries the last validator, the body is not rewritten, only the manifest timestamp advances
    indexNotModified = true;
    fetchSpy.mockClear();
    await new Promise((resolve) => setTimeout(resolve, 5));
    const revisionBefore = metadata.getCachedMetadataVersion();
    await metadata.refreshMetadata();
    await settle();
    expect(urls(fetchSpy)).toEqual(['/api/metadata?view=index&schema=3']);
    expect(fetchSpy.mock.calls[0]?.[1]).toMatchObject({
      headers: expect.objectContaining({ 'If-None-Match': '"index-r1"' }),
    });
    const after = await metadata.__readSplitMetadataCacheForTest();
    expect(after.indexTimestamp).toBe(before.indexTimestamp);
    expect((await after.catalog('openAI'))?.timestamp).toBe(catalogBefore?.timestamp);
    expect(after.manifest?.indexCheckedAt).toBeGreaterThan(before.manifest?.indexCheckedAt ?? 0);
    expect(metadata.getCachedMetadataVersion()).toBe(revisionBefore);
    expect(metadata.isMetadataSnapshotConfirmed('openAI')).toBe(true);
  });

  it('restores from the split cache on cold start without requesting catalogs whose revision is unchanged', async () => {
    const fixture = loadFixture();
    const first = mockFetch(splitServer(fixture));
    let metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI', 'anthropic'], hasRelay: false }));
    await metadata.refreshMetadata();
    await settle();
    first.mockRestore();
    // The index + manifest only land on the merged new key; the two old keys are no longer written
    expect((await readRawBlob(SPLIT_HEAD_KEY))?.value).toMatchObject({
      index: { etag: '"index-r1"' },
      manifest: { indexCheckedAt: expect.any(Number) },
    });
    expect(await readRawBlob(LEGACY_SPLIT_INDEX_KEY)).toBeNull();
    expect(await readRawBlob(LEGACY_SPLIT_MANIFEST_KEY)).toBeNull();

    // New session: the cache is fresh -> usable at once, and the background only conditionally requests the index
    const second = mockFetch(splitServer(fixture, { index: () => new Response(null, { status: 304 }) }));
    metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI', 'anthropic'], hasRelay: false }));
    await metadata.initMetadata();
    expect(metadata.resolveCatalogModel(ANTHROPIC_MODEL, 'anthropic')?.displayName).toBeDefined();
    await vi.waitFor(() => expect(metadata.isMetadataSnapshotConfirmed('anthropic')).toBe(true));
    expect(urls(second)).toEqual(['/api/metadata?view=index&schema=3']);
  });

  it('migrates an older lean cache: last-good first, then index + catalogs on the next refresh, retiring the old cache', async () => {
    const fixture = loadFixture();
    const metadataForSeed = await freshClient();
    await metadataForSeed.__seedMetadataCacheForTest({ data: fixture.leanEquivalent.data as never, etag: '"lean-old"' });

    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const fetchSpy = mockFetch(async (url) => {
      await gate;
      return splitServer(fixture)(url);
    });
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));
    await metadata.initMetadata();

    // Before migration: the old lean snapshot is directly usable (all providers present, none pending)
    expect(metadata.resolveCatalogModel(ANTHROPIC_MODEL, 'anthropic')).not.toBeNull();
    expect(metadata.getProviderCatalogStatus('anthropic')).toBe('loaded');

    release();
    await vi.waitFor(() => expect(metadata.getProviderCatalogStatus('openAI')).toBe('loaded'));
    await vi.waitFor(() => expect(urls(fetchSpy)).toContain(catalogURL('openAI', announcedRevision(loadFixture(), 'openAI'))));
    await settle();
    // The index request does not carry the lean validator (validators do not cross views)
    expect(fetchSpy.mock.calls[0]?.[1]).not.toMatchObject({
      headers: expect.objectContaining({ 'If-None-Match': expect.anything() }),
    });
    expect(metadata.resolveCatalogModel(OPENAI_MODEL, 'openAI')).not.toBeNull();
    // After migration only the needed catalogs are kept; anthropic is not in the needed set -> pending (not absent)
    expect(metadata.getProviderCatalogStatus('anthropic')).toBe('pending');
    expect(await metadata.__readMetadataCacheForTest()).toBeNull();
    // After migration the index lands on the merged new key
    expect((await readRawBlob(SPLIT_HEAD_KEY))?.value).toMatchObject({ index: { etag: '"index-r1"' } });
    expect(await readRawBlob(LEGACY_SPLIT_INDEX_KEY)).toBeNull();
  });

  it('discards an unreadable (malformed) cache and fetches cold without blocking startup', async () => {
    const fixture = loadFixture();
    const { writeBlob } = await import('../../../infra/storage/blob-cache');
    await writeBlob(SPLIT_HEAD_KEY, { index: { data: 'garbage', etag: 42 }, manifest: null, indexStoredAt: 'x' });
    await writeBlob(LEGACY_SPLIT_INDEX_KEY, { data: 'garbage', etag: 42 });
    await writeBlob('oriveo:metadata:c1', { data: null, etag: null });
    const fetchSpy = mockFetch(splitServer(fixture));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));

    await expect(metadata.initMetadata()).resolves.toBeUndefined();
    expect(urls(fetchSpy)[0]).toBe('/api/metadata?view=index&schema=3');
    expect(metadata.resolveCatalogModel(OPENAI_MODEL, 'openAI')).not.toBeNull();
  });

  it('allowlistVersion 1 catalog cache: used as last-good while offline, refetched without the old ETag once online', async () => {
    const fixture = loadFixture();
    const first = mockFetch(splitServer(fixture));
    const seeded = await freshClient();
    seeded.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));
    await seeded.refreshMetadata();
    await settle();
    first.mockRestore();
    const catalogKey = 'oriveo:metadata:split:c1:catalog:openAI';
    const stored = await readRawBlob(catalogKey);
    expect(stored?.value).toMatchObject({ etag: '"catalog-openAI"' });
    const { writeBlob } = await import('../../../infra/storage/blob-cache');
    await writeBlob(catalogKey, { ...stored!.value, allowlistVersion: 1 });

    // Offline cold start: the old-version blob is still last-good and models resolve, but it is not confirmed this session
    const offline = mockFetch(() => {
      throw new TypeError('network down');
    });
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));
    await metadata.initMetadata();
    await settle();
    expect(metadata.resolveCatalogModel(OPENAI_MODEL, 'openAI')).not.toBeNull();
    expect(metadata.isMetadataSnapshotConfirmed('openAI')).toBe(false);
    offline.mockRestore();

    // Online: this provider is refetched unconditionally (without the old ETag)
    const online = mockFetch(splitServer(fixture));
    await metadata.refreshMetadata();
    const catalogCall = online.mock.calls.find(([input]) => catalogKind(String(input)) === 'openAI');
    expect(catalogCall).toBeDefined();
    expect((catalogCall?.[1]?.headers as Record<string, string> | undefined)?.['If-None-Match']).toBeUndefined();
    expect(metadata.isMetadataSnapshotConfirmed('openAI')).toBe(true);
  });

  it('index / manifest stored separately before the merge: on cold start they are re-stored under the new key and the old keys are deleted', async () => {
    const fixture = loadFixture();
    const { writeBlob } = await import('../../../infra/storage/blob-cache');
    await writeBlob(LEGACY_SPLIT_INDEX_KEY, { data: fixture.indexResponse.data, etag: '"index-r1"' });
    await writeBlob(LEGACY_SPLIT_MANIFEST_KEY, { indexCheckedAt: Date.now(), catalogCheckedAt: {} });
    const fetchSpy = mockFetch(splitServer(fixture, { index: () => new Response(null, { status: 304 }) }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [], hasRelay: false }));

    await metadata.initMetadata();
    await vi.waitFor(() => expect(urls(fetchSpy)).toEqual(['/api/metadata?view=index&schema=3']));
    // The index carried over is last-good: on a 304 it sends its validator
    expect(fetchSpy.mock.calls[0]?.[1]).toMatchObject({
      headers: expect.objectContaining({ 'If-None-Match': '"index-r1"' }),
    });
    await settle();
    expect((await readRawBlob(SPLIT_HEAD_KEY))?.value).toMatchObject({
      index: { data: fixture.indexResponse.data, etag: '"index-r1"' },
    });
    expect(await readRawBlob(LEGACY_SPLIT_INDEX_KEY)).toBeNull();
    expect(await readRawBlob(LEGACY_SPLIT_MANIFEST_KEY)).toBeNull();
  });

  it('index publication does a single writeBlob: the index and manifest are stored together as one entry', async () => {
    const fixture = loadFixture();
    const writes: string[] = [];
    vi.doMock('../../../infra/storage/blob-cache', async (importOriginal) => {
      const actual = await importOriginal<typeof import('../../../infra/storage/blob-cache')>();
      return {
        ...actual,
        writeBlob: async <T,>(key: string, value: T) => {
          writes.push(key);
          return actual.writeBlob(key, value);
        },
      };
    });
    try {
      mockFetch(splitServer(fixture));
      const metadata = await freshClient();
      metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [], hasRelay: false }));
      await metadata.refreshMetadata();
      await settle();

      expect(writes.filter((key) => key.startsWith('oriveo:metadata:split:'))).toEqual([
        metadata.METADATA_SPLIT_HEAD_KEY_FOR_TESTING,
      ]);
      const stored = await metadata.__readSplitMetadataCacheForTest();
      expect(stored.index?.etag).toBe('"index-r1"');
      expect(stored.manifest?.indexCheckedAt).toBe(stored.indexTimestamp);
    } finally {
      vi.doUnmock('../../../infra/storage/blob-cache');
    }
  });

  it('requests schema=3 (the production value): index / catalog URLs append &schema=3, the lean fallback does not, and no schema request header is sent', async () => {
    const fixture = loadFixture();
    const fetchSpy = mockFetch(splitServer(fixture));
    let metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));
    await metadata.refreshMetadata();
    expect(urls(fetchSpy)).toEqual([
      '/api/metadata?view=index&schema=3',
      catalogURL('openAI', announcedRevision(fixture, 'openAI')),
    ]);
    for (const [, init] of fetchSpy.mock.calls) {
      expect(Object.keys((init?.headers ?? {}) as Record<string, string>)
        .map((name) => name.toLowerCase())).not.toContain('x-oriveo-metadata-schema');
    }
    await settle();
    fetchSpy.mockRestore();
    await clearCaches();

    const legacy = mockFetch((url) => (url.includes('view=index')
      ? new Response(null, { status: 400 })
      : json(fixture.leanEquivalent, '"lean-1"')));
    metadata = await freshClient();
    await metadata.refreshMetadata();
    expect(urls(legacy)).toEqual(['/api/metadata?view=index&schema=3', '/api/metadata?view=lean']);
  });

  it.each(REVISION_CASES)('index revision $name: cached $cached, received $incoming -> $expect', async (revisionCase) => {
    const fixture = loadFixture();
    const indexBody = (revision: number | null) => (revision === null
      ? fixture.indexResponse
      : { data: schema2(fixture.indexResponse.data, revision) });
    let body = indexBody(revisionCase.cached);
    let etag = '"index-held"';
    const fetchSpy = mockFetch(splitServer(fixture, { index: () => json(body, etag) }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [], hasRelay: false }));
    await metadata.refreshMetadata();
    await settle();
    const held = await metadata.__readSplitMetadataCacheForTest();
    expect(held.index?.etag).toBe('"index-held"');

    body = indexBody(revisionCase.incoming);
    etag = '"index-incoming"';
    trackEvent.mockClear();
    await metadata.refreshMetadata();
    await settle();
    const after = await metadata.__readSplitMetadataCacheForTest();
    const storedRevision = (after.index?.data as { metadataRevision?: number } | undefined)?.metadataRevision;
    const regressed = trackEvent.mock.calls.filter(([, props]) =>
      (props as { reason?: string }).reason === 'revision_regressed');

    if (revisionCase.expect === 'accept') {
      expect(after.index?.etag).toBe('"index-incoming"');
      expect(storedRevision).toBe(revisionCase.incoming);
      expect(regressed).toEqual([]);
    } else if (revisionCase.expect === 'unchanged') {
      // Equal counts as 304: the body is not rewritten, but the new ETag lands together with the index, so the next conditional request carries the new value
      expect(after.index?.etag).toBe('"index-incoming"');
      expect(storedRevision).toBe(revisionCase.cached);
      expect(after.indexTimestamp).toBe(held.indexTimestamp);
      expect(regressed).toEqual([]);
      fetchSpy.mockClear();
      await metadata.refreshMetadata();
      expect(fetchSpy.mock.calls[0]?.[1]).toMatchObject({
        headers: expect.objectContaining({ 'If-None-Match': '"index-incoming"' }),
      });
    } else {
      // A regression is rejected: the copy in hand is kept as is and the body is not rewritten
      expect(after.index?.etag).toBe('"index-held"');
      expect(storedRevision).toBe(revisionCase.cached);
      expect(after.indexTimestamp).toBe(held.indexTimestamp);
      expect(regressed).toEqual(revisionCase.expect === 'reject'
        ? [['metadata_catalog_rejected', { provider_kind: 'index', reason: 'revision_regressed' }]]
        : []);
    }
  });

  it('catalog revision regression: rejected against the value recorded in that provider blob, last-good kept and revision_regressed recorded', async () => {
    const fixture = loadFixture();
    const kind = 'openAI';
    const catalog = fixture.catalogResponses[kind];
    const nextCatalogRevision = `sha256:${'f'.repeat(64)}`;
    let regressedServer = false;
    const indexData = fixture.indexResponse.data;
    mockFetch(splitServer(fixture, {
      index: () => json(regressedServer
        ? { data: { ...indexData, providers: { ...indexData.providers, [kind]: { ...indexData.providers[kind], catalogRevision: nextCatalogRevision } } } }
        : fixture.indexResponse, regressedServer ? '"index-r2"' : '"index-r1"'),
      catalog: (requested) => (requested === kind
        ? json(regressedServer
          ? { data: schema2({ ...catalog.data, catalogRevision: nextCatalogRevision }, 4) }
          : { data: schema2(catalog.data, 5) }, regressedServer ? '"catalog-old"' : '"catalog-new"')
        : undefined),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [kind], hasRelay: false }));
    await metadata.refreshMetadata();
    await settle();
    const held = await (await metadata.__readSplitMetadataCacheForTest()).catalog(kind);
    expect(held?.value).toMatchObject({ metadataRevision: 5, etag: '"catalog-new"' });

    regressedServer = true;
    trackEvent.mockClear();
    await metadata.refreshMetadata();
    await settle();
    const after = await (await metadata.__readSplitMetadataCacheForTest()).catalog(kind);
    expect(after?.value).toMatchObject({ metadataRevision: 5, etag: '"catalog-new"', revision: catalog.data.catalogRevision });
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', { provider_kind: 'openai', reason: 'revision_regressed' });
    expect(metadata.resolveCatalogModel(OPENAI_MODEL, kind)).not.toBeNull();
  });

  it('pending != miss: an unloaded provider returns pending and only that one is fetched; only a loaded catalog that really lacks the model is a miss', async () => {
    const fixture = loadFixture();
    const fetchSpy = mockFetch(splitServer(fixture));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['openAI'], hasRelay: false }));
    await metadata.refreshMetadata();
    fetchSpy.mockClear();

    const routing = await import('../../library/routing');
    const anthropicProvider = { id: 'p-anthropic', kind: 'anthropic', models: [] } as never;
    const claude = { id: ANTHROPIC_MODEL, transport: 'anthropic_messages' } as never;

    // Not loaded: pending (not "absent from the catalog"), routing cannot decide, and this provider is not confirmed this session
    expect(metadata.getMetadataSnapshot()?.catalogPendingProviders).toEqual(['anthropic']);
    expect(metadata.isMetadataSnapshotConfirmed('anthropic')).toBe(false);
    expect(routing.metadataCanDecideRoute(anthropicProvider, claude)).toBe(false);
    expect(metadata.resolveCatalogModel(ANTHROPIC_MODEL, 'anthropic')).toBeNull();
    expect(metadata.getProviderCatalogStatus('anthropic')).toBe('pending');

    await vi.waitFor(() => expect(metadata.getProviderCatalogStatus('anthropic')).toBe('loaded'));
    // Only that provider's catalog was triggered: no index refetch and no full refresh
    expect(urls(fetchSpy)).toEqual([catalogURL('anthropic', announcedRevision(loadFixture(), 'anthropic'))]);
    expect(metadata.resolveCatalogModel(ANTHROPIC_MODEL, 'anthropic')).not.toBeNull();
    expect(metadata.isMetadataSnapshotConfirmed('anthropic')).toBe(true);

    // Loaded and really missing -> miss; a provider absent from the index -> absent (triggers no request)
    fetchSpy.mockClear();
    expect(metadata.resolveCatalogModel(MISSING_MODEL, 'openAI')).toBeNull();
    expect(metadata.getProviderCatalogStatus('openAI')).toBe('loaded');
    expect(metadata.getProviderCatalogStatus('moonshot')).toBe('absent');
    // Provider-level fields can be read from the index even before the catalog loads
    expect(metadata.getProviderValidation('openAI')).toEqual(
      fixture.indexResponse.data.providers.openAI.validation,
    );
    await settle();
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('includes the official-provider whitelist in the needed catalogs when a relay exists', async () => {
    const fixture = loadFixture();
    const fetchSpy = mockFetch(splitServer(fixture));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [], hasRelay: true }));
    await metadata.refreshMetadata();

    expect(urls(fetchSpy).filter((url) => catalogKind(url)).map(catalogKind).sort()).toEqual(['anthropic', 'openAI']);
    const match = metadata.resolveCatalogModelAcrossProvidersWithProvider(ANTHROPIC_MODEL);
    expect(match?.matchedProviderKind).toBe('anthropic');
  });

  it('fetches an explicitly named provider (one being added) even though it is not configured yet', async () => {
    const fixture = loadFixture();
    const fetchSpy = mockFetch(splitServer(fixture));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [], hasRelay: false }));
    await metadata.refreshMetadata({ providerKinds: ['anthropic'] });

    expect(urls(fetchSpy)).toEqual([
      '/api/metadata?view=index&schema=3',
      catalogURL('anthropic', announcedRevision(fixture, 'anthropic')),
    ]);
    const { buildOfficialEnabledModels } = await import('../../providers/official-model-sync');
    const build = buildOfficialEnabledModels('anthropic', metadata.getMetadataSnapshot() as never, {});
    expect(build.models.map((model) => model.id)).toEqual([
      fixture.indexResponse.data.providers.anthropic.defaultModelId ?? ANTHROPIC_MODEL,
    ]);
    const pending = buildOfficialEnabledModels('openAI', metadata.getMetadataSnapshot() as never, {});
    expect(pending).toMatchObject({ models: [], catalogPending: true });
  });
});

describe('expandMetadataCatalog: per-entry metadata schema 2 validation', () => {
  const schema2 = { metadataSchema: 2, metadataRevision: 3, generatedAt: '2026-10-19T00:00:00Z' };

  it('schema 2: a bad model is dropped on its own and recorded, good models expand as usual', () => {
    const fixture = loadFixture();
    const [provider, response] = Object.entries(fixture.catalogResponses)[0];
    const models = response.data.models as Record<string, unknown>;
    const result = expandMetadataCatalog(
      { ...response.data, ...schema2, models: { ...models, 'm-bad': { displayName: 'Bad', capabilityControls: { vision_input: { state: 'maybe' } } } } },
      { provider, revision: response.data.catalogRevision },
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(Object.keys(result.catalog.models).sort()).toEqual(Object.keys(models).sort());
    expect(result.catalog.dropped).toEqual([
      { provider, modelId: 'm-bad', instancePath: '/capabilityControls/vision_input/state', keyword: 'enum' },
    ]);
  });

  it('schema 2 bad envelope (missing metadataRevision): the whole payload is rejected as malformed', () => {
    const fixture = loadFixture();
    const [provider, response] = Object.entries(fixture.catalogResponses)[0];
    const { metadataRevision: _omitted, ...envelope } = { ...response.data, ...schema2 };
    expect(expandMetadataCatalog(envelope, { provider })).toEqual({ ok: false, reason: 'malformed' });
  });

  it('a schema 1 catalog without metadataSchema skips v2 validation and keeps bad models as before', () => {
    const fixture = loadFixture();
    const [provider, response] = Object.entries(fixture.catalogResponses)[0];
    const models = response.data.models as Record<string, unknown>;
    const result = expandMetadataCatalog(
      { ...response.data, models: { ...models, 'm-nameless': { contextLength: 1000 } } },
      { provider },
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.catalog.models['m-nameless']).toBeDefined();
    expect(result.catalog.dropped).toEqual([]);
  });
});

interface Schema3ExpansionCase {
  key: string;
  compact: Record<string, unknown>;
  modelDefaults?: Record<string, unknown>;
  tables: Record<string, unknown>;
  expanded: Record<string, unknown>;
}

type WireResponse = { data: Record<string, unknown> & { catalogRevision: string } };
type WireIndex = { data: Record<string, unknown> & { providers: Record<string, Record<string, unknown>> } };

/** Shared corpus schema3 section (the single source of truth generated by the server). */
interface Schema3Corpus {
  indexResponse: WireIndex;
  catalogResponses: Record<string, WireResponse>;
  schema2IndexResponse: WireIndex;
  schema2CatalogResponses: Record<string, WireResponse>;
  expansionCases: Schema3ExpansionCase[];
  negativeCases: Record<string, { catalog: Record<string, unknown>; provider: string; expect: string }>;
}

const SCHEMA3 = (JSON.parse(readFileSync(
  '../../../shared/model-contracts/metadata_catalog_contract.v1.json',
  'utf8',
)) as { schema3: Schema3Corpus }).schema3;

/** Wraps one version of the schema3 section (3 or its schema 2 counterpart) into the corpus shape splitServer understands. */
function schema3Server(version: 'compact' | 'schema2'): CatalogContractFixture {
  return {
    indexResponse: version === 'compact' ? SCHEMA3.indexResponse : SCHEMA3.schema2IndexResponse,
    catalogResponses: version === 'compact' ? SCHEMA3.catalogResponses : SCHEMA3.schema2CatalogResponses,
  } as unknown as CatalogContractFixture;
}

describe('metadata schema 3 compact catalog', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    trackEvent.mockClear();
    await settle();
    await clearCaches();
  });

  afterEach(async () => {
    await restoreMetadataInstance();
    await settle();
    await clearCaches();
  });

  it.each(SCHEMA3.expansionCases.map((entry) => [entry.key, entry] as const))(
    'expansionCases %s: compact + modelDefaults + tables expand == expanded',
    async (_key, entry) => {
      const { expandCompactCatalogModel } = await import('../metadata-split');
      expect(expandCompactCatalogModel(entry.key, entry.compact, entry.modelDefaults, entry.tables)).toEqual(entry.expanded);
    },
  );

  it('every schema 3 catalog, once expanded by production code, equals the same provider schema 2 catalog model by model, with tombstones put back on the provider', async () => {
    const split = await import('../metadata-split');
    const index3 = SCHEMA3.indexResponse.data as never;
    const index2 = SCHEMA3.schema2IndexResponse.data as never;
    const kinds = Object.keys(SCHEMA3.catalogResponses);
    expect(kinds.sort()).toEqual(Object.keys(SCHEMA3.schema2CatalogResponses).sort());
    const compactCatalogs = new Map<string, ExpandedCatalog>();
    const schema2Catalogs = new Map<string, ExpandedCatalog>();
    type ExpandedCatalog = Extract<ReturnType<typeof split.expandMetadataCatalog>, { ok: true }>['catalog'];
    for (const kind of kinds) {
      const compact = split.expandMetadataCatalog(SCHEMA3.catalogResponses[kind].data, {
        provider: kind,
        revision: split.indexCatalogRevision(index3, kind),
      });
      const schema2 = split.expandMetadataCatalog(SCHEMA3.schema2CatalogResponses[kind].data, {
        provider: kind,
        revision: split.indexCatalogRevision(index2, kind),
      });
      if (!compact.ok || !schema2.ok) throw new Error(`catalog ${kind} rejected`);
      expect(Object.keys(compact.catalog.models).length).toBeGreaterThan(0);
      expect(compact.catalog.dropped).toEqual([]);
      expect(compact.catalog.models).toEqual(schema2.catalog.models);
      expect(compact.catalog.resolveMap).toEqual(schema2.catalog.resolveMap);
      expect(compact.catalog.generationParameters).toEqual(schema2.catalog.generationParameters);
      compactCatalogs.set(kind, compact.catalog);
      schema2Catalogs.set(kind, schema2.catalog);
    }

    const assembled3 = split.assembleLeanFromSplit(index3, compactCatalogs);
    const assembled2 = split.assembleLeanFromSplit(index2, schema2Catalogs);
    // A schema 3 catalog without tombstones = the provider has none (snapshot []); a schema 2 index without them means the same. Default to [] before comparing.
    const withRetired = (providers: Record<string, Record<string, unknown>>) => Object.fromEntries(
      Object.entries(providers).map(([kind, provider]) => [kind, { ...provider, retiredModels: provider.retiredModels ?? [] }]),
    );
    for (const kind of kinds) {
      expect(assembled3.providers[kind].retiredModels)
        .toEqual(SCHEMA3.schema2IndexResponse.data.providers[kind].retiredModels ?? []);
    }
    // At least one provider in the corpus really carries tombstones, so this is not an empty comparison where both sides default
    expect(kinds.some((kind) => ((assembled3.providers[kind].retiredModels as unknown[]) ?? []).length > 0)).toBe(true);
    expect(withRetired(assembled3.providers)).toEqual(withRetired(assembled2.providers));
  });

  it.each(Object.keys(SCHEMA3.negativeCases))('negativeCases %s: the whole catalog is rejected', async (name) => {
    const { expandMetadataCatalog } = await import('../metadata-split');
    const { catalog, provider, expect: expected } = SCHEMA3.negativeCases[name];
    expect(expected).toBe('reject_whole_catalog_keep_last_good');
    expect(expandMetadataCatalog(catalog, { provider })).toEqual({ ok: false, reason: 'unresolved_ref' });
  });

  it('production decoding: schema 3 and schema 2 servers reach the same conclusion for every model and tombstone', async () => {
    const kinds = Object.keys(SCHEMA3.catalogResponses);
    async function collect(version: 'compact' | 'schema2') {
      const fetchSpy = mockFetch(splitServer(schema3Server(version)));
      const metadata = await freshClient();
      metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: kinds, hasRelay: false }));
      await metadata.refreshMetadata();
      const models: Record<string, unknown> = {};
      for (const kind of kinds) {
        for (const modelId of Object.keys(SCHEMA3.schema2CatalogResponses[kind].data.models as Record<string, unknown>)) {
          const resolved = metadata.resolveCatalogModel(modelId, kind);
          expect(resolved).not.toBeNull();
          models[`${kind}/${modelId}`] = {
            resolved,
            generation: metadata.resolveGenerationProfileRef(resolved?.profiles.generation),
            pricing: metadata.lookupPricing(modelId, kind),
            capabilities: metadata.lookupCapabilities(modelId, kind),
          };
        }
      }
      const result = {
        models,
        retired: kinds.map((kind) => metadata.getProviderRetiredModels(kind)),
        listed: kinds.map((kind) => metadata.listProviderModelIds(kind)),
        pending: metadata.getMetadataSnapshot()?.catalogPendingProviders ?? [],
        requested: urls(fetchSpy),
      };
      fetchSpy.mockRestore();
      await restoreMetadataInstance();
      await settle();
      await clearCaches();
      return result;
    }
    const compact = await collect('compact');
    const schema2 = await collect('schema2');
    expect(compact.requested[0]).toBe('/api/metadata?view=index&schema=3');
    expect(compact.pending).toEqual([]);
    expect(compact.retired).toEqual(kinds.map((kind) => (
      SCHEMA3.schema2IndexResponse.data.providers[kind].retiredModels ?? []
    )));
    const { requested: _compactRequested, ...compactRest } = compact;
    const { requested: _schema2Requested, ...schema2Rest } = schema2;
    expect(compactRest).toEqual(schema2Rest);
  });

  it('upgrade: cached schema 2 index + catalog, the server answers schema 3 with the same metadataRevision, and a newly needed provider still loads and converges', async () => {
    const [cachedKind, newKind] = ['anthropic', 'openAI'];
    // Both corpus versions share one revision: exactly the "equal revision counts as unchanged" case to guard against
    expect(SCHEMA3.indexResponse.data.metadataRevision).toBe(SCHEMA3.schema2IndexResponse.data.metadataRevision);
    const oldServer = mockFetch(splitServer(schema3Server('schema2')));
    const seeder = await freshClient();
    seeder.setMetadataCatalogDemandSource(() => ({ providerKinds: [cachedKind], hasRelay: false }));
    await seeder.refreshMetadata();
    expect(seeder.getProviderCatalogStatus(cachedKind)).toBe('loaded');
    await settle();
    oldServer.mockRestore();

    // New session (new client): first start from the cached schema 2 index + that provider catalog, then ask the server for schema 3
    const newServer = mockFetch(splitServer(schema3Server('compact')));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [cachedKind, newKind], hasRelay: false }));
    await metadata.initMetadata();
    expect(metadata.resolveCatalogModel(ANTHROPIC_MODEL, cachedKind)).not.toBeNull();
    await metadata.refreshMetadata();
    await settle();
    for (const kind of [cachedKind, newKind]) {
      expect(metadata.getProviderCatalogStatus(kind)).toBe('loaded');
      for (const modelId of Object.keys(SCHEMA3.catalogResponses[kind].data.models as Record<string, unknown>)) {
        expect(metadata.resolveCatalogModel(modelId, kind)).not.toBeNull();
      }
    }
    expect(metadata.getProviderRetiredModels(newKind)).toEqual(SCHEMA3.schema2IndexResponse.data.providers[newKind].retiredModels);
    // Converged on schema 3: another refresh fetches no catalog
    newServer.mockClear();
    await metadata.refreshMetadata();
    expect(urls(newServer).filter((url) => url.includes('view=catalog'))).toEqual([]);
  });

  it.each(Object.keys(SCHEMA3.negativeCases))('negativeCases %s cold start without last-good: stays pending and records unresolved_ref', async (name) => {
    const { catalog, provider } = SCHEMA3.negativeCases[name];
    mockFetch(splitServer(schema3Server('compact'), {
      catalog: (kind) => (kind === provider ? json({ code: 0, data: catalog }, '"bad"') : undefined),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.refreshMetadata();
    expect(metadata.getProviderCatalogStatus(provider)).toBe('pending');
    expect(metadata.getProviderRetiredModels(provider)).toEqual([]);
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: provider.toLowerCase(),
      reason: 'unresolved_ref',
    });
  });

  it.each(Object.keys(SCHEMA3.negativeCases))('negativeCases %s with last-good: the whole payload is rejected and last-good is unchanged', async (name) => {
    const { catalog, provider } = SCHEMA3.negativeCases[name];
    // last-good comes from an old lean cache (the main corpus leanEquivalent as is)
    const seeder = await freshClient();
    await seeder.__seedMetadataCacheForTest({ data: CORPUS.leanEquivalent.data as never, etag: '"lean-old"' });
    await settle();
    const fetchSpy = mockFetch(splitServer(schema3Server('compact'), {
      catalog: (kind) => (kind === provider ? json({ code: 0, data: catalog }, '"bad"') : undefined),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.initMetadata();
    const ids = Object.keys(CORPUS.leanEquivalent.data.providers[provider].models);
    // Evidence candidates carry the ETag of the current snapshot (it changes with the index generation); compare the catalog content itself
    const view = (id: string) => {
      const model = metadata.resolveCatalogModel(id, provider);
      return model && {
        displayName: model.displayName,
        canonicalModelId: model.canonicalModelId,
        capabilityControls: model.capabilityControls,
        pricing: metadata.lookupPricing(id, provider),
        capabilities: metadata.lookupCapabilities(id, provider),
      };
    };
    const lastGood = ids.map(view);
    expect(lastGood.every(Boolean)).toBe(true);

    await metadata.refreshMetadata();

    expect(urls(fetchSpy).some((url) => url.includes(`provider=${provider}`))).toBe(true);
    expect(ids.map(view)).toEqual(lastGood);
    expect(metadata.getProviderCatalogStatus(provider)).toBe('loaded');
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: provider.toLowerCase(),
      reason: 'unresolved_ref',
    });
  });

  it('the tombstone snapshot takes the index from the moment the request started: if the index becomes schema 3 while a catalog is in flight, the snapshot is still the old index tombstones', async () => {
    const kind = 'openAI';
    const original = SCHEMA3.schema2IndexResponse.data.providers[kind].retiredModels;
    expect(Array.isArray(original) && original.length > 0).toBe(true);
    let upgraded = false;
    let releaseOpenAI: () => void = () => {};
    const openAIGate = new Promise<void>((resolve) => { releaseOpenAI = resolve; });
    let openAIRequests = 0;
    const fetchSpy = mockFetch(async (url) => {
      if (new URL(url, 'https://metadata.test').searchParams.get('view') === 'index') {
        return json(upgraded ? SCHEMA3.indexResponse : SCHEMA3.schema2IndexResponse, upgraded ? '"i3"' : '"i2"');
      }
      const requested = catalogKind(url);
      if (requested === kind) {
        openAIRequests += 1;
        if (openAIRequests > 1) return new Response(null, { status: 500 });
        // The first openAI catalog request (issued from the schema 2 index) hangs until the index has become schema 3
        await openAIGate;
        return json(SCHEMA3.schema2CatalogResponses[kind], '"c2-openAI"');
      }
      if (requested && upgraded) {
        // A request only issued after the schema 3 index is adopted: release the in-flight openAI catalog at this point
        releaseOpenAI();
        return new Response(null, { status: 500 });
      }
      return requested ? json(SCHEMA3.schema2CatalogResponses[requested], `"c2-${requested}"`) : new Response(null, { status: 404 });
    });
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: ['anthropic'], hasRelay: false }));
    await metadata.refreshMetadata();

    // Load openAI on demand: the request goes out from the schema 2 index and is in flight
    expect(metadata.resolveCatalogModel('any-model', kind)).toBeNull();
    await vi.waitFor(() => expect(openAIRequests).toBe(1));
    upgraded = true;
    await metadata.refreshMetadata();
    await vi.waitFor(() => expect(metadata.getProviderCatalogStatus(kind)).toBe('loaded'));
    expect(urls(fetchSpy)).toContain('/api/metadata?view=index&schema=3');
    expect(metadata.getProviderRetiredModels(kind)).toEqual(original);
  });

  it.each([
    ['new cache row carries the tombstone snapshot', false],
    ['old cache row has no snapshot field: backfilled from the old index persisted before the upgrade', true],
  ] as const)('tombstone snapshot: cached schema 2 index + catalog, switching to a schema 3 index while that provider catalog refetch fails, tombstones are not lost - %s', async (_label, legacyRow) => {
    const kind = 'openAI';
    const original = SCHEMA3.schema2IndexResponse.data.providers[kind].retiredModels;
    expect(Array.isArray(original) && original.length > 0).toBe(true);
    const oldServer = mockFetch(splitServer(schema3Server('schema2')));
    const seeder = await freshClient();
    seeder.setMetadataCatalogDemandSource(() => ({ providerKinds: [kind], hasRelay: false }));
    await seeder.refreshMetadata();
    expect(seeder.getProviderRetiredModels(kind)).toEqual(original);
    await settle();
    oldServer.mockRestore();
    const catalogKey = `${SPLIT_HEAD_KEY.slice(0, -'head'.length)}catalog:${kind}`;
    const persisted = await readRawBlob(catalogKey);
    expect(persisted?.value).toBeTruthy();
    if (legacyRow) {
      const { retiredModels: _dropped, ...rest } = persisted!.value as Record<string, unknown>;
      const { writeBlob } = await import('../../../infra/storage/blob-cache');
      await writeBlob(catalogKey, rest);
    } else {
      expect((persisted!.value as { retiredModels?: unknown }).retiredModels).toEqual(original);
    }

    const newServer = mockFetch(splitServer(schema3Server('compact'), {
      catalog: () => new Response(null, { status: 500 }),
    }));
    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [kind], hasRelay: false }));
    await metadata.initMetadata();
    await metadata.refreshMetadata();
    expect(urls(newServer)).toContain('/api/metadata?view=index&schema=3');
    expect(urls(newServer).some((url) => url.includes(`provider=${kind}`))).toBe(true);
    expect(metadata.getProviderRetiredModels(kind)).toEqual(original);
    await settle();
    if (legacyRow) {
      // The backfilled snapshot has landed: it no longer depends on the old index afterwards
      expect(((await readRawBlob(catalogKey))?.value as { retiredModels?: unknown }).retiredModels).toEqual(original);
    }
  });
});

describe('expandMetadataCatalog: under schema 2 a null / empty-string ref counts as a miss and only drops that model', () => {
  it.each([
    ['capabilityControlsRef', null],
    ['capabilityControlsRef', ''],
    ['profilesRef', null],
    ['profilesRef', ''],
  ] as const)('%s = %j: only that model is dropped and unresolved_ref recorded, other models are kept', (ref, value) => {
    const source = SCHEMA3.schema2CatalogResponses.openAI.data as Record<string, unknown> & { models: Record<string, Record<string, unknown>> };
    expect(source.metadataSchema).toBe(2);
    const [broken, ...kept] = Object.keys(source.models);
    expect(kept.length).toBeGreaterThan(0);
    expect(source.models[broken][ref]).toEqual(expect.any(String));
    const catalog = { ...source, models: { ...source.models, [broken]: { ...source.models[broken], [ref]: value } } };
    const result = expandMetadataCatalog(catalog, { provider: 'openAI' });
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(Object.keys(result.catalog.models).sort()).toEqual([...kept].sort());
    expect(result.catalog.dropped).toEqual([
      { provider: 'openAI', modelId: broken, instancePath: `/${ref}`, keyword: 'unresolved_ref' },
    ]);
  });
});
