// @vitest-environment node
/**
 * Shared fixture image_response_samples.v1 fetchPolicy + fetchCases: the Web URL
 * image fetcher with an injected fake fetch, one scenario per fixture case name.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { STUDIO_IMAGE_FETCH_POLICY, fetchStudioImage, type StudioImageFetchOptions } from '../image-fetch';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();
const CONTRACTS = resolve(ROOT, 'shared/model-contracts');

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(CONTRACTS, name), 'utf8')) as T;
}

interface Fixture {
  contractId: string;
  fetchPolicy: unknown;
  decodeCases: Array<{ name: string; b64: string }>;
  fetchCases: Array<{
    name: string;
    expect: { ok: true; mime: string; width: number; height: number } | { ok: false; failure: string };
  }>;
}

const fixture = readJson<Fixture>('image_response_samples.v1/index.json');

function decodeBytes(name: string): Uint8Array {
  const b64 = fixture.decodeCases.find((c) => c.name === name)!.b64;
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

const PNG = decodeBytes('png_rgba_3x2');
const HTML = decodeBytes('not_an_image_html');

/** Body stream that delivers the chunks and then either closes or hangs forever. */
function streamOf(chunks: Uint8Array[], hang = false): ReadableStream<Uint8Array> {
  let i = 0;
  return new ReadableStream<Uint8Array>({
    pull(controller) {
      if (i < chunks.length) {
        controller.enqueue(chunks[i++]);
        return undefined;
      }
      if (hang) return new Promise<void>(() => undefined);
      controller.close();
      return undefined;
    },
  });
}

function fakeResponse(
  status: number,
  body: ReadableStream<Uint8Array> | null,
  headers: Record<string, string> = {},
): Response {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers(headers),
    body,
  } as unknown as Response;
}

interface Scenario {
  url?: string;
  urls?: string[];
  options?: Omit<StudioImageFetchOptions, 'fetch'>;
  fetch: (url: string, init?: RequestInit) => Promise<Response>;
  expectNoRequest?: boolean;
}

const SMALL_LIMIT = PNG.byteLength + 16;

const scenarios: Record<string, Scenario> = {
  fetch_ok_png: {
    fetch: async () => fakeResponse(200, streamOf([PNG.slice(0, 10), PNG.slice(10)]), { 'Content-Type': 'image/png' }),
  },
  fetch_ok_octet_stream_content_type: {
    fetch: async () => fakeResponse(200, streamOf([PNG]), { 'Content-Type': 'application/octet-stream' }),
  },
  fetch_http_404: {
    fetch: async () => fakeResponse(404, streamOf([PNG])),
  },
  fetch_connection_error: {
    fetch: async () => {
      throw new TypeError('fetch failed');
    },
  },
  fetch_timeout: {
    options: { timeoutMs: 30 },
    fetch: async () => fakeResponse(200, streamOf([PNG.slice(0, 10)], true)),
  },
  fetch_content_length_over_limit: {
    // A valid small PNG body proves the declared length alone rejects it.
    options: { maxBytes: SMALL_LIMIT },
    fetch: async () => fakeResponse(200, streamOf([PNG]), { 'Content-Length': String(SMALL_LIMIT + 1) }),
  },
  fetch_body_over_limit_without_length: {
    // PNG header followed by padding up to maxBytes + 1: decodable if the limit were ignored.
    options: { maxBytes: SMALL_LIMIT },
    fetch: async () => {
      const padded = new Uint8Array(SMALL_LIMIT + 1);
      padded.set(PNG);
      return fakeResponse(200, streamOf([padded.slice(0, 40), padded.slice(40)]));
    },
  },
  fetch_body_not_an_image: {
    fetch: async () => fakeResponse(200, streamOf([HTML]), { 'Content-Type': 'image/png' }),
  },
  fetch_non_http_scheme: {
    urls: ['ftp://cdn.example/a.png', 'file:///etc/passwd'],
    fetch: async () => fakeResponse(200, streamOf([PNG])),
    expectNoRequest: true,
  },
};

describe('image_response_samples.v1', () => {
  describe('fetchPolicy', () => {
    it('STUDIO_IMAGE_FETCH_POLICY equals the fixture policy', () => {
      expect(fixture.contractId).toBe('image_response_samples.v1');
      expect(STUDIO_IMAGE_FETCH_POLICY).toEqual(fixture.fetchPolicy);
    });
  });

  describe('fetchCases', () => {
    it('has a scenario for every fixture case and no extra ones', () => {
      expect(Object.keys(scenarios).sort()).toEqual(fixture.fetchCases.map((c) => c.name).sort());
    });

    for (const c of fixture.fetchCases) {
      it(c.name, async () => {
        const scenario = scenarios[c.name];
        expect(scenario).toBeDefined();
        const fakeFetch = vi.fn(scenario.fetch);
        const urls = scenario.urls ?? [scenario.url ?? 'https://cdn.example/image.png'];
        for (const url of urls) {
          const outcome = await fetchStudioImage(url, {
            ...scenario.options,
            fetch: fakeFetch as unknown as typeof fetch,
          });
          if (c.expect.ok) {
            expect(outcome).toEqual({
              ok: true,
              bytes: PNG,
              mime: c.expect.mime,
              width: c.expect.width,
              height: c.expect.height,
            });
          } else {
            expect(outcome).toEqual({ ok: false, failure: c.expect.failure });
          }
        }
        if (scenario.expectNoRequest) {
          expect(fakeFetch).not.toHaveBeenCalled();
        } else {
          expect(fakeFetch).toHaveBeenCalledTimes(urls.length);
          const init = fakeFetch.mock.calls[0][1];
          expect(init?.signal).toBeInstanceOf(AbortSignal);
        }
      });
    }
  });
});
