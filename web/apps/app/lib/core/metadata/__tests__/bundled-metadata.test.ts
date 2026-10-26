import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Bundled catalog snapshot: on a cold start with no cache and a failing /api/metadata, the catalog is built from the repo gz.
 * The snapshot route returns the real bytes under shared/model-contracts/, and resolution results come from the production API (resolveCatalogModel).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { BUNDLED_METADATA_PATH } from '../bundled-metadata';

const schema = vi.hoisted(() => ({ value: 2 }));
vi.mock('../metadata-request-schema', () => ({
  get METADATA_REQUEST_SCHEMA() {
    return schema.value;
  },
  metadataSchemaQuery: (value: number) => (value >= 2 ? `&schema=${value}` : ''),
}));
vi.mock('../../telemetry', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../telemetry')>()),
  trackEvent: vi.fn(),
}));

const SOURCE_GZ = '../../../shared/model-contracts/bundled-metadata.v2.json.gz';
const GZ_BYTES = readFileSync(SOURCE_GZ);

type Route = (url: string) => Response | Promise<Response>;

function mockFetch(route: Route) {
  return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => route(String(input)));
}

function bundledRequests(spy: ReturnType<typeof mockFetch>): number {
  return spy.mock.calls.filter(([input]) => String(input).endsWith(BUNDLED_METADATA_PATH)).length;
}

/** Everything online fails; the static snapshot answers with the real bytes or 404 depending on the parameter. */
function offlineServer(serveBundled: boolean): Route {
  return (url) => {
    if (url.includes('/api/metadata')) throw new TypeError('network down');
    if (url.endsWith(BUNDLED_METADATA_PATH)) {
      return serveBundled ? new Response(new Uint8Array(GZ_BYTES)) : new Response(null, { status: 404 });
    }
    throw new Error(`unexpected request ${url}`);
  };
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

describe('bundled metadata snapshot', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    schema.value = 2;
    await settle();
    await clearCaches();
  });

  afterEach(async () => {

    await restoreMetadataInstance();
    await settle();
    await clearCaches();
  });

  it('no cache + online failure + switch 2: builds the catalog from the bundled snapshot and does not write it to the cache', async () => {
    const spy = mockFetch(offlineServer(true));
    const metadata = await freshClient();
    await metadata.initMetadata();

    expect(bundledRequests(spy)).toBe(1);
    const model = metadata.resolveCatalogModel('deepseek-flash', 'deepseek');
    expect(model).not.toBeNull();
    expect(model?.capabilityControls).toBeDefined();
    expect(Object.keys(model?.capabilityControls ?? {}).length).toBeGreaterThan(0);

    // The snapshot lives only in memory: on the next cold start with online and static both failing, nothing is in hand.
    await settle();
    vi.restoreAllMocks();
    mockFetch(offlineServer(false));
    const next = await freshClient();
    await next.initMetadata();
    expect(next.resolveCatalogModel('deepseek-flash', 'deepseek')).toBeNull();
  });

  it('refreshing again in the same session after adopting the bundled snapshot: the online revision 1 response overrides the snapshot', async () => {
    const body = JSON.parse(gunzipSync(GZ_BYTES).toString('utf8')) as {
      providers: Record<string, { models: Record<string, { displayName?: string }> }>;
    };
    let online = false;
    const liveName = 'Live Flash';
    mockFetch((url) => {
      if (!online) return offlineServer(true)(url);
      if (url.includes('view=index')) return new Response(null, { status: 400 });
      if (url.includes('view=lean')) {
        const live = structuredClone(body);
        live.providers.deepseek.models['deepseek-flash'].displayName = liveName;
        return new Response(JSON.stringify({ ...live, metadataRevision: 1 }), {
          status: 200,
          headers: { 'Content-Type': 'application/json', ETag: '"lean-r1"' },
        });
      }
      throw new Error(`unexpected request ${url}`);
    });
    const metadata = await freshClient();
    await metadata.initMetadata();
    expect(metadata.resolveCatalogModel('deepseek-flash', 'deepseek')?.displayName).not.toBe(liveName);
    // The bundled snapshot does not count as online confirmation: the startup chain still considers a refresh due
    expect(metadata.isMetadataRefreshDue()).toBe(true);

    online = true;
    await metadata.refreshMetadata();
    expect(metadata.resolveCatalogModel('deepseek-flash', 'deepseek')?.displayName).toBe(liveName);
    expect(metadata.isMetadataRefreshDue()).toBe(false);
  });

  it('switch 1: an online failure does not request the bundled snapshot either', async () => {
    schema.value = 1;
    const spy = mockFetch(offlineServer(true));
    const metadata = await freshClient();
    await metadata.initMetadata();

    expect(bundledRequests(spy)).toBe(0);
    expect(metadata.resolveCatalogModel('deepseek-flash', 'deepseek')).toBeNull();
  });

  it('with a cache: an online failure does not request the bundled snapshot either', async () => {
    // First write the cache from one online full-payload response (index 400 -> lean fallback).
    const body = JSON.parse(gunzipSync(GZ_BYTES).toString('utf8')) as Record<string, unknown>;
    mockFetch((url) => {
      if (url.includes('view=index')) return new Response(null, { status: 400 });
      if (url.includes('view=lean')) {
        return new Response(JSON.stringify({ ...body, metadataRevision: 1 }), {
          status: 200,
          headers: { 'Content-Type': 'application/json', ETag: '"lean-r1"' },
        });
      }
      throw new Error(`unexpected request ${url}`);
    });
    const online = await freshClient();
    await online.initMetadata();
    expect(online.resolveCatalogModel('deepseek-flash', 'deepseek')).not.toBeNull();
    await settle();

    vi.restoreAllMocks();
    const spy = mockFetch(offlineServer(true));
    const metadata = await freshClient();
    await metadata.initMetadata();
    await settle();

    expect(bundledRequests(spy)).toBe(0);
    expect(metadata.resolveCatalogModel('deepseek-flash', 'deepseek')).not.toBeNull();
  });

  it('route /bundled-metadata returns the repo snapshot bytes as is; a missing file returns 404', async () => {
    const { GET } = await import('../../../../app/bundled-metadata/route');
    const res = await GET();
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/gzip');
    expect(Buffer.from(await res.arrayBuffer()).equals(GZ_BYTES)).toBe(true);

    const outDir = mkdtempSync(join(tmpdir(), 'bundled-metadata-'));
    try {
      vi.spyOn(process, 'cwd').mockReturnValue(outDir);
      expect((await GET()).status).toBe(404);
    } finally {
      rmSync(outDir, { recursive: true, force: true });
    }
  });
});
