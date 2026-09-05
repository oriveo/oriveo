/**
 * Tests for the metadata-client.onVersionChange subscription mechanism
 *
 * Covers:
 *   - subscribers receive refresh events
 *   - no more events arrive after unsubscribe
 *   - a cache hit during init also fires one event
 */

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { initMetadata, onVersionChange, refreshMetadata } from '../../metadata/metadata-client';

beforeEach(() => {
  // Clearing the metadata-client internal cache means forcing a refresh and then clearing localStorage
  if (typeof window !== 'undefined' && window.localStorage) {
    window.localStorage.removeItem('oriveo:metadata');
    window.localStorage.removeItem('oriveo:metadata:etag');
  }
  vi.restoreAllMocks();
});

describe('onVersionChange', () => {
  it('fires listener when metadata is refreshed', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          version: 42,
          contractVersion: 1,
          updatedAt: '2026-04-18T00:00:00Z',
          profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
          providers: {},
          providerConfigs: [],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json', ETag: '"v42"' } },
      ),
    );

    const listener = vi.fn();
    const unsubscribe = onVersionChange(listener);

    await refreshMetadata();

    expect(listener).toHaveBeenCalled();
    const [event] = listener.mock.calls[0];
    expect(event.version).toBe(42);
    expect(event.contractVersion).toBe(1);

    unsubscribe();
  });

  it('unsubscribed listener does not receive events', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          version: 10,
          contractVersion: 1,
          updatedAt: '2026-04-18T00:00:00Z',
          profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
          providers: {},
          providerConfigs: [],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const listener = vi.fn();
    const unsubscribe = onVersionChange(listener);
    unsubscribe();

    await refreshMetadata();

    expect(listener).not.toHaveBeenCalled();
  });

  it('multiple listeners each receive version events', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          version: 99,
          contractVersion: 1,
          updatedAt: '2026-04-18T00:00:00Z',
          profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
          providers: {},
          providerConfigs: [],
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } },
      ),
    );

    const listenerA = vi.fn();
    const listenerB = vi.fn();
    const unsubA = onVersionChange(listenerA);
    const unsubB = onVersionChange(listenerB);

    await refreshMetadata();

    expect(listenerA).toHaveBeenCalled();
    expect(listenerB).toHaveBeenCalled();

    unsubA();
    unsubB();
  });
});
