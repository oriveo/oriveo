import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 *
 * Metadata cache bucketing and storage medium.
 *
 * Rules:
 *   - The snapshot lives in IndexedDB, never in localStorage. In production it measures 3.3MB, so
 *     writing it to localStorage would eat 66% of the 5MB Chrome quota and squeeze out the
 *     `firestore_mutations_*` broadcast keys a sync SDK needs. The "not one byte in
 *     localStorage" assertion in this file guards that regression.
 *   - The cache key prefix must carry `c{contractVersion}`, e.g. `oriveo:metadata:c1`.
 *   - A contractVersion change invalidates the old cache and forces a full fetch.
 *   - Startup clears every historical metadata remnant from localStorage (unbucketed, bucketed and
 *     ETag), handing those 3.3MB straight back to the browser for existing users.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const LEGACY_KEY = 'oriveo:metadata';
const LEGACY_ETAG_KEY = 'oriveo:metadata:etag';
const CURRENT_KEY = 'oriveo:metadata:c1';

function buildPayload(contractVersion: number, version = 1) {
  return {
    version,
    contractVersion,
    updatedAt: '2026-04-18T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {},
    providerConfigs: [],
  };
}

/** Reads the IDB blob directly, bypassing the current-contract restriction in metadata-client, so the c2 bucket can be asserted. */
async function readBucket(key: string) {
  const { readBlob } = await import('../../../infra/storage/blob-cache');
  return readBlob<{ data: { contractVersion?: number } }>(key);
}

async function clearBuckets() {
  const { pruneBlobs } = await import('../../../infra/storage/blob-cache');
  await pruneBlobs('oriveo:metadata:c', []);
}

describe('metadata cache bucketing and storage medium', () => {
  beforeEach(async () => {
    vi.resetModules();
    vi.restoreAllMocks();
    // persistCache writes asynchronously through setTimeout(cb, 0); let the schedule left over from
    // the previous test finish, or it runs after this test clears the database and writes the old
    // data back, breaking isolation.
    await new Promise((r) => setTimeout(r, 20));
    localStorage.clear();
    await clearBuckets();
  });
  afterEach(async () => {
    await new Promise((r) => setTimeout(r, 20));
    localStorage.clear();
    await clearBuckets();
  });

  it('writes the snapshot to IndexedDB under `oriveo:metadata:c{contractVersion}` — never to localStorage', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify(buildPayload(1, 7)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const { initMetadata } = await import('../metadata-client');
    await initMetadata();

    // Wait for requestIdleCallback -> setTimeout -> IDB put to finish
    await new Promise((r) => setTimeout(r, 30));

    const entry = await readBucket(CURRENT_KEY);
    expect(entry).not.toBeNull();
    expect(entry!.value.data.contractVersion).toBe(1);

    // Regression guard: no part of the snapshot may land in localStorage.
    // A failure here means 3.3MB is back inside the shared 5MB quota and the sync queue gets squeezed out again.
    expect(localStorage.getItem(CURRENT_KEY)).toBeNull();
    expect(localStorage.getItem(LEGACY_KEY)).toBeNull();
    expect(localStorage.length).toBe(0);
  });

  it('one-shot cleanup: drops every legacy metadata key from localStorage on init', async () => {
    // Three generations of remnants an existing user may hold: unbucketed, bucketed snapshot, bucketed ETag
    localStorage.setItem(LEGACY_KEY, JSON.stringify({ timestamp: Date.now(), data: buildPayload(1, 5) }));
    localStorage.setItem(LEGACY_ETAG_KEY, 'W/"old"');
    localStorage.setItem(CURRENT_KEY, JSON.stringify({ timestamp: Date.now(), data: buildPayload(1, 6) }));
    localStorage.setItem('oriveo:metadata:etag:c1', 'W/"old-bucketed"');
    // Unrelated keys must survive; the cleanup only targets the metadata prefix
    localStorage.setItem('oriveo.theme', 'dark');

    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify(buildPayload(1, 7)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const { initMetadata } = await import('../metadata-client');
    await initMetadata();

    expect(localStorage.getItem(LEGACY_KEY)).toBeNull();
    expect(localStorage.getItem(LEGACY_ETAG_KEY)).toBeNull();
    expect(localStorage.getItem(CURRENT_KEY)).toBeNull();
    expect(localStorage.getItem('oriveo:metadata:etag:c1')).toBeNull();
    expect(localStorage.getItem('oriveo.theme')).toBe('dark');
  });

  it('contractVersion change → discards old-bucket cache and does a full fetch', async () => {
    // The old cache sits in the c1 bucket
    const { writeBlob } = await import('../../../infra/storage/blob-cache');
    await writeBlob(CURRENT_KEY, { data: buildPayload(1, 10), etag: null });

    // The backend starts returning contractVersion = 2, an update within the client support window
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify(buildPayload(2, 20)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const { initMetadata } = await import('../metadata-client');
    await initMetadata();
    await new Promise((r) => setTimeout(r, 30));

    // The new cache is written to the c2 bucket
    const c2 = await readBucket('oriveo:metadata:c2');
    expect(c2).not.toBeNull();
    expect(c2!.value.data.contractVersion).toBe(2);

    // The old c1 bucket is cleared
    expect(await readBucket(CURRENT_KEY)).toBeNull();

    // A network round trip is required; the stale cache must not be reused
    expect(fetchMock).toHaveBeenCalled();
  });

  it('survives a cold start when IndexedDB is unavailable (falls back to network, never throws)', async () => {
    // Private mode, or the user disabled site data: open throws outright
    const original = globalThis.indexedDB;
    Object.defineProperty(globalThis, 'indexedDB', {
      configurable: true,
      value: {
        open() {
          throw new DOMException('The user denied permission to access the database.', 'UnknownError');
        },
        databases: () => Promise.reject(new DOMException('denied', 'UnknownError')),
      },
    });

    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify(buildPayload(1, 42)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    try {
      const { initMetadata, getMetadataSnapshot } = await import('../metadata-client');
      await expect(initMetadata()).resolves.toBeUndefined();
      expect(fetchMock).toHaveBeenCalled();
      // A failed cache write must not break the session: the snapshot has to be in memory
      expect(getMetadataSnapshot()).not.toBeNull();
    } finally {
      Object.defineProperty(globalThis, 'indexedDB', { configurable: true, value: original });
    }
  });
});
