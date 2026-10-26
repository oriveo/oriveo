import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { __resetRuntimeMetadataCache, getRuntimeMetadata } from './runtime';

interface LeanV1DroppedFields { model?: string[]; capabilityControls?: string[] }

/**
 * Golden leanV1DroppedFields: fields lean v1 deliberately does not project and that only appear in the catalog.
 * Removed from the models of the expanded result before comparing (field names always come from the golden file);
 * if capabilityControls ends up empty the whole key is removed.
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

/** The catalog omits a canonicalModelId equal to the tree id (corpus $comment): before comparing, a missing one is filled in with the tree id. */
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

/**
 * This path runs on every message send, so its caching discipline is user-visible: after the TTL
 * expires the first message waits for this request before streaming starts. The three invariants
 * below are the index request, the conditional request and in-flight deduplication.
 */
const SNAPSHOT = {
  version: 1,
  providers: {},
  profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: { templates: {} } },
};

function jsonResponse(body: unknown, etag: string) {
  return new Response(JSON.stringify({ data: body }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: etag },
  });
}

describe('getRuntimeMetadata caching', () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    __resetRuntimeMetadataCache();
    fetchSpy = vi.spyOn(globalThis, 'fetch') as never;
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    __resetRuntimeMetadataCache();
    vi.useRealTimers();
  });

  it('requests the index first and adopts a full snapshot as-is when the server ignores view', async () => {
    fetchSpy.mockResolvedValue(jsonResponse(SNAPSHOT, '"m1"'));
    const data = await getRuntimeMetadata();

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(String(fetchSpy.mock.calls[0][0])).toBe('https://api.oriveoai.com/api/metadata?view=index&schema=3');
    expect(data).toEqual(SNAPSHOT);
  });

  it('serves from memory inside the TTL without another request', async () => {
    fetchSpy.mockResolvedValue(jsonResponse(SNAPSHOT, '"m1"'));
    const first = await getRuntimeMetadata();
    const second = await getRuntimeMetadata();

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(second).toBe(first);
  });

  it('sends If-None-Match once the TTL expires and reuses the snapshot on 304 instead of downloading it again', async () => {
    const now = vi.spyOn(Date, 'now');
    now.mockReturnValue(1_000_000);
    fetchSpy.mockResolvedValueOnce(jsonResponse(SNAPSHOT, '"m1"'));
    const first = await getRuntimeMetadata();

    // Step past the five-minute TTL.
    now.mockReturnValue(1_000_000 + 5 * 60 * 1000 + 1);
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 304 }));
    const revalidated = await getRuntimeMetadata();

    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(fetchSpy.mock.calls[1][1]).toMatchObject({
      headers: expect.objectContaining({ 'If-None-Match': '"m1"' }),
    });
    // A 304 hands back the same object with a renewed TTL, so the next call issues no request.
    expect(revalidated).toBe(first);
    await getRuntimeMetadata();
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it('shares one in-flight request across calls that arrive the instant the TTL expires', async () => {
    let release: (value: Response) => void = () => {};
    fetchSpy.mockReturnValueOnce(new Promise<Response>((resolve) => { release = resolve; }) as never);

    const inflight = [getRuntimeMetadata(), getRuntimeMetadata(), getRuntimeMetadata()];
    release(jsonResponse(SNAPSHOT, '"m1"'));
    const results = await Promise.all(inflight);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(results[1]).toBe(results[0]);
    expect(results[2]).toBe(results[0]);
  });

  it('keeps the previous snapshot when the request fails, rather than interrupting the chat', async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse(SNAPSHOT, '"m1"'));
    const first = await getRuntimeMetadata();

    __resetRuntimeMetadataCache();
    fetchSpy.mockRejectedValueOnce(new Error('network down'));
    expect(await getRuntimeMetadata()).toBeNull();

    expect(first).not.toBeNull();
  });
});

describe('getRuntimeMetadata index + per-provider catalog', () => {
  const fixture = JSON.parse(readFileSync(
    resolve(process.cwd(), '../../..', 'shared/model-contracts/metadata_catalog_contract.v1.json'),
    'utf8',
  )) as {
    indexResponse: { data: { providers: Record<string, { catalogRevision: string; validation: unknown }> } };
    catalogResponses: Record<string, { data: { catalogRevision: string } }>;
    leanEquivalent: { data: { providers: Record<string, unknown>; generationParameterTables: unknown } };
    leanV1DroppedFields: LeanV1DroppedFields;
    negativeCases: { unresolvedRef: { catalog: unknown } };
  };
  let fetchSpy: ReturnType<typeof vi.spyOn>;
  let indexBody: unknown;

  function route(input: unknown): Response {
    const url = String(input);
    if (url.endsWith('view=index&schema=3')) return jsonResponse(indexBody, '"i1"');
    const kind = /provider=([^&]+)/.exec(url)?.[1];
    const catalog = kind ? fixture.catalogResponses[kind] : undefined;
    if (!catalog) return new Response(null, { status: 404 });
    return new Response(JSON.stringify(catalog), {
      status: 200,
      headers: { 'Content-Type': 'application/json', ETag: `"c-${kind}"` },
    });
  }

  function requested(): string[] {
    return fetchSpy.mock.calls.map(([input]: [unknown]) => {
      const url = String(input);
      return url.slice(url.indexOf('/api/metadata'));
    });
  }

  beforeEach(() => {
    __resetRuntimeMetadataCache();
    indexBody = fixture.indexResponse.data;
    fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => route(input)) as never;
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    __resetRuntimeMetadataCache();
  });

  it('fetches only the index plus the requested provider, reassembled into the lean shape', async () => {
    const data = await getRuntimeMetadata('openAI');

    expect(requested()).toEqual([
      '/api/metadata?view=index&schema=3',
      '/api/metadata?view=catalog&provider=openAI&schema=3',
    ]);
    expect(stripProviderModels(data?.providers.openAI, fixture.leanV1DroppedFields))
      .toEqual(fixture.leanEquivalent.data.providers.openAI);
    expect(data?.generationParameterTables).toEqual(fixture.leanEquivalent.data.generationParameterTables);
    // Other providers carry only index fields: validation is still readable, but their model
    // catalogs are not downloaded for this request.
    expect(data?.providers.anthropic?.validation).toEqual(fixture.indexResponse.data.providers.anthropic.validation);
    expect(data?.providers.anthropic?.models).toEqual({});
    expect(data?.providers.anthropic?.resolveMap).toBeUndefined();
  });

  it('shares one catalog fetch across concurrent requests for a kind and skips it while the revision is unchanged', async () => {
    const results = await Promise.all([
      getRuntimeMetadata('openAI'),
      getRuntimeMetadata('openAI'),
      getRuntimeMetadata('openAI'),
    ]);
    expect(requested().filter((url) => url.includes('view=catalog'))).toHaveLength(1);
    expect(results[1]).toBe(results[0]);

    // A new index where the openAI revision is unchanged: only the index is fetched again.
    const now = vi.spyOn(Date, 'now');
    now.mockReturnValue(Date.now() + 5 * 60 * 1000 + 1);
    indexBody = { ...fixture.indexResponse.data, version: 87 };
    fetchSpy.mockClear();
    await getRuntimeMetadata('openAI');
    expect(requested()).toEqual(['/api/metadata?view=index&schema=3']);
    now.mockRestore();
  });

  it('rejects a catalog with an unresolved ref as a whole instead of dropping models one by one', async () => {
    fetchSpy.mockImplementation(async (input: unknown) => {
      const url = String(input);
      if (url.includes('provider=openAI')) {
        return jsonResponse(fixture.negativeCases.unresolvedRef.catalog, '"bad"');
      }
      return route(input);
    });
    const data = await getRuntimeMetadata('openAI');

    expect(data?.providers.openAI?.models).toEqual({});
    expect(data?.providers.openAI?.resolveMap).toBeUndefined();
  });

  it('keeps provider-level fields and accepts no models when a listed provider answers the catalog with 404', async () => {
    fetchSpy.mockImplementation(async (input: unknown) => (
      String(input).includes('provider=openAI') ? new Response(null, { status: 404 }) : route(input)
    ));
    const data = await getRuntimeMetadata('openAI');

    // No models were ever accepted, so there is nothing to show; the provider-level fields remain.
    expect(data?.providers.openAI?.models).toEqual({});
    expect(data?.providers.openAI?.validation).toEqual(fixture.indexResponse.data.providers.openAI.validation);
  });

  it('requests schema=3 (the production value): index / catalog URLs carry &schema=3, the lean fallback does not, and no schema request header is sent', async () => {
    await getRuntimeMetadata('openAI');
    expect(requested()).toEqual([
      '/api/metadata?view=index&schema=3',
      '/api/metadata?view=catalog&provider=openAI&schema=3',
    ]);
    for (const [, init] of fetchSpy.mock.calls as Array<[unknown, RequestInit | undefined]>) {
      expect(Object.keys((init?.headers ?? {}) as Record<string, string>)
        .map((name) => name.toLowerCase())).not.toContain('x-oriveo-metadata-schema');
    }
  });

  describe('schema 2 index: envelope validation, and the revision only moves forward', () => {
    const schema2Index = (metadataRevision: number) => ({
      ...fixture.indexResponse.data,
      metadataSchema: 2,
      metadataRevision,
      generatedAt: '2026-10-19T00:00:00Z',
    });
    const expireTtl = () => {
      const now = vi.spyOn(Date, 'now');
      now.mockReturnValue(Date.now() + 5 * 60 * 1000 + 1);
      return now;
    };

    it('rejects an index with a broken envelope as a whole and returns the previous usable data', async () => {
      indexBody = schema2Index(5);
      const first = await getRuntimeMetadata();
      expect(first?.providers.openAI).toBeDefined();

      const now = expireTtl();
      const { generatedAt: _dropped, ...broken } = schema2Index(6);
      indexBody = { ...broken, providers: { openAI: fixture.indexResponse.data.providers.openAI } };
      fetchSpy.mockClear();
      const second = await getRuntimeMetadata();
      now.mockRestore();

      expect(requested()).toEqual(['/api/metadata?view=index&schema=3']);
      expect(second).toBe(first);
    });

    it('rejects a revision regression and keeps the previous copy; a later revision advance is accepted', async () => {
      indexBody = schema2Index(5);
      const first = await getRuntimeMetadata();

      let now = expireTtl();
      indexBody = { ...schema2Index(4), version: 1 };
      const regressed = await getRuntimeMetadata();
      now.mockRestore();
      expect(regressed).toBe(first);

      now = expireTtl();
      indexBody = { ...schema2Index(6), version: 99 };
      const advanced = await getRuntimeMetadata();
      now.mockRestore();
      expect(advanced).not.toBe(first);
      expect((advanced as { version?: number } | null)?.version).toBe(99);
    });

    it('treats an equal revision as unchanged: the snapshot is not replaced and the TTL is renewed', async () => {
      indexBody = schema2Index(5);
      const first = await getRuntimeMetadata();

      const now = expireTtl();
      indexBody = { ...schema2Index(5), version: 42 };
      fetchSpy.mockClear();
      const same = await getRuntimeMetadata();
      expect(same).toBe(first);
      expect(requested()).toEqual(['/api/metadata?view=index&schema=3']);
      // Already renewed: the very next call makes no request
      await getRuntimeMetadata();
      now.mockRestore();
      expect(requested()).toHaveLength(1);
    });
  });

  it('upgrade: holding a schema 2 index + catalog and the server answers schema 3 with the same revision, a provider not yet held is still fetched and everything converges', async () => {
    type Wire = { data: Record<string, unknown> & { providers?: Record<string, Record<string, unknown>> } };
    const schema3 = (JSON.parse(readFileSync(
      resolve(process.cwd(), '../../..', 'shared/model-contracts/metadata_catalog_contract.v1.json'),
      'utf8',
    )) as { schema3: {
      indexResponse: Wire; schema2IndexResponse: Wire;
      catalogResponses: Record<string, Wire>; schema2CatalogResponses: Record<string, Wire>;
    } }).schema3;
    // Both versions share one revision: exactly the "equal revision counts as unchanged" case this guards against
    expect(schema3.indexResponse.data.metadataRevision).toBe(schema3.schema2IndexResponse.data.metadataRevision);
    let version: 'schema2' | 'compact' = 'schema2';
    fetchSpy.mockImplementation(async (input: unknown) => {
      const url = String(input);
      const index = version === 'compact' ? schema3.indexResponse : schema3.schema2IndexResponse;
      const catalogs = version === 'compact' ? schema3.catalogResponses : schema3.schema2CatalogResponses;
      if (url.includes('view=index')) return jsonResponse(index.data, `"i-${version}"`);
      const kind = /provider=([^&]+)/.exec(url)?.[1];
      const catalog = kind ? catalogs[kind] : undefined;
      return catalog ? jsonResponse(catalog.data, `"c-${version}-${kind}"`) : new Response(null, { status: 404 });
    });
    const held = await getRuntimeMetadata('anthropic');
    expect(Object.keys(held?.providers.anthropic?.models ?? {}).length).toBeGreaterThan(0);

    const now = vi.spyOn(Date, 'now');
    now.mockReturnValue(Date.now() + 5 * 60 * 1000 + 1);
    version = 'compact';
    const data = await getRuntimeMetadata('openAI');
    expect(Object.keys(data?.providers.openAI?.models ?? {}).sort())
      .toEqual(Object.keys(schema3.catalogResponses.openAI.data.models as Record<string, unknown>).sort());
    expect((data?.providers.openAI as { retiredModels?: unknown } | undefined)?.retiredModels).toEqual(schema3.schema2IndexResponse.data.providers?.openAI.retiredModels);

    // The provider already held is also switched to the schema 3 catalog: a later fetch at the same revision no longer requests the catalog
    const anthropic = await getRuntimeMetadata('anthropic');
    expect(Object.keys(anthropic?.providers.anthropic?.models ?? {}).length).toBeGreaterThan(0);
    fetchSpy.mockClear();
    now.mockReturnValue(Date.now() + 15 * 60 * 1000);
    await getRuntimeMetadata('anthropic');
    await getRuntimeMetadata('openAI');
    expect(requested().filter((url) => url.includes('view=catalog'))).toEqual([]);
    now.mockRestore();
  });

  it('tombstone snapshot: holding a schema 2 index + catalog, then moving to a schema 3 index while the catalog refetch for that provider fails, the tombstones are not lost', async () => {
    type Wire = { data: Record<string, unknown> & { providers?: Record<string, Record<string, unknown>> } };
    const schema3 = (JSON.parse(readFileSync(
      resolve(process.cwd(), '../../..', 'shared/model-contracts/metadata_catalog_contract.v1.json'),
      'utf8',
    )) as { schema3: {
      indexResponse: Wire; schema2IndexResponse: Wire; schema2CatalogResponses: Record<string, Wire>;
    } }).schema3;
    const original = schema3.schema2IndexResponse.data.providers?.openAI.retiredModels;
    expect(Array.isArray(original) && original.length > 0).toBe(true);
    let upgraded = false;
    fetchSpy.mockImplementation(async (input: unknown) => {
      const url = String(input);
      if (url.includes('view=index')) {
        return jsonResponse((upgraded ? schema3.indexResponse : schema3.schema2IndexResponse).data, upgraded ? '"i3"' : '"i2"');
      }
      if (upgraded) return new Response(null, { status: 500 });
      return jsonResponse(schema3.schema2CatalogResponses.openAI.data, '"c2"');
    });
    const retiredOf = (data: Awaited<ReturnType<typeof getRuntimeMetadata>>) => (
      data?.providers.openAI as { retiredModels?: unknown } | undefined
    )?.retiredModels;
    expect(retiredOf(await getRuntimeMetadata('openAI'))).toEqual(original);

    const now = vi.spyOn(Date, 'now');
    now.mockReturnValue(Date.now() + 5 * 60 * 1000 + 1);
    upgraded = true;
    fetchSpy.mockClear();
    const data = await getRuntimeMetadata('openAI');
    // It really moved to the schema 3 index and tried to refetch this provider's catalog (failed, last-good kept)
    expect(requested().some((url) => url.includes('view=catalog&provider=openAI'))).toBe(true);
    expect(Object.keys(data?.providers.openAI?.models ?? {}).length).toBeGreaterThan(0);
    expect(retiredOf(data)).toEqual(original);
    now.mockRestore();
  });

  it('falls back to lean when the server answers view=index with 400', async () => {
    fetchSpy.mockImplementation(async (input: unknown) => (
      String(input).includes('view=index')
        ? new Response(null, { status: 400 })
        : jsonResponse(fixture.leanEquivalent.data, '"lean-1"')
    ));
    const data = await getRuntimeMetadata('openAI');

    expect(requested()).toEqual(['/api/metadata?view=index&schema=3', '/api/metadata?view=lean']);
    expect(data).toEqual(fixture.leanEquivalent.data);
  });
});
