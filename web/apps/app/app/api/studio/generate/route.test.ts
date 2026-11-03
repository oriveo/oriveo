// @vitest-environment node
/**
 * POST /api/studio/generate: pre-stream request errors (rate limit, multipart,
 * request JSON, reference files), the SSE envelope (ping, result frame, headers)
 * and browser disconnect as cancel. The route runs the real executor; only the
 * global fetch (upstream) is faked.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { __resetRateLimitForTests, RATE_LIMIT_CONFIG } from '../../chat/stream/rate-limit';
import { runStudioGenerate } from './executor';
import { POST } from './route';

// Passthrough to the real executor; one case forces an unexpected rejection.
vi.mock('./executor', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./executor')>();
  return { ...actual, runStudioGenerate: vi.fn(actual.runStudioGenerate) };
});

const ROOT = resolve(__dirname, '../../../../../../../..');
// Shared contracts directory name, spelled by code point to keep this file ASCII.
const CONTRACTS = resolve(ROOT, String.fromCharCode(0x5171, 0x4eab), 'model-contracts');
const normalization = JSON.parse(
  readFileSync(resolve(CONTRACTS, 'image_param_normalization.v1.json'), 'utf8'),
) as { profiles: Record<string, Record<string, unknown>> };

const ROUTE_URL = 'http://localhost/api/studio/generate';
// IP literal: the real SSRF guard passes it without DNS.
const BASE_URL = 'https://8.8.8.8/v1';

function u32be(value: number): number[] {
  return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
}

/** Header-only PNG the decoder accepts. */
function pngBytes(width: number, height: number): Uint8Array {
  return Uint8Array.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ...u32be(13), 0x49, 0x48, 0x44, 0x52,
    ...u32be(width), ...u32be(height),
    8, 6, 0, 0, 0, 0, 0, 0, 0,
  ]);
}

const OUTPUT = pngBytes(32, 48);
const REFERENCE = pngBytes(64, 64);
const b64 = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64');

function requestJson(overrides: Record<string, unknown> = {}): Record<string, unknown> {
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

const editJson = () =>
  requestJson({
    operation: 'edit',
    prompt: { userPrompt: 'make it blue', references: [{ n: 1, role: 'base' }] },
    images: [{ slot: 1, role: 'base', mime: 'image/png' }],
  });

let ipCounter = 0;

function buildRequest(
  fields: Record<string, string | Blob>,
  opts: { ip?: string; signal?: AbortSignal } = {},
): Request {
  const form = new FormData();
  for (const [name, value] of Object.entries(fields)) form.append(name, value);
  return new Request(ROUTE_URL, {
    method: 'POST',
    body: form,
    headers: { 'x-forwarded-for': opts.ip ?? `198.51.100.${(ipCounter += 1) % 250}` },
    signal: opts.signal,
  });
}

const referenceFile = () => new File([REFERENCE as BlobPart], 'ref.png', { type: 'image/png' });

function upstreamOk(): Response {
  return new Response(JSON.stringify({ created: 1, data: [{ b64_json: b64(OUTPUT) }] }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
}

function isUpstream(input: unknown): boolean {
  return String(input instanceof Request ? input.url : input).startsWith(BASE_URL);
}

async function readAll(response: Response): Promise<string> {
  const reader = response.body!.getReader();
  const decoder = new TextDecoder();
  let text = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) return text;
    text += decoder.decode(value, { stream: true });
  }
}

function resultFrame(text: string): Record<string, unknown> {
  const match = /event: result\ndata: (.*)\n\n$/.exec(text);
  if (!match) throw new Error(`no trailing result frame in ${JSON.stringify(text)}`);
  return JSON.parse(match[1]!) as Record<string, unknown>;
}

describe('POST /api/studio/generate', () => {
  beforeEach(() => {
    __resetRateLimitForTests();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
  });

  describe('request errors', () => {
    async function expectInvalid(response: Response, fetchSpy: { mock: { calls: unknown[] } }) {
      expect(response.status).toBe(400);
      expect(response.headers.get('content-type')).toContain('application/json');
      const body = (await response.json()) as { errorKind: string; message: unknown };
      expect(body.errorKind).toBe('invalid_param');
      expect(typeof body.message).toBe('string');
      expect(fetchSpy.mock.calls).toHaveLength(0);
    }

    it('answers 429 rate_limited once the shared chat bucket is exhausted', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      const ip = '203.0.113.9';
      for (let i = 0; i < RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW; i++) {
        const response = await POST(buildRequest({}, { ip }));
        expect(response.status).toBe(400);
      }
      const response = await POST(buildRequest({ request: JSON.stringify(requestJson()) }, { ip }));
      expect(response.status).toBe(429);
      expect(response.headers.get('X-RateLimit-Remaining')).toBe('0');
      expect(Number(response.headers.get('Retry-After'))).toBeGreaterThanOrEqual(1);
      const body = (await response.json()) as { errorKind: string; message: unknown };
      expect(body.errorKind).toBe('rate_limited');
      expect(typeof body.message).toBe('string');
      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it('rejects a body that is not multipart form data', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      const response = await POST(
        new Request(ROUTE_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(requestJson()),
        }),
      );
      await expectInvalid(response, fetchSpy);
    });

    it('rejects a form without the request field', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      await expectInvalid(await POST(buildRequest({ other: 'x' })), fetchSpy);
    });

    it('rejects malformed request JSON', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      await expectInvalid(await POST(buildRequest({ request: '{"providerKind":' })), fetchSpy);
    });

    it.each<[string, Record<string, unknown>]>([
      ['apiKey is a number', { apiKey: 42 }],
      ['baseURL is missing', { baseURL: undefined }],
      ['profile is a string', { profile: 'openai_gpt_image' }],
      ['prompt.userPrompt is missing', { prompt: { references: [] } }],
      ['prompt.references holds an unknown role', { prompt: { userPrompt: 'x', references: [{ n: 1, role: 'hero' }] } }],
      ['params.n is a string', { params: { n: '2' } }],
      ['advanced is an array', { advanced: [] }],
      ['images is not an array', { images: {} }],
      ['an image slot is not a number', { images: [{ slot: '1', role: 'base', mime: 'image/png' }] }],
    ])('rejects a field of the wrong type: %s', async (_name, overrides) => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      const response = await POST(buildRequest({ request: JSON.stringify(requestJson(overrides)) }));
      await expectInvalid(response, fetchSpy);
    });

    it('rejects a declared reference image without its file field', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      const response = await POST(buildRequest({ request: JSON.stringify(editJson()), image_2: referenceFile() }));
      await expectInvalid(response, fetchSpy);
    });
  });

  describe('sse', () => {
    it('streams one result frame with base64 images and SSE headers', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
        if (isUpstream(input)) return upstreamOk();
        throw new Error(`unexpected fetch ${String(input)}`);
      });

      const response = await POST(buildRequest({ request: JSON.stringify(requestJson()) }));

      expect(response.status).toBe(200);
      expect(response.headers.get('content-type')).toContain('text/event-stream');
      expect(response.headers.get('cache-control')).toContain('no-cache');
      expect(response.headers.get('x-accel-buffering')).toBe('no');
      expect(response.headers.get('X-RateLimit-Limit')).toBe(String(RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW));
      const text = await readAll(response);
      expect(text.match(/event: result/g)).toHaveLength(1);
      const result = resultFrame(text);
      expect(result.status).toBe('completed');
      expect(result.errorKind).toBeNull();
      expect(result.delivered).toBe(1);
      expect(result.mayBeBilled).toBe(true);
      expect(result.composedPrompt).toBe('a red apple');
      const images = result.images as Array<{ data: string; mime: string; width: number; height: number }>;
      expect(images).toHaveLength(1);
      expect(new Uint8Array(Buffer.from(images[0]!.data, 'base64'))).toEqual(OUTPUT);
      expect(images[0]).toMatchObject({ mime: 'image/png', width: 32, height: 48 });

      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const [url, init] = fetchSpy.mock.calls[0]!;
      expect(String(url)).toBe(`${BASE_URL}/images/generations`);
      expect(init?.redirect).toBe('manual');
      expect(init?.signal).toBeInstanceOf(AbortSignal);
    });

    it('forwards each reference file under its slot to the upstream edit request', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
        if (isUpstream(input)) return upstreamOk();
        throw new Error(`unexpected fetch ${String(input)}`);
      });

      const response = await POST(buildRequest({ request: JSON.stringify(editJson()), image_1: referenceFile() }));

      expect(response.status).toBe(200);
      expect(resultFrame(await readAll(response)).status).toBe('completed');
      expect(fetchSpy).toHaveBeenCalledTimes(1);
      const body = fetchSpy.mock.calls[0]![1]!.body;
      expect(body).toBeInstanceOf(FormData);
      const files = [...(body as FormData).getAll('image[]'), ...(body as FormData).getAll('image')];
      expect(files).toHaveLength(1);
      expect(new Uint8Array(await (files[0] as Blob).arrayBuffer())).toEqual(REFERENCE);
    });

    it('reports an unexpected executor failure as a possibly billed internal_error result', async () => {
      vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
      const fetchSpy = vi.spyOn(globalThis, 'fetch');
      vi.mocked(runStudioGenerate).mockRejectedValueOnce(new Error('executor bug'));

      const response = await POST(buildRequest({ request: JSON.stringify(requestJson({ params: { n: 2 } })) }));

      expect(response.status).toBe(200);
      const text = await readAll(response);
      expect(text.match(/event: result/g)).toHaveLength(1);
      expect(resultFrame(text)).toEqual({
        status: 'failed',
        errorKind: 'upstream_error',
        message: 'internal_error',
        mayBeBilled: true,
        retried: false,
        nRequested: 2,
        delivered: 0,
        composedPrompt: null,
        adjustments: { prompt: [], params: [] },
        usage: null,
        images: [],
      });
      expect(fetchSpy).not.toHaveBeenCalled();
      expect(vi.getTimerCount()).toBe(0);
    });

    it('writes a ping comment every 15 seconds until the result arrives, then stops the timer', async () => {
      vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
      let release!: () => void;
      const gate = new Promise<void>((resolveGate) => {
        release = resolveGate;
      });
      vi.spyOn(globalThis, 'fetch').mockImplementation(async (input) => {
        if (!isUpstream(input)) throw new Error(`unexpected fetch ${String(input)}`);
        await gate;
        return upstreamOk();
      });

      const response = await POST(buildRequest({ request: JSON.stringify(requestJson()) }));
      const reader = response.body!.getReader();
      const decoder = new TextDecoder();

      await vi.advanceTimersByTimeAsync(15000);
      expect(decoder.decode((await reader.read()).value)).toBe(': ping\n\n');
      await vi.advanceTimersByTimeAsync(15000);
      expect(decoder.decode((await reader.read()).value)).toBe(': ping\n\n');

      release();
      let rest = '';
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        rest += decoder.decode(value, { stream: true });
      }
      expect(resultFrame(rest).status).toBe('completed');
      expect(rest).not.toContain(': ping');
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe('abort', () => {
    it('treats a browser disconnect as cancel: no result frame and the ping timer is cleared', async () => {
      vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
        if (!isUpstream(input)) return Promise.reject(new Error(`unexpected fetch ${String(input)}`));
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        });
      });
      const browser = new AbortController();

      const response = await POST(buildRequest({ request: JSON.stringify(requestJson()) }, { signal: browser.signal }));
      expect(response.status).toBe(200);
      await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
      expect(vi.getTimerCount()).toBe(1);

      browser.abort();
      const text = await readAll(response);
      expect(text).not.toContain('event: result');
      expect(vi.getTimerCount()).toBe(0);
    });

    it('aborts the executor signal and the upstream fetch when the stream reader cancels', async () => {
      vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] });
      let upstreamSignal: AbortSignal | null | undefined;
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation((input, init) => {
        if (!isUpstream(input)) return Promise.reject(new Error(`unexpected fetch ${String(input)}`));
        upstreamSignal = init?.signal;
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        });
      });

      const response = await POST(buildRequest({ request: JSON.stringify(requestJson()) }));
      expect(response.status).toBe(200);
      await vi.waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(1));
      const executorSignal = vi.mocked(runStudioGenerate).mock.lastCall![1].signal;
      expect(executorSignal.aborted).toBe(false);
      expect(upstreamSignal?.aborted).toBe(false);

      await response.body!.getReader().cancel();

      expect(executorSignal.aborted).toBe(true);
      expect(upstreamSignal?.aborted).toBe(true);
      expect(vi.getTimerCount()).toBe(0);
      await expect(vi.mocked(runStudioGenerate).mock.results.at(-1)!.value).resolves.toMatchObject({
        status: 'cancelled',
      });
    });
  });
});
