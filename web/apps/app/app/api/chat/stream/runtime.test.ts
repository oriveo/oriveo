import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { __resetRuntimeMetadataCache, getRuntimeMetadata } from './runtime';

/**
 * This path runs on every message send, so its caching discipline is user-visible: after the TTL
 * expires the first message waits for this request before streaming starts. The three invariants
 * below are the lean view, the conditional request and in-flight deduplication.
 */
const SNAPSHOT = {
  version: 1,
  providers: {},
  profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: { templates: {} } },
};

function jsonResponse(body: unknown, etag: string) {
  return new Response(JSON.stringify({ data: body }), {
    status: 200,
    headers: { 'Content-Type': 'application/json', ETag: etag },
  });
}

describe('getRuntimeMetadata caching', () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    __resetRuntimeMetadataCache();
    fetchSpy = vi.spyOn(globalThis, 'fetch') as never;
  });

  afterEach(() => {
    fetchSpy.mockRestore();
    __resetRuntimeMetadataCache();
    vi.useRealTimers();
  });

  it('requests the lean view, since request building never reads the fields the full view adds', async () => {
    fetchSpy.mockResolvedValue(jsonResponse(SNAPSHOT, '"m1"'));
    await getRuntimeMetadata();

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(String(fetchSpy.mock.calls[0][0])).toBe('https://api.oriveoai.com/api/metadata?view=lean');
  });

  it('serves from memory inside the TTL without another request', async () => {
    fetchSpy.mockResolvedValue(jsonResponse(SNAPSHOT, '"m1"'));
    const first = await getRuntimeMetadata();
    const second = await getRuntimeMetadata();

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(second).toBe(first);
  });

  it('sends If-None-Match once the TTL expires and reuses the snapshot on 304 instead of downloading it again', async () => {
    const now = vi.spyOn(Date, 'now');
    now.mockReturnValue(1_000_000);
    fetchSpy.mockResolvedValueOnce(jsonResponse(SNAPSHOT, '"m1"'));
    const first = await getRuntimeMetadata();

    // Step past the five-minute TTL.
    now.mockReturnValue(1_000_000 + 5 * 60 * 1000 + 1);
    fetchSpy.mockResolvedValueOnce(new Response(null, { status: 304 }));
    const revalidated = await getRuntimeMetadata();

    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(fetchSpy.mock.calls[1][1]).toMatchObject({
      headers: expect.objectContaining({ 'If-None-Match': '"m1"' }),
    });
    // A 304 hands back the same object with a renewed TTL, so the next call issues no request.
    expect(revalidated).toBe(first);
    await getRuntimeMetadata();
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it('shares one in-flight request across calls that arrive the instant the TTL expires', async () => {
    let release: (value: Response) => void = () => {};
    fetchSpy.mockReturnValueOnce(new Promise<Response>((resolve) => { release = resolve; }) as never);

    const inflight = [getRuntimeMetadata(), getRuntimeMetadata(), getRuntimeMetadata()];
    release(jsonResponse(SNAPSHOT, '"m1"'));
    const results = await Promise.all(inflight);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(results[1]).toBe(results[0]);
    expect(results[2]).toBe(results[0]);
  });

  it('keeps the previous snapshot when the request fails, rather than interrupting the chat', async () => {
    fetchSpy.mockResolvedValueOnce(jsonResponse(SNAPSHOT, '"m1"'));
    const first = await getRuntimeMetadata();

    __resetRuntimeMetadataCache();
    fetchSpy.mockRejectedValueOnce(new Error('network down'));
    expect(await getRuntimeMetadata()).toBeNull();

    expect(first).not.toBeNull();
  });
});
