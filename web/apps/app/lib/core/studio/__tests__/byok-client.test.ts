/**
 * runStudioByokRound: budget fit, multipart upload to /api/studio/generate,
 * SSE result decoding, error mapping and cancellation.
 */
import { describe, expect, it, vi } from 'vitest';
import {
  runStudioByokRound,
  type StudioByokRoundInput,
  type StudioGenerateWireResult,
} from '../byok-client';
import type { ImageProfile } from '../image-profile';

const PROFILE: ImageProfile = {
  imageOutput: true,
  operations: ['generate', 'edit'],
  route: 'dashscope_multimodal',
  aspectRatios: ['1:1'],
  sizeParam: 'dashscope_wxh',
  resolutions: { '1k': 1024 },
  maxNPerCall: 1,
  timeoutSeconds: 120,
  source: 'official_api',
};

// dashscope_multimodal caps one data-URI image at 10,000,000 bytes.
const OVERSIZED = 7_600_000;

function makeInput(overrides: Partial<StudioByokRoundInput> = {}): StudioByokRoundInput {
  return {
    providerKind: 'qwen',
    apiKey: 'sk-test',
    baseURL: 'https://dashscope.example.com',
    modelId: 'qwen-image',
    profile: PROFILE,
    operation: 'generate',
    prompt: { userPrompt: 'a red fox', references: [{ n: 1, role: 'subject' }] },
    params: { aspect: '1:1', n: 1 },
    advanced: null,
    images: [{ slot: 1, role: 'subject', mime: 'image/png', data: new Uint8Array([1, 2, 3, 4]) }],
    ...overrides,
  };
}

function wireResult(overrides: Partial<StudioGenerateWireResult> = {}): StudioGenerateWireResult {
  return {
    status: 'completed',
    errorKind: null,
    message: null,
    mayBeBilled: true,
    retried: false,
    nRequested: 1,
    delivered: 1,
    composedPrompt: 'a red fox\n\nImage 1 is the subject reference.',
    adjustments: { prompt: [], params: [{ field: 'aspect', from: '3:2', to: '1:1' }] },
    usage: { inputTokens: 10, outputTokens: 20, totalTokens: 30 },
    images: [{ data: 'AQID/w==', mime: 'image/png', width: 1024, height: 1024, revisedPrompt: null }],
    ...overrides,
  };
}

function sseResponse(chunks: string[], onPull?: (index: number) => void): Response {
  const encoder = new TextEncoder();
  let index = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      onPull?.(index);
      if (index >= chunks.length) {
        controller.close();
        return;
      }
      controller.enqueue(encoder.encode(chunks[index]!));
      index += 1;
    },
  });
  return new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}

function resultFrames(result: StudioGenerateWireResult): string[] {
  const frame = `event: result\ndata: ${JSON.stringify(result)}\n\n`;
  const cut = Math.floor(frame.length / 2);
  return [': ping\n\n', frame.slice(0, cut), frame.slice(cut)];
}

function okFetch(result: StudioGenerateWireResult = wireResult()) {
  return vi.fn(async (_url: RequestInfo | URL, _init?: RequestInit) => sseResponse(resultFrames(result)));
}

function signal(): AbortSignal {
  return new AbortController().signal;
}

describe('runStudioByokRound', () => {
  describe('upload', () => {
    it('posts multipart request JSON and one image_<slot> file per reference', async () => {
      const fetchMock = okFetch();
      const input = makeInput({
        operation: 'edit',
        advanced: { seed: 7 },
        prompt: {
          userPrompt: 'swap the sky',
          references: [
            { n: 1, role: 'base' },
            { n: 2, role: 'style' },
          ],
        },
        images: [
          { slot: 2, role: 'style', mime: 'image/webp', data: new Uint8Array([9, 9]) },
          { slot: 1, role: 'base', mime: 'image/png', data: new Uint8Array([1, 2, 3]) },
        ],
      });

      await runStudioByokRound(input, { fetch: fetchMock, signal: signal() });

      expect(fetchMock).toHaveBeenCalledTimes(1);
      const [url, init] = fetchMock.mock.calls[0]!;
      expect(url).toBe('/api/studio/generate');
      expect(init?.method).toBe('POST');
      const form = init?.body as FormData;
      expect(form).toBeInstanceOf(FormData);
      const request = JSON.parse(form.get('request') as string);
      expect(request).toEqual({
        providerKind: 'qwen',
        apiKey: 'sk-test',
        baseURL: 'https://dashscope.example.com',
        modelId: 'qwen-image',
        profile: PROFILE,
        operation: 'edit',
        prompt: input.prompt,
        params: { aspect: '1:1', n: 1 },
        advanced: { seed: 7 },
        images: [
          { slot: 1, role: 'base', mime: 'image/png' },
          { slot: 2, role: 'style', mime: 'image/webp' },
        ],
      });
      const base = form.get('image_1') as Blob;
      expect(base.type).toBe('image/png');
      expect(Array.from(new Uint8Array(await base.arrayBuffer()))).toEqual([1, 2, 3]);
      const style = form.get('image_2') as Blob;
      expect(style.type).toBe('image/webp');
      expect(Array.from(new Uint8Array(await style.arrayBuffer()))).toEqual([9, 9]);
    });

    it('uploads the shrunk bytes and mime when a reference is over the route limit', async () => {
      const fetchMock = okFetch();
      const shrink = vi.fn(async () => ({ data: new Uint8Array([5, 6, 7]), mime: 'image/jpeg' }));
      const input = makeInput({
        images: [{ slot: 1, role: 'subject', mime: 'image/png', data: new Uint8Array(OVERSIZED) }],
      });

      await runStudioByokRound(input, { fetch: fetchMock, signal: signal(), shrink });

      expect(shrink).toHaveBeenCalledTimes(1);
      const form = fetchMock.mock.calls[0]![1]?.body as FormData;
      expect(JSON.parse(form.get('request') as string).images).toEqual([
        { slot: 1, role: 'subject', mime: 'image/jpeg' },
      ]);
      const file = form.get('image_1') as Blob;
      expect(file.type).toBe('image/jpeg');
      expect(Array.from(new Uint8Array(await file.arrayBuffer()))).toEqual([5, 6, 7]);
    });

    it('fails locally with references_too_large and sends nothing when the budget cannot fit', async () => {
      const fetchMock = okFetch();
      const input = makeInput({
        images: [{ slot: 1, role: 'subject', mime: 'image/png', data: new Uint8Array(OVERSIZED) }],
      });

      const result = await runStudioByokRound(input, {
        fetch: fetchMock,
        signal: signal(),
        shrink: async () => null,
      });

      expect(fetchMock).not.toHaveBeenCalled();
      expect(result.status).toBe('failed');
      expect(result.errorKind).toBe('invalid_param');
      expect(result.message).toBe('references_too_large');
      expect(result.mayBeBilled).toBe(false);
      expect(result.images).toEqual([]);
    });

    it('counts the user prompt when the composed prompt exceeds the default 32000 char limit', async () => {
      // Profile has no maxPromptChars. A 32001-char user text cannot fit the default
      // limit, so compose fails and the budget counts the user text only; counting the
      // 7M-char effects would push the request over dashscope's 16,777,216 byte cap.
      expect(PROFILE.maxPromptChars).toBeUndefined();
      const fetchMock = okFetch();
      const shrink = vi.fn(async () => null);
      const input = makeInput({
        prompt: {
          userPrompt: 'a'.repeat(32_001),
          references: [{ n: 1, role: 'subject' }],
          effectFragments: ['x'.repeat(7_000_000)],
        },
        images: [{ slot: 1, role: 'subject', mime: 'image/png', data: new Uint8Array(7_400_000) }],
      });

      const result = await runStudioByokRound(input, { fetch: fetchMock, signal: signal(), shrink });

      expect(shrink).not.toHaveBeenCalled();
      expect(fetchMock).toHaveBeenCalledTimes(1);
      expect(result.status).toBe('completed');
    });
  });

  describe('result', () => {
    it('returns the result frame with base64 image data decoded, skipping ping comments', async () => {
      const wire = wireResult();
      const result = await runStudioByokRound(makeInput(), { fetch: okFetch(wire), signal: signal() });

      expect(result).toEqual({
        ...wire,
        images: [
          { data: new Uint8Array([1, 2, 3, 255]), mime: 'image/png', width: 1024, height: 1024, revisedPrompt: null },
        ],
      });
      expect(result.images[0]!.data).toBeInstanceOf(Uint8Array);
    });

    it('passes a failed server result through unchanged', async () => {
      const wire = wireResult({
        status: 'failed',
        errorKind: 'refused',
        message: 'moderation_blocked',
        mayBeBilled: false,
        delivered: 0,
        composedPrompt: null,
        usage: null,
        images: [],
      });
      const result = await runStudioByokRound(makeInput(), { fetch: okFetch(wire), signal: signal() });

      expect(result).toEqual(wire);
    });
  });

  describe('errors', () => {
    const errorCases: Array<[string, number, string, string, string | null]> = [
      ['body errorKind on 429', 429, '{"errorKind":"rate_limited","message":"slow down"}', 'rate_limited', 'slow down'],
      ['body errorKind on 500', 500, '{"errorKind":"invalid_param","message":"bad request"}', 'invalid_param', 'bad request'],
      ['429 without a parsable body', 429, 'Too Many Requests', 'rate_limited', null],
      ['400 without a parsable body', 400, '', 'invalid_param', null],
      ['413 without a parsable body', 413, '<html>too large</html>', 'invalid_param', null],
      ['502 without a parsable body', 502, 'Bad Gateway', 'upstream_error', null],
    ];

    it.each(errorCases)('maps %s', async (_name, status, body, errorKind, message) => {
      const fetchMock = vi.fn(async () => new Response(body, { status }));
      const result = await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: signal() });

      expect(result.status).toBe('failed');
      expect(result.errorKind).toBe(errorKind);
      expect(result.message).toBe(message);
      expect(result.mayBeBilled).toBe(false);
      expect(result.images).toEqual([]);
    });

    it('maps a thrown fetch error to network with mayBeBilled true', async () => {
      const fetchMock = vi.fn(async () => {
        throw new TypeError('Failed to fetch');
      });
      const result = await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: signal() });

      expect(result.status).toBe('failed');
      expect(result.errorKind).toBe('network');
      expect(result.mayBeBilled).toBe(true);
      expect(result.images).toEqual([]);
    });

    it('maps a stream that ends without a result frame to network', async () => {
      const fetchMock = vi.fn(async () => sseResponse([': ping\n\n', 'event: other\ndata: {}\n\n']));
      const result = await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: signal() });

      expect(result.status).toBe('failed');
      expect(result.errorKind).toBe('network');
      expect(result.mayBeBilled).toBe(true);
    });
  });

  describe('cancel', () => {
    it('maps an AbortError from fetch to cancelled with mayBeBilled true', async () => {
      const fetchMock = vi.fn(async () => {
        throw new DOMException('The operation was aborted.', 'AbortError');
      });
      const result = await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: signal() });

      expect(result.status).toBe('cancelled');
      expect(result.errorKind).toBeNull();
      expect(result.mayBeBilled).toBe(true);
      expect(result.images).toEqual([]);
    });

    it('maps any fetch error after the signal aborted to cancelled', async () => {
      const controller = new AbortController();
      const fetchMock = vi.fn(async () => {
        controller.abort();
        throw new TypeError('Failed to fetch');
      });
      const result = await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: controller.signal });

      expect(result.status).toBe('cancelled');
      expect(result.mayBeBilled).toBe(true);
    });

    it('returns cancelled with no images when the signal aborted before the result arrived', async () => {
      const controller = new AbortController();
      const fetchMock = vi.fn(async () =>
        sseResponse(resultFrames(wireResult()), (index) => {
          if (index === 1) controller.abort();
        }),
      );
      const result = await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: controller.signal });

      expect(result.status).toBe('cancelled');
      expect(result.mayBeBilled).toBe(true);
      expect(result.images).toEqual([]);
    });

    it('returns cancelled without billing or calling fetch when the signal aborted before the upload', async () => {
      const controller = new AbortController();
      const fetchMock = okFetch();
      const shrink = vi.fn(async () => {
        controller.abort();
        return { data: new Uint8Array([5, 6, 7]), mime: 'image/jpeg' };
      });
      const input = makeInput({
        images: [{ slot: 1, role: 'subject', mime: 'image/png', data: new Uint8Array(OVERSIZED) }],
      });
      const result = await runStudioByokRound(input, { fetch: fetchMock, signal: controller.signal, shrink });

      expect(shrink).toHaveBeenCalledTimes(1);
      expect(fetchMock).not.toHaveBeenCalled();
      expect(result.status).toBe('cancelled');
      expect(result.errorKind).toBeNull();
      expect(result.mayBeBilled).toBe(false);
      expect(result.images).toEqual([]);
    });

    it('passes the signal to fetch', async () => {
      const fetchMock = okFetch();
      const s = signal();
      await runStudioByokRound(makeInput(), { fetch: fetchMock, signal: s });

      expect(fetchMock.mock.calls[0]![1]?.signal).toBe(s);
    });
  });
});
