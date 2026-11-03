/**
 * Studio presets Store: offline snapshot fallback, persisted cache + body, the
 * 6-hour refresh throttle with If-None-Match, and locale switches.
 * Fake fetch + in-memory storage; expected presets come from the real decoder.
 */
import { describe, expect, it } from 'vitest';
import {
  bundledStudioPresetsSnapshot,
  decodeStudioPresets,
  localizeStudioPresets,
  type StudioPresets,
} from '../presets';
import { createStudioPresetsStore, STUDIO_PRESETS_STORAGE_KEY } from '../presets-store';

const BASE = 'https://backend.example.test';
const T0 = 1_800_000_000_000;
const SIX_HOURS = 6 * 3600 * 1000;
const NEW_REVISION = '2099-01-01.1';
const ETAG = '"presets-r2"';

type Reply = { status: number; etag?: string; body?: unknown } | 'throw';

interface FakeCall {
  url: string;
  ifNoneMatch: string | null;
  cache: RequestCache | undefined;
}

function fakeFetch(replies: Reply[]) {
  const calls: FakeCall[] = [];
  const fn = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const headers = new Headers(init?.headers);
    calls.push({ url: String(input), ifNoneMatch: headers.get('If-None-Match'), cache: init?.cache });
    const reply = replies.shift();
    if (!reply) throw new Error(`unexpected fetch #${calls.length}`);
    if (reply === 'throw') throw new TypeError('network down');
    const responseHeaders = new Headers();
    if (reply.etag) responseHeaders.set('ETag', reply.etag);
    const text = reply.body === undefined ? null : JSON.stringify(reply.body);
    return new Response(reply.status === 304 ? null : text, { status: reply.status, headers: responseHeaders });
  };
  return { fn: fn as typeof fetch, calls };
}

function memoryStorage(initial: Record<string, string> = {}) {
  const map = new Map(Object.entries(initial));
  return {
    map,
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => {
      map.set(key, value);
    },
  };
}

function offline(tag: string): StudioPresets {
  const decoded = decodeStudioPresets(localizeStudioPresets(bundledStudioPresetsSnapshot(), tag));
  if (decoded.error !== null) throw new Error(`bundled snapshot does not decode for ${tag}`);
  return decoded;
}

// A Server-shaped envelope with a newer revision (built from the snapshot, then re-labelled).
function serverEnvelope(tag: string, revision = NEW_REVISION) {
  const env = localizeStudioPresets(bundledStudioPresetsSnapshot(), tag);
  return { ...env, data: { ...env.data, revision } };
}

function persisted(storage: ReturnType<typeof memoryStorage>) {
  const raw = storage.map.get(STUDIO_PRESETS_STORAGE_KEY);
  return raw === undefined ? undefined : (JSON.parse(raw) as { cache: Record<string, unknown>; body: unknown });
}

describe('studio presets store', () => {
  it('offlineFallsBackToSnapshot', () => {
    const empty = createStudioPresetsStore({ fetch: fakeFetch([]).fn, storage: memoryStorage(), backendURL: BASE });
    const presets = empty.current('en');
    expect(presets, 'empty storage -> offline snapshot').toEqual(offline('en'));
    expect(presets?.revision).toBe(bundledStudioPresetsSnapshot().revision);
    expect(presets?.styles.length).toBeGreaterThan(0);

    const corrupt = memoryStorage({
      [STUDIO_PRESETS_STORAGE_KEY]: JSON.stringify({
        cache: { locale: 'en', revision: NEW_REVISION, etag: ETAG, checkedAtMs: T0 },
        body: { code: 0, data: { contractId: 'other.v9' } },
      }),
    });
    const store = createStudioPresetsStore({ fetch: fakeFetch([]).fn, storage: corrupt, backendURL: BASE });
    expect(store.current('en'), 'undecodable persisted body -> offline snapshot').toEqual(offline('en'));

    const garbage = memoryStorage({ [STUDIO_PRESETS_STORAGE_KEY]: '{not json' });
    const store2 = createStudioPresetsStore({ fetch: fakeFetch([]).fn, storage: garbage, backendURL: BASE });
    expect(store2.current('zh-Hans'), 'unparsable storage -> offline snapshot (zh-Hans)').toEqual(offline('zh-Hans'));
  });

  it('replacedPersistsAcrossInstances', async () => {
    const storage = memoryStorage();
    const net = fakeFetch([{ status: 200, etag: ETAG, body: serverEnvelope('en') }]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await expect(store.refreshIfNeeded('en', T0)).resolves.toBe('replaced');
    expect(net.calls).toEqual([{ url: `${BASE}/api/studio/presets?locale=en`, ifNoneMatch: null, cache: 'no-store' }]);
    expect(persisted(storage)?.cache).toEqual({ locale: 'en', revision: NEW_REVISION, etag: ETAG, checkedAtMs: T0 });
    expect(store.current('en')?.revision).toBe(NEW_REVISION);

    const reopened = createStudioPresetsStore({ fetch: fakeFetch([]).fn, storage, backendURL: BASE });
    const presets = reopened.current('en');
    expect(presets?.revision, 'new instance reads the persisted body').toBe(NEW_REVISION);
    expect(presets?.styles).toEqual(offline('en').styles);
  });

  it('throttledWithinSixHours', async () => {
    const storage = memoryStorage();
    const net = fakeFetch([
      { status: 200, etag: ETAG, body: serverEnvelope('en') },
      { status: 200, etag: ETAG, body: serverEnvelope('en') },
    ]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await store.refreshIfNeeded('en', T0);
    await expect(store.refreshIfNeeded('en', T0 + SIX_HOURS - 1)).resolves.toBe('throttled');
    expect(net.calls).toHaveLength(1);

    const reopened = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await expect(reopened.refreshIfNeeded('en', T0 + SIX_HOURS - 1), 'throttle survives reopening').resolves.toBe('throttled');
    await expect(reopened.refreshIfNeeded('en', T0 + SIX_HOURS)).resolves.toBe('unchanged');
    expect(net.calls).toHaveLength(2);
    expect(net.calls[1]?.ifNoneMatch).toBe(ETAG);
    expect(persisted(storage)?.cache.checkedAtMs).toBe(T0 + SIX_HOURS);
  });

  it('notModifiedKeepsBody', async () => {
    const storage = memoryStorage();
    const net = fakeFetch([{ status: 200, etag: ETAG, body: serverEnvelope('en') }, { status: 304 }]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await store.refreshIfNeeded('en', T0);
    const bodyBefore = persisted(storage)?.body;

    await expect(store.refreshIfNeeded('en', T0 + SIX_HOURS)).resolves.toBe('not_modified');
    expect(net.calls[1]?.ifNoneMatch).toBe(ETAG);
    const after = persisted(storage);
    expect(after?.cache).toEqual({ locale: 'en', revision: NEW_REVISION, etag: ETAG, checkedAtMs: T0 + SIX_HOURS });
    expect(after?.body).toEqual(bodyBefore);
    expect(store.current('en')?.revision).toBe(NEW_REVISION);
    await expect(store.refreshIfNeeded('en', T0 + SIX_HOURS + 1), '304 restarts the throttle window').resolves.toBe('throttled');
  });

  it('failureKeepsCache', async () => {
    const storage = memoryStorage();
    const net = fakeFetch([{ status: 200, etag: ETAG, body: serverEnvelope('en') }, 'throw', { status: 500 }, { status: 200, body: { code: 1 } }]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await store.refreshIfNeeded('en', T0);
    const rawBefore = storage.map.get(STUDIO_PRESETS_STORAGE_KEY);

    await expect(store.refreshIfNeeded('en', T0 + SIX_HOURS), 'transport failure').resolves.toBe('failed');
    await expect(store.refreshIfNeeded('en', T0 + SIX_HOURS + 1), 'HTTP 500, checkedAtMs untouched').resolves.toBe('failed');
    await expect(store.refreshIfNeeded('en', T0 + SIX_HOURS + 2), 'undecodable 200').resolves.toBe('invalid');
    expect(net.calls).toHaveLength(4);
    expect(storage.map.get(STUDIO_PRESETS_STORAGE_KEY)).toBe(rawBefore);
    expect(store.current('en')?.revision).toBe(NEW_REVISION);
  });

  it('localeChangeRefetches', async () => {
    const storage = memoryStorage();
    const net = fakeFetch([
      { status: 200, etag: ETAG, body: serverEnvelope('en') },
      { status: 200, etag: '"presets-zh"', body: serverEnvelope('zh-Hant', '2099-01-02.1') },
    ]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await store.refreshIfNeeded('en', T0);
    expect(store.current('zh-Hant'), 'other locale before refetch -> offline snapshot').toEqual(offline('zh-Hant'));

    await expect(store.refreshIfNeeded('zh-Hant', T0 + 1)).resolves.toBe('replaced');
    expect(net.calls[1]).toEqual({
      url: `${BASE}/api/studio/presets?locale=${encodeURIComponent('zh-Hant')}`,
      ifNoneMatch: null,
      cache: 'no-store',
    });
    expect(store.current('zh-Hant')?.revision).toBe('2099-01-02.1');
    expect(store.current('zh-Hant')?.locale).toBe('zh-Hant');
    expect(store.current('en'), 'cache now holds zh-Hant -> en falls back offline').toEqual(offline('en'));
  });

  it('corruptBodyRefetchesWithoutEtag', async () => {
    const freshCache = { locale: 'en', revision: NEW_REVISION, etag: ETAG, checkedAtMs: T0 };
    const corrupt = memoryStorage({
      [STUDIO_PRESETS_STORAGE_KEY]: JSON.stringify({ cache: freshCache, body: { code: 0, data: { contractId: 'other.v9' } } }),
    });
    const net = fakeFetch([{ status: 200, etag: ETAG, body: serverEnvelope('en') }]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage: corrupt, backendURL: BASE });
    await expect(store.refreshIfNeeded('en', T0 + 1), 'undecodable body is planned as no cache').resolves.toBe('replaced');
    expect(net.calls).toEqual([{ url: `${BASE}/api/studio/presets?locale=en`, ifNoneMatch: null, cache: 'no-store' }]);
    expect(store.current('en')?.revision).toBe(NEW_REVISION);
    expect(persisted(corrupt)?.cache).toEqual({ ...freshCache, checkedAtMs: T0 + 1 });

    const missing = memoryStorage({ [STUDIO_PRESETS_STORAGE_KEY]: JSON.stringify({ cache: freshCache }) });
    const net2 = fakeFetch([{ status: 200, etag: ETAG, body: serverEnvelope('en') }]);
    const store2 = createStudioPresetsStore({ fetch: net2.fn, storage: missing, backendURL: BASE });
    await expect(store2.refreshIfNeeded('en', T0 + 2), 'missing body, same revision -> replaced, not unchanged').resolves.toBe('replaced');
    expect(net2.calls[0]?.ifNoneMatch).toBeNull();
    expect(store2.current('en')?.revision).toBe(NEW_REVISION);
  });

  it('concurrentRefreshSharesOneRequest', async () => {
    const storage = memoryStorage();
    const urls: string[] = [];
    const gates: Array<(res: Response) => void> = [];
    let active = 0;
    let maxActive = 0;
    const gated = (async (input: RequestInfo | URL) => {
      urls.push(String(input));
      active += 1;
      maxActive = Math.max(maxActive, active);
      const res = await new Promise<Response>((resolve) => gates.push(resolve));
      active -= 1;
      return res;
    }) as typeof fetch;
    const flush = async () => {
      for (let i = 0; i < 10; i += 1) await Promise.resolve();
    };
    const store = createStudioPresetsStore({ fetch: gated, storage, backendURL: BASE });
    const first = store.refreshIfNeeded('en', T0);
    const second = store.refreshIfNeeded('en', T0 + 1);
    const other = store.refreshIfNeeded('zh-Hant', T0 + 2);
    await flush();
    expect(urls, 'one request in flight for the whole store').toEqual([`${BASE}/api/studio/presets?locale=en`]);
    gates.shift()?.(new Response(JSON.stringify(serverEnvelope('en')), { status: 200, headers: { ETag: ETAG } }));
    await expect(first).resolves.toBe('replaced');
    await expect(second, 'the later caller gets the same result').resolves.toBe('replaced');
    await flush();
    expect(urls).toHaveLength(2);
    gates.shift()?.(new Response(JSON.stringify(serverEnvelope('zh-Hant', '2099-01-02.1')), { status: 200 }));
    await expect(other).resolves.toBe('replaced');
    expect(maxActive).toBe(1);
    expect(store.current('zh-Hant')?.revision).toBe('2099-01-02.1');
  });

  it('oversizedBodyIsInvalid', async () => {
    // 600k two-byte characters: under 1 MiB of UTF-16 units, over 1 MiB of UTF-8 bytes.
    const storage = memoryStorage();
    const big = { ...serverEnvelope('en'), padding: 'é'.repeat(600_000) };
    const net = fakeFetch([{ status: 200, etag: ETAG, body: big }]);
    const store = createStudioPresetsStore({ fetch: net.fn, storage, backendURL: BASE });
    await expect(store.refreshIfNeeded('en', T0), 'body over 1 MiB (UTF-8 bytes)').resolves.toBe('invalid');
    expect(storage.map.has(STUDIO_PRESETS_STORAGE_KEY)).toBe(false);
    expect(store.current('en')).toEqual(offline('en'));

    const small = { ...serverEnvelope('en'), padding: 'a'.repeat(600_000) };
    const net2 = fakeFetch([{ status: 200, etag: ETAG, body: small }]);
    const store2 = createStudioPresetsStore({ fetch: net2.fn, storage: memoryStorage(), backendURL: BASE });
    await expect(store2.refreshIfNeeded('en', T0), 'same length in ASCII stays under 1 MiB').resolves.toBe('replaced');
  });
});
