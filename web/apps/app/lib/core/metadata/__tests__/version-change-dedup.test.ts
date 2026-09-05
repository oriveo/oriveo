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

describe('metadata onVersionChange dedup', () => {
  beforeEach(() => {
    vi.resetModules();
    vi.restoreAllMocks();
    localStorage.clear();
  });
  afterEach(() => {
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

    const metadataModule = await import('../metadata-client');
    const { onVersionChange, refreshMetadata, __resetVersionListenersForTest } = metadataModule;

    __resetVersionListenersForTest();

    const listener = vi.fn();
    onVersionChange(listener);

    await refreshMetadata(); // 200 → emit once
    expect(listener).toHaveBeenCalledTimes(1);

    //   304 
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
      await import('../metadata-client');
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
      await import('../metadata-client');

    const listener = vi.fn();
    onVersionChange(listener);
    __resetVersionListenersForTest();

    //   emit  
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(
      new Response(JSON.stringify(buildPayload(1, 1)), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      }),
    );
    const { refreshMetadata } = await import('../metadata-client');
    await refreshMetadata();

    expect(listener).not.toHaveBeenCalled();
  });
});
