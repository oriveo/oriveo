/**
 * Style preset sample cache: fixture studio_presets.v1.json
 * clientCases.sampleCache (resolveUrl / verify / policy) plus cache behaviour
 * with an injected downloader; storage is the production blob-cache over
 * fake-indexeddb (in-memory storage only where a test counts storage calls).
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { pruneBlobs, readBlob, writeBlob } from '../../../infra/storage/blob-cache';
import {
  createPresetSampleCache,
  PRESET_SAMPLE_MAX_BYTES,
  resolvePresetSampleUrl,
  verifyPresetSample,
  type PresetSampleStorage,
} from '../preset-sample-cache';
import type { StudioPresetSample } from '../presets';

const ROOT = resolve(__dirname, '../../../../../../../..');
const CONTRACTS = resolve(ROOT, String.fromCharCode(0x5171, 0x4eab), 'studio-contracts');

interface SampleCacheCases {
  policy: { maxBytes: number };
  resolveUrl: Array<{ caseId: string; input: { baseUrl: string; url: string }; expect: string | null }>;
  verify: Array<{ caseId: string; input: { bytesBase64: string; sha256: string }; expect: string }>;
}

const fixture = JSON.parse(readFileSync(resolve(CONTRACTS, 'studio_presets.v1.json'), 'utf8')) as {
  clientCases: { sampleCache: SampleCacheCases };
};
const cases = fixture.clientCases.sampleCache;

const BASE = 'https://api.example.com';
const HELLO = new TextEncoder().encode('hello');
const HELLO_SHA = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824';
const WORLD = new TextEncoder().encode('world');

function decodeBase64(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

function sample(overrides: Partial<StudioPresetSample> = {}): StudioPresetSample {
  return { url: '/api/studio/presets/samples/r1/a.webp', width: 64, height: 64, sha256: HELLO_SHA, ...overrides };
}

const PREFIX = 'studio-sample:';

async function storedValue(key: string): Promise<unknown> {
  return (await readBlob<unknown>(key))?.value ?? null;
}

class MemoryStorage implements PresetSampleStorage {
  readonly entries = new Map<string, unknown>();
  readonly removed: string[] = [];
  readonly reads: string[] = [];
  async read(key: string): Promise<unknown> {
    this.reads.push(key);
    return this.entries.get(key) ?? null;
  }
  async write(key: string, bytes: Uint8Array): Promise<boolean> {
    this.entries.set(key, bytes);
    return true;
  }
  async remove(key: string): Promise<void> {
    this.removed.push(key);
    this.entries.delete(key);
  }
  async prune(keep: readonly string[]): Promise<number> {
    const keepSet = new Set(keep);
    let count = 0;
    for (const key of [...this.entries.keys()]) {
      if (!keepSet.has(key)) {
        this.entries.delete(key);
        count += 1;
      }
    }
    return count;
  }
}

function recordingFetcher(bytes: Uint8Array | null) {
  const urls: string[] = [];
  const fetchBytes = async (url: string) => {
    urls.push(url);
    return bytes;
  };
  return { urls, fetchBytes };
}

describe('preset sample cache', () => {
  beforeEach(async () => {
    // Clear every blob-cache entry so tests do not see each other's data.
    await pruneBlobs('', []);
  });

  it('fixtureResolveUrl', () => {
    expect(cases.resolveUrl.length).toBeGreaterThan(0);
    for (const c of cases.resolveUrl) {
      expect(resolvePresetSampleUrl(c.input.baseUrl, c.input.url), c.caseId).toBe(c.expect);
    }
  });

  it('fixtureVerify', async () => {
    expect(cases.verify.length).toBeGreaterThan(0);
    for (const c of cases.verify) {
      expect(await verifyPresetSample(decodeBase64(c.input.bytesBase64), c.input.sha256), c.caseId).toBe(c.expect);
    }
  });

  it('policyMaxBytes', () => {
    expect(PRESET_SAMPLE_MAX_BYTES).toBe(cases.policy.maxBytes);
  });

  it('hitSkipsNetwork', async () => {
    expect(await writeBlob(PREFIX + HELLO_SHA, HELLO)).toBe(true);
    const fetcher = recordingFetcher(WORLD);
    const cache = createPresetSampleCache({ fetchBytes: fetcher.fetchBytes, backendURL: BASE });

    const bytes = await cache.data(sample());

    expect(bytes).toStrictEqual(HELLO);
    expect(fetcher.urls).toStrictEqual([]);
  });

  it('missDownloadsAndStores', async () => {
    const fetcher = recordingFetcher(HELLO);
    const cache = createPresetSampleCache({ fetchBytes: fetcher.fetchBytes, backendURL: BASE });

    const bytes = await cache.data(sample());

    expect(bytes).toStrictEqual(HELLO);
    expect(fetcher.urls).toStrictEqual([`${BASE}/api/studio/presets/samples/r1/a.webp`]);
    expect(await storedValue(PREFIX + HELLO_SHA)).toStrictEqual(HELLO);

    const again = await cache.data(sample());
    expect(again).toStrictEqual(HELLO);
    expect(fetcher.urls).toHaveLength(1);
  });

  it('shaMismatchNotStored', async () => {
    const storage = new MemoryStorage();
    const fetcher = recordingFetcher(WORLD);
    const cache = createPresetSampleCache({ storage, fetchBytes: fetcher.fetchBytes, backendURL: BASE });

    const bytes = await cache.data(sample());

    expect(bytes).toBeNull();
    expect(fetcher.urls).toHaveLength(1);
    expect(storage.entries.size).toBe(0);
  });

  it('unresolvableUrlSkipsNetwork', async () => {
    const storage = new MemoryStorage();
    const fetcher = recordingFetcher(HELLO);
    const cache = createPresetSampleCache({ storage, fetchBytes: fetcher.fetchBytes, backendURL: BASE });

    expect(await cache.data(sample({ url: '//evil.example.com/a.webp' }))).toBeNull();
    expect(await cache.data(sample({ url: 'http://cdn.example.com/a.webp' }))).toBeNull();

    const emptyBase = createPresetSampleCache({ storage, fetchBytes: fetcher.fetchBytes, backendURL: '' });
    expect(await emptyBase.data(sample())).toBeNull();

    expect(fetcher.urls).toStrictEqual([]);
    expect(storage.entries.size).toBe(0);

    // A sha256 that is not 64 lowercase hex chars: null before any storage read or request.
    const badShaStorage = new MemoryStorage();
    const badSha = createPresetSampleCache({ storage: badShaStorage, fetchBytes: fetcher.fetchBytes, backendURL: BASE });
    for (const sha256 of [HELLO_SHA.toUpperCase(), HELLO_SHA.slice(1), `${HELLO_SHA}0`, 'g'.repeat(64), '']) {
      expect(await badSha.data(sample({ sha256 })), sha256).toBeNull();
    }
    expect(badShaStorage.reads).toStrictEqual([]);
    expect(fetcher.urls).toStrictEqual([]);
  });

  it('concurrentSameKeyDownloadsOnce', async () => {
    const storage = new MemoryStorage();
    const urls: string[] = [];
    let release: (value: Uint8Array | null) => void = () => undefined;
    const gate = new Promise<Uint8Array | null>((resolveGate) => {
      release = resolveGate;
    });
    const cache = createPresetSampleCache({
      storage,
      backendURL: BASE,
      fetchBytes: (url) => {
        urls.push(url);
        return gate;
      },
    });

    const first = cache.data(sample());
    const second = cache.data(sample());
    await new Promise((r) => setTimeout(r, 0));
    release(HELLO);
    const [a, b] = await Promise.all([first, second]);

    expect(a).toStrictEqual(HELLO);
    expect(b).toStrictEqual(HELLO);
    expect(urls).toHaveLength(1);
  });

  it('pruneKeepsOnlyGiven', async () => {
    const other = 'a'.repeat(64);
    const stale = 'b'.repeat(64);
    const foreign = 'metadata:catalog';
    await writeBlob(PREFIX + HELLO_SHA, HELLO);
    await writeBlob(PREFIX + other, WORLD);
    await writeBlob(PREFIX + stale, WORLD);
    await writeBlob(foreign, WORLD);
    const cache = createPresetSampleCache({ fetchBytes: recordingFetcher(null).fetchBytes, backendURL: BASE });

    await cache.prune([HELLO_SHA, other]);

    expect(await storedValue(PREFIX + HELLO_SHA)).toStrictEqual(HELLO);
    expect(await storedValue(PREFIX + other)).toStrictEqual(WORLD);
    expect(await storedValue(PREFIX + stale)).toBeNull();
    expect(await storedValue(foreign)).toStrictEqual(WORLD);
  });

  it('unreadableEntryRefetches', async () => {
    // Both a non-bytes value and a zero-byte entry count as unreadable: refetch and overwrite.
    for (const broken of [{ corrupted: true }, new Uint8Array(0)]) {
      await writeBlob(PREFIX + HELLO_SHA, broken);
      const fetcher = recordingFetcher(HELLO);
      const cache = createPresetSampleCache({ fetchBytes: fetcher.fetchBytes, backendURL: BASE });

      const bytes = await cache.data(sample());

      expect(bytes).toStrictEqual(HELLO);
      expect(fetcher.urls).toHaveLength(1);
      expect(await storedValue(PREFIX + HELLO_SHA)).toStrictEqual(HELLO);
    }
  });
});
