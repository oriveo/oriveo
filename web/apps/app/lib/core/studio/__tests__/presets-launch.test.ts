/**
 * Studio presets launch: hidden entry skips the refresh; a visible entry refreshes
 * with the resolved preset locale and, only when the presets were replaced, prunes
 * the sample cache to the current style samples.
 * Real Store + fake fetch + in-memory storage; the prune target is a spy.
 */
import { describe, expect, it } from 'vitest';
import { bundledStudioPresetsSnapshot, localizeStudioPresets, resolveStudioPresetLocale } from '../presets';
import { createStudioPresetsStore } from '../presets-store';
import { runStudioPresetsLaunch } from '../presets-launch';

const BASE = 'https://backend.example.test';
const T0 = 1_800_000_000_000;
const NEW_REVISION = '2099-01-01.1';
const SHA_A = 'a'.repeat(64);
const SHA_B = 'b'.repeat(64);

type Reply = { status: number; etag?: string; body?: unknown } | 'throw';

function fakeFetch(replies: Reply[]) {
  const calls: string[] = [];
  const fn = async (input: RequestInfo | URL): Promise<Response> => {
    calls.push(String(input));
    const reply = replies.shift();
    if (!reply) throw new Error(`unexpected fetch #${calls.length}`);
    if (reply === 'throw') throw new TypeError('network down');
    const headers = new Headers();
    if (reply.etag) headers.set('ETag', reply.etag);
    const text = reply.body === undefined ? null : JSON.stringify(reply.body);
    return new Response(reply.status === 304 ? null : text, { status: reply.status, headers });
  };
  return { fn: fn as typeof fetch, calls };
}

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => {
      map.set(key, value);
    },
  };
}

function pruneSpy() {
  const calls: string[][] = [];
  return {
    calls,
    prune: async (keep: readonly string[]) => {
      calls.push([...keep]);
    },
  };
}

// Server-shaped envelope with a newer revision; the first two styles carry samples (SHA_A twice, SHA_B once).
function serverEnvelope(tag: string) {
  const env = localizeStudioPresets(bundledStudioPresetsSnapshot(), tag);
  const sample = (sha256: string) => ({ url: `/static/studio/${sha256}.webp`, width: 512, height: 512, sha256 });
  const styles = env.data.styles.map((s, i) => {
    if (i === 0) return { ...s, sample: { ...s.sample, ...sample(SHA_A) } };
    if (i === 1) return { ...s, sample: { ...s.sample, ...sample(SHA_B) } };
    if (i === 2) return { ...s, sample: { ...s.sample, ...sample(SHA_A) } };
    return s;
  });
  return { ...env, data: { ...env.data, revision: NEW_REVISION, styles } };
}

function setup(replies: Reply[]) {
  const fetch = fakeFetch(replies);
  const store = createStudioPresetsStore({ fetch: fetch.fn, storage: memoryStorage(), backendURL: BASE, now: () => T0 });
  return { fetch, store, cache: pruneSpy() };
}

describe('studio presets launch', () => {
  it('hiddenEntrySkipsRefresh', async () => {
    const { fetch, store, cache } = setup([]);
    const outcome = await runStudioPresetsLaunch({ entryVisible: false, appLanguageTag: 'en', store, sampleCache: cache });
    expect(outcome).toBeNull();
    expect(fetch.calls).toEqual([]);
    expect(cache.calls).toEqual([]);
  });

  it('visibleEntryRefreshesWithLocale', async () => {
    const { fetch, store, cache } = setup([{ status: 503 }]);
    const locale = resolveStudioPresetLocale(bundledStudioPresetsSnapshot().locales, 'zh-TW');
    expect(locale).toBe('zh-Hant');
    const outcome = await runStudioPresetsLaunch({ entryVisible: true, appLanguageTag: 'zh-TW', store, sampleCache: cache });
    expect(outcome).toBe('failed');
    expect(fetch.calls).toEqual([`${BASE}/api/studio/presets?locale=zh-Hant`]);
    expect(cache.calls).toEqual([]);
  });

  it('replacedPrunesToCurrentSamples', async () => {
    const { fetch, store, cache } = setup([{ status: 200, etag: '"r2"', body: serverEnvelope('en') }]);
    const outcome = await runStudioPresetsLaunch({ entryVisible: true, appLanguageTag: 'en-US', store, sampleCache: cache });
    expect(outcome).toBe('replaced');
    expect(fetch.calls).toEqual([`${BASE}/api/studio/presets?locale=en`]);
    const current = store.current('en');
    expect(current?.revision).toBe(NEW_REVISION);
    const expected = [...new Set((current?.styles ?? []).flatMap((s) => (s.sample ? [s.sample.sha256] : [])))];
    expect(expected).toEqual([SHA_A, SHA_B]);
    expect(cache.calls).toEqual([expected]);

    // Replaced but current() is null: nothing to keep, so the cache must not be pruned to empty.
    const nullCache = pruneSpy();
    const nullStore = { current: () => null, refreshIfNeeded: async () => 'replaced' as const };
    const nullOutcome = await runStudioPresetsLaunch({
      entryVisible: true,
      appLanguageTag: 'en',
      store: nullStore,
      sampleCache: nullCache,
    });
    expect(nullOutcome).toBe('replaced');
    expect(nullCache.calls).toEqual([]);
  });

  it('nonReplacedKeepsSamples', async () => {
    const { fetch, store, cache } = setup([{ status: 200, etag: '"r2"', body: serverEnvelope('en') }, 'throw']);
    await runStudioPresetsLaunch({ entryVisible: true, appLanguageTag: 'en', store, sampleCache: cache });
    expect(cache.calls).toHaveLength(1);
    // Within the 6-hour window: throttled, no request, cache untouched.
    expect(await runStudioPresetsLaunch({ entryVisible: true, appLanguageTag: 'en', store, sampleCache: cache })).toBe('throttled');
    expect(fetch.calls).toHaveLength(1);
    // Another locale is not throttled: the request fails and the cache is left alone.
    expect(await runStudioPresetsLaunch({ entryVisible: true, appLanguageTag: 'ja', store, sampleCache: cache })).toBe('failed');
    expect(fetch.calls).toEqual([`${BASE}/api/studio/presets?locale=en`, `${BASE}/api/studio/presets?locale=ja`]);
    expect(cache.calls).toHaveLength(1);
  });
});
