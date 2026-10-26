import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Web tests for the per-entry validation of metadata schema 2 (see the model catalog and capability truth contract).
 *
 * Case corpus comes only from the shared fixture metadata_payload.v2.cases.json; production-path cases upgrade the index / catalog of metadata_catalog_contract.v1.json
 * to schema 2, fetch them via refreshMetadata, and assert what resolveCatalogModel actually produces.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import {
  compareMetadataRevision,
  decodeMetadataFullOrIndexV2,
  metadataRevisionOf,
  type MetadataRevisionVerdict,
} from '../metadata-payload-v2';
import { expandMetadataCatalog } from '../metadata-split';
import { generateMetadataValidatorsSource, OUTPUT_PATH } from '../../../../scripts/generate-metadata-validators.mjs';

// Pricing time is passed explicitly: a fixed instant, never the wall clock.
const PRICED_AT = () => new Date('2026-10-19T12:00:00Z');

const trackEvent = vi.fn();
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: (...args: unknown[]) => trackEvent(...args),
}));

type JsonRecord = Record<string, unknown>;

interface PayloadCasesFixture {
  reportCode: string;
  revisionCases: Array<{ name: string; cached: number | null; incoming: number; expect: MetadataRevisionVerdict }>;
  catalogCases: Array<{
    name: string;
    data: JsonRecord;
    expect: { envelope: 'accept' | 'reject'; keptModels?: string[]; droppedModels?: string[] };
  }>;
}

interface CatalogContractFixture {
  indexResponse: { data: JsonRecord & { providers: Record<string, JsonRecord> } };
  catalogResponses: Record<string, { data: JsonRecord & { catalogRevision: string; models: Record<string, JsonRecord> } }>;
}

function loadFixture<T>(name: string): T {
  return JSON.parse(readFileSync(`../../../shared/model-contracts/${name}`, 'utf8')) as T;
}

const CASES = loadFixture<PayloadCasesFixture>('metadata_payload.v2.cases.json');
const SCHEMA2_FIELDS = { metadataSchema: 2, metadataRevision: 3, generatedAt: '2026-10-19T00:00:00Z' };

describe('metadata revision rule: shared fixture revisionCases', () => {
  // The client and the Next server runtime share this one pure function; the revision is read through the production metadataRevisionOf.
  it.each(CASES.revisionCases.map((c) => [c.name, c] as const))('%s', (_name, testCase) => {
    const incoming = metadataRevisionOf({ ...SCHEMA2_FIELDS, metadataRevision: testCase.incoming });
    expect(incoming).toBe(testCase.incoming);
    expect(compareMetadataRevision(testCase.cached, incoming)).toBe(testCase.expect);
  });

  it('a schema 1 body has no revision: metadataRevisionOf is null and it is accepted', () => {
    expect(metadataRevisionOf({ metadataRevision: 9 })).toBeNull();
    expect(compareMetadataRevision(5, metadataRevisionOf({ metadataRevision: 9 }))).toBe('accept');
  });
});

describe('metadata payload v2 decode: shared fixture catalogCases', () => {
  // Goes through the production expand function: expand table references first, then validate model by model (a bad table entry takes down the models referencing it; a missed reference only drops that model).
  it.each(CASES.catalogCases.map((c) => [c.name, c] as const))('%s', (_name, testCase) => {
    const result = expandMetadataCatalog(testCase.data, { provider: testCase.data.provider as string });
    if (testCase.expect.envelope === 'reject') {
      expect(result).toEqual({ ok: false, reason: 'malformed' });
      return;
    }
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(Object.keys(result.catalog.models).sort()).toEqual([...testCase.expect.keptModels!].sort());
    expect(result.catalog.dropped.map((entry) => entry.modelId).sort()).toEqual([...testCase.expect.droppedModels!].sort());
    for (const entry of result.catalog.dropped) {
      // Only provider / modelId / instancePath / keyword, never any value
      expect(Object.keys(entry).sort()).toEqual(['instancePath', 'keyword', 'modelId', 'provider']);
      expect(entry.provider).toBe(testCase.data.provider);
      expect(entry.keyword.length).toBeGreaterThan(0);
    }
  });

  it('report codes match the fixture', () => {
    expect(CASES.reportCode).toBe('model_entry_invalid');
  });

  it('full / index: a bad provider is dropped whole, a bad model only that entry, a bad envelope rejects the whole payload', () => {
    const base = { contractVersion: 1, ...SCHEMA2_FIELDS };
    const accepted = decodeMetadataFullOrIndexV2({
      ...base,
      providers: {
        good: { displayName: 'Good', models: { 'm-a': { displayName: 'A' }, 'm-bad': { displayName: 1 } } },
        nameless: { modelCount: 1 },
      },
    });
    expect(accepted.envelope).toBe('accept');
    const providers = (accepted.data as { providers: Record<string, { models: JsonRecord }> }).providers;
    expect(Object.keys(providers)).toEqual(['good']);
    expect(Object.keys(providers.good.models)).toEqual(['m-a']);
    expect(accepted.dropped).toEqual([
      { provider: 'good', modelId: 'm-bad', instancePath: '/displayName', keyword: 'type' },
      { provider: 'nameless', instancePath: '', keyword: 'required' },
    ]);

    const rejected = decodeMetadataFullOrIndexV2({ contractVersion: 1, metadataSchema: 2, providers: {} });
    expect(rejected.envelope).toBe('reject');
  });

  it('a malformed pricingV2 only drops that key: both the full payload and catalog validation keep the model and record one drop', () => {
    const badPricingV2 = { unit: 'per_token', base: { inputPerMToken: '2', outputPerMToken: 8 } };
    const full = decodeMetadataFullOrIndexV2({
      contractVersion: 1,
      ...SCHEMA2_FIELDS,
      providers: {
        good: {
          displayName: 'Good',
          models: {
            'm-bad-price': { displayName: 'P', pricingV2: badPricingV2 },
            'm-bad-both': { displayName: 1, pricingV2: badPricingV2 },
          },
        },
      },
    });
    expect(full.envelope).toBe('accept');
    const models = (full.data as { providers: Record<string, { models: JsonRecord }> }).providers.good.models;
    expect(models).toEqual({ 'm-bad-price': { displayName: 'P' } });
    expect(full.dropped.map((entry) => entry.modelId).sort()).toEqual(['m-bad-both', 'm-bad-price']);
    const priceDrop = full.dropped.find((entry) => entry.modelId === 'm-bad-price');
    expect(priceDrop?.instancePath.startsWith('/pricingV2')).toBe(true);
    expect(full.dropped.find((entry) => entry.modelId === 'm-bad-both')?.instancePath).toBe('/displayName');

    const corpus = loadFixture<CatalogContractFixture>('metadata_catalog_contract.v1.json');
    const provider = Object.keys(corpus.catalogResponses)[0];
    const catalogData = corpus.catalogResponses[provider].data;
    const modelId = Object.keys(catalogData.models)[0];
    const expanded = expandMetadataCatalog(
      {
        ...catalogData,
        ...SCHEMA2_FIELDS,
        models: { ...catalogData.models, [modelId]: { ...catalogData.models[modelId], pricingV2: badPricingV2 } },
      },
      { provider },
    );
    expect(expanded.ok).toBe(true);
    if (!expanded.ok) return;
    expect(expanded.catalog.models[modelId]).toBeDefined();
    expect('pricingV2' in expanded.catalog.models[modelId]!).toBe(false);
    expect(expanded.catalog.dropped.map((entry) => entry.modelId)).toEqual([modelId]);
  });

  it('a bad regionPricing item only drops that item: the model and other region prices stay; all-bad removes the key too; unknown keys inside an item are accepted', () => {
    const cn = {
      regionScope: 'cn', currencyCode: 'CNY', pricingStatus: 'priced', pricingUnit: 'per_token',
      pricing: { promptPerMToken: 4, completionPerMToken: 16 }, futureKey: 1,
    };
    const badPricing = { ...cn, regionScope: 'hk', pricing: 'not-an-object' };
    const badStatus = { ...cn, regionScope: 'sg', pricingStatus: 'maybe' };
    const full = decodeMetadataFullOrIndexV2({
      contractVersion: 1,
      ...SCHEMA2_FIELDS,
      providers: {
        good: {
          displayName: 'Good',
          models: {
            'm-mixed': { displayName: 'M', regionPricing: [badPricing, cn, badStatus] },
            'm-all-bad': { displayName: 'A', regionPricing: [badPricing] },
            'm-ok': { displayName: 'O', regionPricing: [cn] },
          },
        },
      },
    });
    expect(full.envelope).toBe('accept');
    const models = (full.data as { providers: Record<string, { models: JsonRecord }> }).providers.good.models;
    expect(models).toEqual({
      'm-mixed': { displayName: 'M', regionPricing: [cn] },
      'm-all-bad': { displayName: 'A' },
      'm-ok': { displayName: 'O', regionPricing: [cn] },
    });
    expect(full.dropped.map((entry) => entry.modelId).sort()).toEqual(['m-all-bad', 'm-mixed']);
    expect(full.dropped.every((entry) => entry.instancePath.startsWith('/regionPricing/'))).toBe(true);
  });
});

describe('metadata payload v2 generated validators', () => {
  it('in-memory regeneration is byte-identical to the checked-in file', () => {
    expect(generateMetadataValidatorsSource()).toBe(readFileSync(OUTPUT_PATH, 'utf8'));
  });
});

function json(body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
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

describe('metadata payload v2 production path', () => {
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

  it('schema 2 catalog with a bad model: the result lacks that model and reports it; lifecycle / parameterSupport land in the resolved metadata', async () => {
    const corpus = loadFixture<CatalogContractFixture>('metadata_catalog_contract.v1.json');
    const provider = Object.keys(corpus.catalogResponses)[0];
    const catalogData = corpus.catalogResponses[provider].data;
    const goodModelId = Object.keys(catalogData.models)[0];
    const lifecycle = { state: 'deprecated', shutdownAt: '2026-12-01T00:00:00Z', signal: 'upstream_shutdown_date' };
    const parameterSupport = { temperature: { support: 'supported' } };
    const index = {
      ...corpus.indexResponse.data,
      ...SCHEMA2_FIELDS,
      providers: {
        [provider]: corpus.indexResponse.data.providers[provider],
        nameless: { catalogRevision: catalogData.catalogRevision, modelCount: 1 },
      },
    };
    const catalog = {
      ...catalogData,
      ...SCHEMA2_FIELDS,
      models: {
        ...catalogData.models,
        [goodModelId]: { ...catalogData.models[goodModelId], lifecycle, parameterSupport },
        'm-bad-lifecycle': { displayName: 'Bad', lifecycle: { state: 'sunset' } },
      },
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('view=index&schema=3')) return json({ code: 0, data: index }, { ETag: '"index-v2"' });
      if (url.includes(`view=catalog&provider=${provider}`)) {
        return json({ code: 0, data: catalog }, { ETag: '"catalog-v2"', 'X-Metadata-Catalog-Revision': catalog.catalogRevision });
      }
      return new Response(null, { status: 404 });
    });

    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.initMetadata();
    await metadata.refreshMetadata();

    const resolved = metadata.resolveCatalogModel(goodModelId, provider);
    expect(resolved?.lifecycle).toEqual(lifecycle);
    expect(resolved?.parameterSupport).toEqual(parameterSupport);
    expect(metadata.resolveCatalogModel('m-bad-lifecycle', provider)).toBeNull();
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: provider.toLowerCase(),
      reason: 'model_entry_invalid',
      model_id: 'm-bad-lifecycle',
      instance_path: '/lifecycle/state',
      keyword: 'enum',
    });
    // A provider missing displayName in the index is dropped whole and reported, without modelId
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', {
      provider_kind: 'nameless',
      reason: 'model_entry_invalid',
      instance_path: '',
      keyword: 'required',
    });
  });

  it('schema 2 full payload with a bad pricingV2 model: the model stays, pricingV2 is missing, deriveCostFields takes the legacy path', async () => {
    const corpus = loadFixture<CatalogContractFixture>('metadata_catalog_contract.v1.json');
    const provider = Object.keys(corpus.catalogResponses)[0];
    const catalogData = corpus.catalogResponses[provider].data;
    const modelId = Object.keys(catalogData.models)[0];
    // Bad shape: a key outside the allowlist plus a price set that would make the result obviously different; if adopted, the cost would be computed at 999/M.
    const badPricingV2 = { unit: 'per_token', base: { inputPerMToken: 999, outputPerMToken: 999 }, discount: 0.5 };
    const { view: _view, ...indexFields } = corpus.indexResponse.data as JsonRecord;
    const full = {
      ...indexFields,
      ...SCHEMA2_FIELDS,
      providers: {
        [provider]: {
          ...corpus.indexResponse.data.providers[provider],
          models: { [modelId]: { ...catalogData.models[modelId], pricingV2: badPricingV2 } },
        },
      },
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('view=index&schema=3')) return json({ code: 0, data: full }, { ETag: '"full-v2"' });
      return new Response(null, { status: 404 });
    });

    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.initMetadata();
    await metadata.refreshMetadata();

    const resolved = metadata.resolveCatalogModel(modelId, provider);
    expect(resolved).not.toBeNull();
    expect(resolved?.pricingV2).toBeUndefined();
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', expect.objectContaining({
      provider_kind: provider.toLowerCase(),
      reason: 'model_entry_invalid',
      model_id: modelId,
      instance_path: '/pricingV2',
    }));

    const { deriveCostFields } = await import('../../chat/cost-fields');
    const { calcCostFromResolved } = await import('../../chat/cost');
    const breakdown = {
      promptTokens: 1000,
      cachedInputTokens: 0,
      cacheCreation5mTokens: 0,
      cacheCreation1hTokens: 0,
      completionTokens: 100,
      reasoningTokens: 0,
    };
    const fields = deriveCostFields({ breakdown }, { id: modelId, name: modelId } as never, { kind: provider } as never, PRICED_AT);
    const legacy = calcCostFromResolved(breakdown, resolved);
    expect(legacy.source).toBe('localEstimate');
    expect(fields.costSource).toBe('localEstimate');
    expect(fields.cost).toBe(legacy.cost);
    expect(fields.cost).toBeLessThan((1000 * 999 + 100 * 999) / 1_000_000);
  });

  it('schema 2 catalog with a bad envelope: the whole payload is rejected, the provider stays pending and malformed is recorded', async () => {
    const corpus = loadFixture<CatalogContractFixture>('metadata_catalog_contract.v1.json');
    const provider = Object.keys(corpus.catalogResponses)[0];
    const catalogData = corpus.catalogResponses[provider].data;
    const index = { ...corpus.indexResponse.data, ...SCHEMA2_FIELDS };
    const { metadataRevision: _omitted, ...badCatalog } = { ...catalogData, ...SCHEMA2_FIELDS };
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
      const url = String(input);
      if (url.endsWith('view=index&schema=3')) return json({ code: 0, data: index }, { ETag: '"index-v2"' });
      if (url.includes(`view=catalog&provider=${provider}`)) return json({ code: 0, data: badCatalog }, { ETag: '"bad"' });
      return new Response(null, { status: 404 });
    });

    const metadata = await freshClient();
    metadata.setMetadataCatalogDemandSource(() => ({ providerKinds: [provider], hasRelay: false }));
    await metadata.initMetadata();
    await metadata.refreshMetadata();

    expect(metadata.getProviderCatalogStatus(provider)).toBe('pending');
    expect(trackEvent).toHaveBeenCalledWith('metadata_catalog_rejected', { provider_kind: provider.toLowerCase(), reason: 'malformed' });
  });
});
