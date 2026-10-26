/**
 * @vitest-environment jsdom
 *
 * onVersionChange deduplication, so the 304 path does not trigger pointless UI recomputation.
 *
 * The policy:
 *   - the first init and any 200 response emit a version event;
 *   - a following 304 means the content is unchanged, so an identical `version` skips the emit;
 *   - a 200 with a new contractVersion must emit even when the version happens to match;
 *   - __resetVersionListenersForTest exists to isolate listeners between test cases.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

function buildPayload(contractVersion: number, version: number) {
  return {
    version,
    contractVersion,
    updatedAt: '2026-04-18T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    providers: {},
    providerConfigs: [],
  };
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

describe('metadata onVersionChange dedup', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.restoreAllMocks();
    localStorage.clear();
  });
  afterEach(async () => {
    await restoreMetadataInstance();
    localStorage.clear();
  });

  it('skips emit on 304 when version+contractVersion have not changed since last emit', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch');

    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(1, 42)), {
        status: 200,
        headers: { 'Content-Type': 'application/json', ETag: '"v42"' },
      }),
    );

    const metadataModule = await importMetadataClient();
    const { onVersionChange, refreshMetadata, __resetVersionListenersForTest } = metadataModule;

    __resetVersionListenersForTest();

    const listener = vi.fn();
    onVersionChange(listener);

    await refreshMetadata(); // 200 → emit once
    expect(listener).toHaveBeenCalledTimes(1);

    // A 304 carries no new version, so it must not look like a change.
    fetchMock.mockResolvedValueOnce(
      new Response(null, { status: 304 }),
    );
    await refreshMetadata();

    // dedup  
    expect(listener).toHaveBeenCalledTimes(1);
  });

  it('emits on 200 when contractVersion bumps even if version stays the same', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch');

    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(1, 100)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    const { onVersionChange, refreshMetadata, __resetVersionListenersForTest } =
      await importMetadataClient();
    __resetVersionListenersForTest();

    const listener = vi.fn();
    onVersionChange(listener);
    await refreshMetadata();
    expect(listener).toHaveBeenCalledTimes(1);

    // The backend raises contractVersion while version stays the same, a theoretical edge case.
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(2, 100)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    await refreshMetadata();
    expect(listener).toHaveBeenCalledTimes(2);
  });

  it('__resetVersionListenersForTest clears subscribers across test boundaries', async () => {
    const { onVersionChange, __resetVersionListenersForTest } =
      await importMetadataClient();

    const listener = vi.fn();
    onVersionChange(listener);
    __resetVersionListenersForTest();

    // A listener removed before the refresh must not be called by it.
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(1, 1)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    const { refreshMetadata } = await importMetadataClient();
    await refreshMetadata();

    expect(listener).not.toHaveBeenCalled();
  });
});
