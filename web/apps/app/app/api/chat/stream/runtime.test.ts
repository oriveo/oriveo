import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { __resetRuntimeMetadataCache, getRuntimeMetadata } from './runtime';

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
    expect(String(fetchSpy.mock.calls[0][0])).toBe('https://api.oriveoai.com/api/metadata?view=index');
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
    negativeCases: { unresolvedRef: { catalog: unknown } };
  };
  let fetchSpy: ReturnType<typeof vi.spyOn>;
  let indexBody: unknown;

  function route(input: unknown): Response {
    const url = String(input);
    if (url.endsWith('view=index')) return jsonResponse(indexBody, '"i1"');
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
      '/api/metadata?view=index',
      '/api/metadata?view=catalog&provider=openAI',
    ]);
    expect(data?.providers.openAI).toEqual(fixture.leanEquivalent.data.providers.openAI);
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
    expect(requested()).toEqual(['/api/metadata?view=index']);
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

  it('falls back to lean when the server answers view=index with 400', async () => {
    fetchSpy.mockImplementation(async (input: unknown) => (
      String(input).endsWith('view=index')
        ? new Response(null, { status: 400 })
        : jsonResponse(fixture.leanEquivalent.data, '"lean-1"')
    ));
    const data = await getRuntimeMetadata('openAI');

    expect(requested()).toEqual(['/api/metadata?view=index', '/api/metadata?view=lean']);
    expect(data).toEqual(fixture.leanEquivalent.data);
  });
});
