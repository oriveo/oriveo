// @vitest-environment node
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { createSearchCatalogLoader } from '../search-catalog-loader';

// Server-side catalog loading: starts from the bundled snapshot, signature-verified adoption, keeps the previous copy on failure, 404 = presets unavailable, one fetch within the TTL.

const REPO_ROOT = join(process.cwd(), '../../..');
const contract = JSON.parse(readFileSync(join(REPO_ROOT, 'shared/search-contracts/search_catalog_contract.v1.json'), 'utf8'));
const TEST_KEYS = { [contract.testKeys.keyId]: contract.testKeys.publicKeyB64 };

const view = (doc: unknown) => new Response(JSON.stringify({ code: 0, data: doc, message: 'ok' }), { status: 200 });

describe('search catalog loader', () => {
  it('production default: the bundled snapshot is adopted with the production public key and used as the fallback when the network fails', async () => {
    const loader = createSearchCatalogLoader({ fetchView: async () => new Response(null, { status: 503 }) });
    const catalog = await loader.get();
    expect(catalog?.source).toBe('builtin');
    expect(catalog?.active.size).toBeGreaterThan(0);
  });

  it('network catalog fails signature verification -> keep the previous copy; same revision = unchanged', async () => {
    const tampered = structuredClone(contract.catalog);
    tampered.services[0].regions[0].host = 'evil.example';
    const responses = [view(tampered), view(contract.catalog)];
    const loader = createSearchCatalogLoader({
      trustedKeys: TEST_KEYS,
      builtin: contract.catalog,
      fetchView: async () => responses.shift()!,
      ttlMs: 0,
    });
    const first = await loader.get();
    expect(first?.source).toBe('builtin');
    expect(first?.active.get('deepseek')?.entry.regions[0].host).toBe('api.deepseek.com');
    const second = await loader.get();
    expect(second).toBe(first);
  });

  it('404 = presets unavailable; an adoptable catalog obtained afterwards restores them', async () => {
    const responses = [new Response(null, { status: 404 }), view(contract.catalog)];
    const loader = createSearchCatalogLoader({
      trustedKeys: TEST_KEYS,
      builtin: null,
      fetchView: async () => responses.shift()!,
      ttlMs: 0,
    });
    expect(await loader.get()).toBeNull();
    const recovered = await loader.get();
    expect(recovered?.source).toBe('network');
    expect([...recovered!.active.keys()]).toContain('deepseek');
  });

  it('404 withdraws the bundled snapshot too; an older server\'s 400 is neither a withdrawal nor lifts one; only a later 200 adoption restores', async () => {
    const responses = [
      new Response(null, { status: 400 }),
      new Response(null, { status: 404 }),
      new Response(null, { status: 400 }),
      new Response(null, { status: 304 }),
      view(contract.catalog),
    ];
    const loader = createSearchCatalogLoader({
      trustedKeys: TEST_KEYS,
      builtin: contract.catalog,
      fetchView: async () => responses.shift()!,
      ttlMs: 0,
    });
    expect((await loader.get())?.source).toBe('builtin');
    expect(await loader.get()).toBeNull();
    expect(await loader.get()).toBeNull();
    expect(await loader.get()).toBeNull();
    // A same-revision (unchanged) result is also a signature-verified 200: lifts the withdrawal
    expect((await loader.get())?.active.has('deepseek')).toBe(true);
  });

  it('no usable catalog at all (snapshot fails verification, network error) = presets unavailable', async () => {
    const loader = createSearchCatalogLoader({
      trustedKeys: {},
      builtin: contract.catalog,
      fetchView: async () => {
        throw new Error('offline');
      },
    });
    expect(await loader.get()).toBeNull();
  });

  it('one fetch within the TTL, concurrent requests are coalesced', async () => {
    let now = 1_000;
    const fetchView = vi.fn(async () => view(contract.catalog));
    const loader = createSearchCatalogLoader({ trustedKeys: TEST_KEYS, builtin: null, fetchView, ttlMs: 60_000, now: () => now });
    await Promise.all([loader.get(), loader.get(), loader.get()]);
    await loader.get();
    expect(fetchView).toHaveBeenCalledTimes(1);
    now += 60_001;
    await loader.get();
    expect(fetchView).toHaveBeenCalledTimes(2);
  });
});
