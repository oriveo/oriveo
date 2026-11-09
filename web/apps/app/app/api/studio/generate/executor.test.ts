// @vitest-environment node
/**
 * runStudioGenerate: every real sample
 * of image_response_samples.v1 (placeholder base64 swapped for a decodable image
 * of the observed size) drives a fake upstream through to the aggregate; local
 * rejects never reach the upstream; batches run concurrently with
 * summed usage, transport failures retry once only before connecting, and a
 * dropped client cancels the whole round.
 */
import { readFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { resolve } from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import { decodeImageInfo, type ImageMaterializeOutcome } from '../../../../lib/core/studio/image-response';
import { runStudioGenerate, type StudioGenerateDeps, type StudioGenerateInput } from './executor';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();
// Shared contracts directory name, spelled by code point to keep this file ASCII.
const CONTRACTS = resolve(ROOT, 'shared', 'model-contracts');
const SAMPLES_DIR = resolve(CONTRACTS, 'image_response_samples.v1');
const BASE_URL = 'https://api.example.com/v1';
const PLACEHOLDER = /<base64 bytes=\d+ sha256=[^>]+>/g;

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

interface ObservedImage {
  mime: string;
  width: number;
  height: number;
}

interface SampleFile {
  meta: { route: string; provider: string; op: 'generate' | 'edit'; http: number };
  observed: { images: ObservedImage[] };
  response: unknown;
}

const fixture = readJson<{
  samples: Array<{ file: string; nRequested: number; expect: { images: { kind: string }[]; result: string } }>;
}>(resolve(SAMPLES_DIR, 'index.json'));
const normalization = readJson<{ profiles: Record<string, Record<string, unknown>> }>(
  resolve(CONTRACTS, 'image_param_normalization.v1.json'),
);

/** Profile per route; openai_images edit picks the provider's own edit transport. */
function profileRef(route: string, provider: string, op: string): string {
  switch (route) {
    case 'openai_images':
      if (op === 'edit' && provider === 'siliconFlow') return 'siliconflow_qwen_edit';
      if (op === 'edit' && provider === 'togetherAI') return 'together_flux_kontext';
      return 'openai_gpt_image';
    case 'xai_images':
      return 'xai_grok_imagine';
    case 'gemini_generate_content':
      return 'gemini_flash_image';
    case 'chat_modalities':
      return 'openrouter_gemini_chat';
    case 'openrouter_images':
      return 'openrouter_gpt_images';
    case 'dashscope_multimodal':
      return 'dashscope_qwen_image';
    case 'minimax_image_generation':
      return 'minimax_image01';
    default:
      throw new Error(`no profile for route ${route}`);
  }
}

function u32be(value: number): number[] {
  return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
}

function u16be(value: number): number[] {
  return [(value >>> 8) & 0xff, value & 0xff];
}

/** Smallest header-only image the decoder accepts, with the given mime and size. */
function imageBytes(image: ObservedImage): Uint8Array {
  if (image.mime === 'image/png') {
    return Uint8Array.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
      ...u32be(13), 0x49, 0x48, 0x44, 0x52,
      ...u32be(image.width), ...u32be(image.height),
      8, 6, 0, 0, 0, 0, 0, 0, 0,
    ]);
  }
  if (image.mime === 'image/jpeg') {
    return Uint8Array.from([
      0xff, 0xd8, 0xff, 0xc0, ...u16be(17), 8,
      ...u16be(image.height), ...u16be(image.width),
      3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xff, 0xd9,
    ]);
  }
  throw new Error(`no synthetic image for ${image.mime}`);
}

const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64');
const fromB64 = (data: string) => new Uint8Array(Buffer.from(data, 'base64'));

function outcomeOf(bytes: Uint8Array): ImageMaterializeOutcome {
  const info = decodeImageInfo(bytes);
  if (!info) throw new Error('synthetic image does not decode');
  return { ok: true, bytes, ...info };
}

function makeDeps(overrides: Partial<StudioGenerateDeps> = {}, upstream?: () => Response) {
  const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
    upstream ? upstream() : new Response('{}', { status: 200 }),
  );
  const assertUrl = vi.fn(async (_url: string) => {});
  const fetchImage = vi.fn(async (_url: string, _signal: AbortSignal): Promise<ImageMaterializeOutcome> => {
    throw new Error('fetchImage not expected');
  });
  const deps: StudioGenerateDeps = {
    fetch: fetchMock as unknown as typeof fetch,
    assertUrl,
    fetchImage,
    signal: new AbortController().signal,
    ...overrides,
  };
  return { deps, fetchMock, assertUrl, fetchImage };
}

const PNG_REF = imageBytes({ mime: 'image/png', width: 64, height: 64 });

function baseInput(overrides: Partial<StudioGenerateInput> = {}): StudioGenerateInput {
  return {
    providerKind: 'openai',
    apiKey: 'test-key',
    baseURL: BASE_URL,
    modelId: 'gpt-image-2',
    profile: normalization.profiles.openai_gpt_image,
    operation: 'generate',
    prompt: { userPrompt: 'a red apple', references: [] },
    params: {},
    advanced: null,
    images: [],
    ...overrides,
  };
}

const editInput = (overrides: Partial<StudioGenerateInput> = {}) =>
  baseInput({
    operation: 'edit',
    prompt: { userPrompt: 'make it blue', references: [{ n: 1, role: 'base' }] },
    images: [{ slot: 1, role: 'base', mime: 'image/png', data: PNG_REF }],
    ...overrides,
  });

describe('runStudioGenerate', () => {
  describe('golden samples', () => {
    for (const sample of fixture.samples) {
      it(sample.file, async () => {
        const file = readJson<SampleFile>(resolve(SAMPLES_DIR, sample.file));
        const { route, provider, op, http } = file.meta;
        const modelId = sample.file.split('.').slice(2, -2).join('.');
        const observed = file.observed.images;
        const served = observed.length > 0 ? b64(imageBytes(observed[0]!)) : '';
        const text = JSON.stringify(file.response).replace(PLACEHOLDER, served);

        const fetchImage = vi.fn(async () => outcomeOf(imageBytes(observed[0]!)));
        const { deps, fetchMock } = makeDeps(
          { fetchImage },
          () => new Response(text, { status: http, headers: { 'Content-Type': 'application/json' } }),
        );
        const input = (op === 'edit' ? editInput : baseInput)({
          providerKind: provider,
          modelId,
          profile: normalization.profiles[profileRef(route, provider, op)],
        });

        const result = await runStudioGenerate(input, deps);

        expect(fetchMock).toHaveBeenCalledTimes(1);
        const init = fetchMock.mock.calls[0]![1]!;
        const headerNames = Object.keys((init.headers ?? {}) as Record<string, string>).map((h) => h.toLowerCase());
        if (init.body instanceof FormData) {
          expect(headerNames).not.toContain('content-type');
          expect(init.body.getAll('image[]').length + init.body.getAll('image').length).toBeGreaterThan(0);
        } else {
          expect(typeof init.body).toBe('string');
          expect(() => JSON.parse(init.body as string)).not.toThrow();
        }
        expect(fetchImage).toHaveBeenCalledTimes(sample.expect.images.filter((i) => i.kind === 'url').length);

        expect(result.nRequested).toBe(sample.nRequested);
        expect(result.retried).toBe(false);
        if (sample.expect.result === 'ok') {
          expect(result.status).toBe('completed');
          expect(result.errorKind).toBeNull();
          expect(result.message).toBeNull();
          expect(result.mayBeBilled).toBe(true);
          // Duplicate observed entries (same picture in data[] and images[]) count once per requested image.
          expect(result.delivered).toBe(Math.min(observed.length, sample.nRequested));
          expect(result.images).toHaveLength(result.delivered);
          result.images.forEach((image, index) => {
            const { mime, width, height } = observed[index]!;
            const want = { mime, width, height };
            expect({ mime: image.mime, width: image.width, height: image.height }).toEqual(want);
            const decoded = decodeImageInfo(fromB64(image.data));
            expect(decoded).toEqual(want);
          });
        } else {
          expect(result.status).toBe('failed');
          expect(result.errorKind).toBe(sample.expect.result);
          expect(result.delivered).toBe(0);
          expect(result.images).toEqual([]);
          expect(result.message).toBe(text.slice(0, 1000));
          expect(result.mayBeBilled).toBe(http >= 200 && http < 300);
        }
      });
    }
  });

  describe('local rejects', () => {
    async function expectLocalReject(
      input: StudioGenerateInput,
      message: string,
      overrides: Partial<StudioGenerateDeps> = {},
    ) {
      const mocks = makeDeps(overrides);
      const result = await runStudioGenerate(input, mocks.deps);
      expect(result).toMatchObject({
        status: 'failed',
        errorKind: 'invalid_param',
        message,
        mayBeBilled: false,
        retried: false,
        delivered: 0,
        images: [],
        usage: null,
      });
      expect(mocks.fetchMock).not.toHaveBeenCalled();
      return { result, ...mocks };
    }

    it('rejects a profile that fails checkImageProfile', async () => {
      const { fetchMock, assertUrl } = await expectLocalReject(baseInput({ profile: {} }), 'invalid_profile');
      expect(fetchMock).not.toHaveBeenCalled();
      expect(assertUrl).not.toHaveBeenCalled();
    });

    it('rejects an operation the profile does not list', async () => {
      await expectLocalReject(
        editInput({ profile: normalization.profiles.minimax_image01 }),
        'invalid_profile',
      );
    });

    it('rejects a prompt over profile.maxPromptChars', async () => {
      const { result } = await expectLocalReject(
        baseInput({
          profile: { ...normalization.profiles.openai_gpt_image, maxPromptChars: 10 },
          prompt: { userPrompt: 'x'.repeat(11), references: [] },
          params: { aspect: 'banana' },
        }),
        'prompt_too_long',
      );
      expect(result.composedPrompt).toBeNull();
    });

    it('rejects a prompt over the 32000 default when the profile has no maxPromptChars', async () => {
      await expectLocalReject(
        baseInput({ prompt: { userPrompt: 'x'.repeat(32001), references: [] } }),
        'prompt_too_long',
      );
    });

    it('rejects a request the normalizer refuses with its error name', async () => {
      const { result } = await expectLocalReject(baseInput({ params: { aspect: 'banana' } }), 'invalid_request');
      expect(result.adjustments.params).toEqual([]);
    });

    it('rejects references over the route budget before the SSRF check', async () => {
      const huge = new Uint8Array(20971521);
      huge.set(PNG_REF);
      const { assertUrl, fetchMock } = await expectLocalReject(
        editInput({ images: [{ slot: 1, role: 'base', mime: 'image/png', data: huge }] }),
        'references_too_large',
        { assertUrl: vi.fn(async () => Promise.reject(new Error('blocked'))) },
      );
      expect(assertUrl).not.toHaveBeenCalled();
      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('rejects a base URL blocked by the SSRF guard', async () => {
      const assertUrl = vi.fn(async (_url: string) => Promise.reject(new Error('blocked')));
      const { fetchMock } = await expectLocalReject(baseInput(), 'base_url_blocked', { assertUrl });
      expect(assertUrl).toHaveBeenCalledTimes(1);
      expect(assertUrl.mock.calls[0]![0]).toMatch(/^https:\/\/api\.example\.com\/v1\//);
      expect(fetchMock).not.toHaveBeenCalled();
    });
  });

  /** OpenAI images body with `count` b64 images and an optional usage object. */
  function imagesBody(count: number, usage?: Record<string, number>): string {
    return JSON.stringify({
      data: Array.from({ length: count }, () => ({ b64_json: b64(PNG_REF) })),
      ...(usage ? { usage } : {}),
    });
  }

  const requestedN = (init: RequestInit | undefined) => (JSON.parse(init!.body as string) as { n?: number }).n;
  const twoPerCall = { ...normalization.profiles.openai_gpt_image, maxNPerCall: 2 };

  function deferred<T = void>() {
    let resolve!: (value: T) => void;
    const promise = new Promise<T>((r) => {
      resolve = r;
    });
    return { promise, resolve };
  }

  /** Resolves with an AbortError once the signal aborts, like the platform fetch. */
  function rejectOnAbort(signal: AbortSignal | null | undefined): Promise<never> {
    return new Promise((_resolve, reject) => {
      const fail = () => reject(signal?.reason ?? new DOMException('aborted', 'AbortError'));
      if (signal?.aborted) fail();
      else signal?.addEventListener('abort', fail, { once: true });
    });
  }

  describe('batches', () => {
    it('sends every batch concurrently with its own n and sums usage per field', async () => {
      let inFlight = 0;
      let peak = 0;
      const bothStarted = deferred();
      const usages = [
        { input_tokens: 10, total_tokens: 30 },
        { input_tokens: 5, total_tokens: 7 },
      ];
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
        const call = fetchMock.mock.calls.length - 1;
        inFlight += 1;
        peak = Math.max(peak, inFlight);
        if (inFlight === 2) bothStarted.resolve();
        await bothStarted.promise;
        inFlight -= 1;
        return new Response(imagesBody(requestedN(init) ?? 0, usages[call]), { status: 200 });
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput({ profile: twoPerCall, params: { n: 3 } }), deps);

      expect(peak).toBe(2);
      expect(fetchMock.mock.calls.map(([, init]) => requestedN(init))).toEqual([2, 1]);
      expect(result).toMatchObject({
        status: 'completed',
        errorKind: null,
        nRequested: 3,
        delivered: 3,
        mayBeBilled: true,
        retried: false,
        usage: { inputTokens: 15, outputTokens: null, totalTokens: 37 },
      });
      expect(result.images).toHaveLength(3);
      expect(result.adjustments.params).toContainEqual({ field: 'n', from: 3, to: [2, 1] });
    });

    it('rewrites parameters.n per batch for dashscope', async () => {
      const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
        new Response('{}', { status: 200 }),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });
      const profile = { ...normalization.profiles.dashscope_qwen_image, maxNPerCall: 2 };

      await runStudioGenerate(baseInput({ providerKind: 'qwen', modelId: 'qwen-image', profile, params: { n: 3 } }), deps);

      const sent = fetchMock.mock.calls.map(
        ([, init]) => (JSON.parse(init!.body as string) as { parameters?: { n?: number } }).parameters?.n,
      );
      expect(sent).toEqual([2, 1]);
    });

    it('keeps a body without an n key unchanged for every batch', async () => {
      const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
        new Response('{}', { status: 200 }),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(
        baseInput({ providerKind: 'gemini', modelId: 'gemini-flash-image', profile: normalization.profiles.gemini_flash_image, params: { n: 2 } }),
        deps,
      );

      expect(result.nRequested).toBe(2);
      expect(fetchMock).toHaveBeenCalledTimes(2);
      const bodies = fetchMock.mock.calls.map(([, init]) => JSON.parse(init!.body as string) as Record<string, unknown>);
      expect(bodies[0]).toEqual(bodies[1]);
      expect(bodies[0]).not.toHaveProperty('n');
    });

    it('reports partial when one batch fails and keeps the delivered images', async () => {
      const failure = JSON.stringify({ error: { message: 'server exploded' } });
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) =>
        requestedN(init) === 2
          ? new Response(imagesBody(2, { input_tokens: 4 }), { status: 200 })
          : new Response(failure, { status: 500 }),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput({ profile: twoPerCall, params: { n: 3 } }), deps);

      expect(result).toMatchObject({
        status: 'partial',
        nRequested: 3,
        delivered: 2,
        mayBeBilled: true,
        message: failure,
        usage: { inputTokens: 4, outputTokens: null, totalTokens: null },
      });
      expect(result.errorKind).not.toBeNull();
      expect(result.images).toHaveLength(2);
    });

    it('leaves usage null when no batch reports any', async () => {
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit) =>
        new Response(imagesBody(requestedN(init) ?? 0), { status: 200 }),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput({ profile: twoPerCall, params: { n: 3 } }), deps);

      expect(result.status).toBe('completed');
      expect(result.usage).toBeNull();
    });
  });

  describe('transport', () => {
    async function closedLocalPort(): Promise<number> {
      const server = createServer();
      await new Promise<void>((resolveListen) => server.listen(0, 'localhost', resolveListen));
      const address = server.address();
      if (address === null || typeof address === 'string') throw new Error('no port');
      await new Promise<void>((resolveClose) => server.close(() => resolveClose()));
      return address.port;
    }

    it('retries a refused connection once over the real fetch and fails as network', async () => {
      const port = await closedLocalPort();
      const realFetch = vi.fn((url: string | URL | Request, init?: RequestInit) => globalThis.fetch(url, init));
      const { deps } = makeDeps({ fetch: realFetch as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput({ baseURL: `http://localhost:${port}/v1` }), deps);

      expect(realFetch).toHaveBeenCalledTimes(2);
      expect(result).toMatchObject({
        status: 'failed',
        errorKind: 'network',
        retried: true,
        mayBeBilled: false,
        delivered: 0,
        images: [],
      });
    });

    it('does not retry a timeout and marks it as possibly billed', async () => {
      const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit): Promise<Response> => {
        throw new DOMException('timed out', 'TimeoutError');
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(result).toMatchObject({ status: 'failed', errorKind: 'timeout', retried: false, mayBeBilled: true });
    });

    it('completes after one pre-connect retry and reports retried', async () => {
      const refused = Object.assign(new TypeError('fetch failed'), { cause: { code: 'ECONNREFUSED' } });
      const fetchMock = vi
        .fn(async (_url: string | URL | Request, _init?: RequestInit): Promise<Response> => new Response(imagesBody(1), { status: 200 }))
        .mockRejectedValueOnce(refused);
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(result).toMatchObject({ status: 'completed', errorKind: null, retried: true, mayBeBilled: true, delivered: 1 });
    });

    it('does not retry an unknown failure after send', async () => {
      const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit): Promise<Response> => {
        throw new TypeError('socket hang up');
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(result).toMatchObject({ status: 'failed', errorKind: 'network', retried: false, mayBeBilled: true });
    });

    it('gives every attempt its own signal that follows the client signal', async () => {
      const client = new AbortController();
      const signals: AbortSignal[] = [];
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        signals.push(init!.signal!);
        return new Response(imagesBody(1), { status: 200 });
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch, signal: client.signal });

      await runStudioGenerate(baseInput(), deps);

      expect(signals).toHaveLength(1);
      expect(signals[0]).not.toBe(client.signal);
      expect(signals[0]!.aborted).toBe(false);
      client.abort();
      expect(signals[0]!.aborted).toBe(true);
    });
    it('downloads url images with the client signal, outside the attempt timeout', async () => {
      const client = new AbortController();
      let attemptSignal: AbortSignal | undefined;
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        attemptSignal = init!.signal!;
        return new Response(JSON.stringify({ data: [{ url: 'https://cdn.example.com/a.png' }] }), { status: 200 });
      });
      const fetchImage = vi.fn(async (_url: string, signal: AbortSignal): Promise<ImageMaterializeOutcome> => {
        // The attempt timer has no say here: only the client signal reaches the download.
        expect(signal).toBe(client.signal);
        return outcomeOf(PNG_REF);
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch, fetchImage, signal: client.signal });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchImage).toHaveBeenCalledTimes(1);
      expect(fetchImage.mock.calls[0]![1]).toBe(client.signal);
      expect(fetchImage.mock.calls[0]![1]).not.toBe(attemptSignal);
      expect(result).toMatchObject({ status: 'completed', delivered: 1, errorKind: null });
    });

    it('records a thrown non-cancel download failure as network', async () => {
      const fetchImage = vi.fn(async (): Promise<ImageMaterializeOutcome> => {
        throw new DOMException('timed out', 'TimeoutError');
      });
      const { deps } = makeDeps(
        { fetchImage },
        () => new Response(JSON.stringify({ data: [{ url: 'https://cdn.example.com/a.png' }] }), { status: 200 }),
      );

      const result = await runStudioGenerate(baseInput(), deps);

      expect(result).toMatchObject({ status: 'failed', errorKind: 'network', delivered: 0, mayBeBilled: true });
    });
  });

  describe('cancel', () => {
    it('cancels without sending when the client drops before the upstream call', async () => {
      const client = new AbortController();
      const assertUrl = vi.fn(async (_url: string) => {
        client.abort();
      });
      const { deps, fetchMock } = makeDeps({ assertUrl, signal: client.signal });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchMock).not.toHaveBeenCalled();
      expect(result).toMatchObject({ status: 'cancelled', errorKind: null, mayBeBilled: false, images: [], delivered: 0 });
    });

    it('cancels an in-flight request and marks it as possibly billed', async () => {
      const client = new AbortController();
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        queueMicrotask(() => client.abort());
        return rejectOnAbort(init?.signal);
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch, signal: client.signal });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(result).toMatchObject({
        status: 'cancelled',
        errorKind: null,
        retried: false,
        mayBeBilled: true,
        images: [],
        delivered: 0,
      });
    });

    it('drops finished batches when the client cancels while another is in flight', async () => {
      const client = new AbortController();
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        if (requestedN(init) === 2) {
          setTimeout(() => client.abort(), 0);
          return new Response(imagesBody(2), { status: 200 });
        }
        return rejectOnAbort(init?.signal);
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch, signal: client.signal });

      const result = await runStudioGenerate(baseInput({ profile: twoPerCall, params: { n: 3 } }), deps);

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(result).toMatchObject({ status: 'cancelled', errorKind: null, mayBeBilled: true, images: [], delivered: 0 });
    });

    it('cancels while url images are being fetched', async () => {
      const client = new AbortController();
      const fetchImage = vi.fn(async (_url: string, signal: AbortSignal): Promise<ImageMaterializeOutcome> => {
        queueMicrotask(() => client.abort());
        return rejectOnAbort(signal);
      });
      const { deps } = makeDeps(
        { fetchImage, signal: client.signal },
        () => new Response(JSON.stringify({ data: [{ url: 'https://cdn.example.com/a.png' }] }), { status: 200 }),
      );

      const result = await runStudioGenerate(baseInput(), deps);

      expect(fetchImage).toHaveBeenCalledTimes(1);
      expect(result).toMatchObject({ status: 'cancelled', errorKind: null, mayBeBilled: true, images: [], delivered: 0 });
    });
  });

  describe('review fixes', () => {
    it('times out a hanging upstream with the real per-attempt timer and does not retry', async () => {
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> =>
        rejectOnAbort(init?.signal),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });
      const profile = { ...normalization.profiles.openai_gpt_image, timeoutSeconds: 1 };

      const result = await runStudioGenerate(baseInput({ profile }), deps);

      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(result).toMatchObject({ status: 'failed', errorKind: 'timeout', retried: false, mayBeBilled: true });
    });

    it('cancels an oversized upstream reply and fails the batch as response_too_large', async () => {
      const limit = 41943040 + 1048576;
      const chunkSize = 4 * 1048576;
      const total = limit + 4 * chunkSize;
      let served = 0;
      const cancel = vi.fn();
      const fetchMock = vi.fn(async (_url: string | URL | Request, _init?: RequestInit): Promise<Response> =>
        new Response(
          new ReadableStream<Uint8Array>({
            pull(controller) {
              if (served >= total) {
                controller.close();
                return;
              }
              served += chunkSize;
              controller.enqueue(new Uint8Array(chunkSize));
            },
            cancel,
          }),
          { status: 200 },
        ),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput(), deps);

      expect(result).toMatchObject({
        status: 'failed',
        errorKind: 'upstream_error',
        message: 'response_too_large',
        mayBeBilled: true,
        delivered: 0,
        images: [],
      });
      expect(cancel).toHaveBeenCalledTimes(1);
      expect(served).toBeLessThan(total);
    });

    it('leaves message null when the batch that supplies errorKind has none', async () => {
      const failure = JSON.stringify({ error: { message: 'server exploded' } });
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> => {
        if (requestedN(init) === 2) throw new TypeError('socket hang up');
        return new Response(failure, { status: 500 });
      });
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput({ profile: twoPerCall, params: { n: 3 } }), deps);

      expect(result).toMatchObject({ status: 'failed', errorKind: 'network', message: null, delivered: 0 });
    });

    it('does not borrow a later batch message for a partial first batch', async () => {
      const failure = JSON.stringify({ error: { message: 'server exploded' } });
      const fetchMock = vi.fn(async (_url: string | URL | Request, init?: RequestInit): Promise<Response> =>
        requestedN(init) === 2
          ? new Response(imagesBody(1), { status: 200 })
          : new Response(failure, { status: 500 }),
      );
      const { deps } = makeDeps({ fetch: fetchMock as unknown as typeof fetch });

      const result = await runStudioGenerate(baseInput({ profile: twoPerCall, params: { n: 3 } }), deps);

      expect(result).toMatchObject({ status: 'partial', errorKind: 'partial', message: null, delivered: 1 });
    });
  });
});
