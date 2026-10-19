import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  notFound: vi.fn(() => {
    throw new Error('NEXT_HTTP_ERROR_FALLBACK;404');
  }),
  /** When non-null, the manifest text read by the entry is replaced with it (the test's own file reads are unaffected). */
  manifestText: null as string | null,
}));

vi.mock('next/navigation', () => ({ notFound: mocks.notFound }));
vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>();
  const readFileSync = ((path: Parameters<typeof actual.readFileSync>[0], ...rest: unknown[]) => {
    if (mocks.manifestText !== null && String(path).endsWith('memory.v1.json')) return mocks.manifestText;
    return (actual.readFileSync as (...args: unknown[]) => unknown)(path, ...rest);
  }) as typeof actual.readFileSync;
  return { ...actual, default: { ...actual, readFileSync }, readFileSync };
});

function manifestPath(): string {
  let dir = resolve(import.meta.dirname);
  for (;;) {
    const candidate = join(dir, 'shared', 'test-fixtures', 'shots', 'memory.v1.json');
    try {
      readFileSync(candidate, 'utf8');
      return candidate;
    } catch {
      const parent = dirname(dir);
      if (parent === dir) throw new Error('memory.v1.json not found');
      dir = parent;
    }
  }
}

/** Hands out a fresh copy each time, so changing it does not affect other cases. */
function loadManifest() {
  return JSON.parse(readFileSync(manifestPath(), 'utf8'));
}

describe('memory shots shared sample manifest', () => {
  let uninstall: (() => void) | null = null;
  afterEach(() => {
    uninstall?.();
    uninstall = null;
    mocks.manifestText = null;
    vi.restoreAllMocks();
  });

  it('shotsManifestPagesMatchImplemented', async () => {
    const { MEMORY_SHOT_PAGES } = await import('./memory-shots-pages');
    const names = (loadManifest().pages as Array<{ name: string }>).map((page) => page.name);
    expect(new Set(names)).toEqual(new Set(MEMORY_SHOT_PAGES));
    expect(names).toHaveLength(MEMORY_SHOT_PAGES.length);
  });

  it('shotsManifestBuildsItemsThroughProduction', async () => {
    const data = await import('./memory-shots-data');
    const { groupMemoryItems, isThisDeviceVersion, visibleMemoryItems } = await import('../../settings/memory/MemoryItemList');
    const manifest = loadManifest();
    expect(data.isCompleteMemoryShotsManifest(manifest)).toBe(true);

    expect(data.memoryShotPlan('memoryStarter', manifest).items).toEqual([]);
    const plan = data.memoryShotPlan('memoryList', manifest);
    expect(plan.items.map((item) => item.id)).toEqual(manifest.items.map((item: { id: string }) => item.id));
    expect(visibleMemoryItems(plan.items)).toHaveLength(17);

    // Production grouping: two conflict pairs (L2 / L3), four groups, and L3 keeps only active / paused.
    const groups = groupMemoryItems(plan.items);
    expect(groups.conflicts.map((pair) => pair.map((item) => item.id))).toEqual([['m-pref-c1', 'm-pref-c2']]);
    expect(groups.episodicConflicts.map(({ newer, older }) => [newer.id, older.id])).toEqual([['m-ep-c2', 'm-ep-c1']]);
    expect(groups.groups.map((group) => [group.category, group.items.length])).toEqual([
      ['about', 2], ['preferences', 3], ['instructions', 2], ['projects', 3],
    ]);
    expect(groups.episodic.map((item) => item.id)).toEqual(['m-ep-1', 'm-ep-2', 'm-ep-3']);
    // The one whose id != conflictGroupId is this device's copy.
    const pair = groups.conflicts[0]!;
    expect(isThisDeviceVersion(pair[1]!, pair, plan.deviceId)).toBe(true);
    expect(isThisDeviceVersion(pair[0]!, pair, plan.deviceId)).toBe(false);

    expect(plan.folders.map((folder) => [folder.id, folder.name])).toEqual([['folder-trip', 'Lisbon trip']]);
    expect(plan.clockMs).toBe(Date.parse(manifest.clock));
    expect(data.memoryShotPlan('memoryEditorL2', manifest).query).toBe('?edit=m-pref-1');
    expect(data.memoryShotPlan('memoryEditorL3', manifest).query).toBe('?edit=m-ep-1');
    expect(data.memoryShotPlan('memoryInbox', manifest).target).toBe('inbox');
  });

  it('shotsManifestRawTooLongHitsProductionLimit', async () => {
    const data = await import('./memory-shots-data');
    const { MemoryItems } = await import('@oriveo/core/context/memory-items');
    const manifest = loadManifest();
    const plan = data.memoryShotPlan('memoryRaw', manifest);
    expect(plan.drive.kind).toBe('rawTooLong');
    // A manifest that omits createdAt means the contract default null: production listOrder puts pinned first, then by id; raw line 3 is m-about-2 (same as iOS / Android).
    expect(MemoryItems.rawRender(plan.items).split('\n').slice(0, 3)).toEqual([
      "I'm a product designer based in Berlin.", '---', 'I have a dog named Miso.',
    ]);
    const text = plan.drive.kind === 'rawTooLong' ? plan.drive.text : '';
    const result = MemoryItems.rawApply({ items: plan.items, text, newIds: Array.from({ length: 40 }, (_, i) => `n-${i}`) });
    expect(result).toEqual({ error: 'tooLong', index: manifest.pages.find((p: { name: string }) => p.name === 'memoryRaw').preset.rawTooLongAt });
  });

  it('shotsManifestCandidatesReadByProductionRepository', async () => {
    const fence = await import('../relay-shots/relay-shots-fence');
    uninstall = fence.installRelayShotsFence();
    const data = await import('./memory-shots-data');
    const { createMemoryCandidateRepository } = await import('../../../lib/core/memory/memory-candidate-repository');
    const { getActiveUIDSync } = await import('../../../lib/infra/storage/partition');
    const manifest = loadManifest();
    const plan = data.memoryShotPlan('memoryInbox', manifest);
    const store = { getState: () => ({}), setState: vi.fn() } as never;
    await data.applyMemoryShotPlan(plan, store);
    const repository = createMemoryCandidateRepository({
      uid: getActiveUIDSync(),
      items: { list: async () => plan.items, createFromDraft: vi.fn() } as never,
    });
    const pending = await repository.pending(plan.clockMs);
    // decision / event candidates are episodic; both layers are read from the production repository (createdAtMs descending).
    const newestFirst = [...manifest.candidates as Array<{ content: string; createdAt: string }>]
      .sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
    expect(pending.map((c) => c.content)).toEqual(newestFirst.map((c) => c.content));
    expect(pending.map((c) => c.proposedLayer)).toEqual(['semantic', 'episodic', 'semantic']);
  });

  it('shotsManifestUnreadableRefuses', async () => {
    const { default: MemoryShotsPage } = await import('./[page]/page');
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    const open = () => MemoryShotsPage({ params: Promise.resolve({ page: 'memoryList' }) });
    const withoutItems = loadManifest();
    delete withoutItems.items;
    const withoutPage = loadManifest();
    withoutPage.pages = withoutPage.pages.filter((page: { name: string }) => page.name !== 'memoryList');

    for (const text of ['{ not json', JSON.stringify(withoutItems), JSON.stringify(withoutPage)]) {
      errors.mockClear();
      mocks.manifestText = text;
      await expect(open()).rejects.toThrow('NEXT_HTTP_ERROR_FALLBACK;404');
      expect(errors.mock.calls.some((call) => String(call[0]).includes('shots manifest'))).toBe(true);
    }
  });
});
