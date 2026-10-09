/**
 * Truth table for offering "retry without the additional body" after an error (an in-stream error is treated like an upstream rejection).
 */
import { describe, expect, it, vi } from 'vitest';
import { additionalBodyRetryEligible, type AdditionalBodyRetryInput } from '../additional-body-retry';

const base: AdditionalBodyRetryInput = {
  additionalBodyApplied: true, receivedUpstreamEvent: false, sideEffects: false, localRejection: false,
};

describe('additionalBodyRetryEligible', () => {
  it.each<[string, Partial<AdditionalBodyRetryInput>, boolean]>([
    ['HTTP 400 offers retry', { httpStatus: 400 }, true],
    ['an unclassified in-stream error frame before any content offers retry', { streamErrorFrame: {} }, true],
    ['the empty-stream fallback does not offer retry', {}, false],
    ['an error after content does not offer retry', { receivedUpstreamEvent: true, streamErrorFrame: {} }, false],
    ['a 400 after content does not offer retry either', { receivedUpstreamEvent: true, httpStatus: 400 }, false],
    ['no additional body applied does not offer retry', { additionalBodyApplied: false, httpStatus: 400 }, false],
    ['a local rejection does not offer retry', { localRejection: true, httpStatus: 400 }, false],
    ['a classified in-stream error frame does not offer retry (quota)', { streamErrorFrame: { classifiedKind: 'quotaExceeded' } }, false],
    ['a classified in-stream error frame does not offer retry (rate limit)', { streamErrorFrame: { classifiedKind: 'rateLimited' } }, false],
    ['a classified in-stream error frame does not offer retry (auth)', { streamErrorFrame: { classifiedKind: 'invalidKey' } }, false],
    ['a classified in-stream error frame does not offer retry (model unavailable)', { streamErrorFrame: { classifiedKind: 'unavailable' } }, false],
    ['an in-stream error frame classified as an upstream error still offers retry', { streamErrorFrame: { classifiedKind: 'upstream' } }, true],
    ['tool side effects do not offer retry', { sideEffects: true, httpStatus: 400 }, false],
    ['other HTTP statuses do not offer retry', { httpStatus: 500 }, false],
  ])('%s', (_name, patch, expected) => {
    expect(additionalBodyRetryEligible({ ...base, ...patch })).toBe(expected);
  });
});

describe('send path fact: proxy-client sets the flag on an upstream 400', () => {
  it('non-empty additional body + upstream 400 -> offered; none / only an empty object -> not offered', async () => {
    const { sendStreamProxy } = await import('../../providers/proxy-client');
    const run = async (additionalBody?: { raw: string }) => {
      vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({ error: { message: 'Unknown parameter: top_k' } }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      }));
      const handle = sendStreamProxy('openAI', 'k', 'gpt-4', [{ role: 'user', content: 'hi' }], undefined,
        { supportsWebSearch: false, ...(additionalBody ? { additionalBody } : {}) });
      const reader = handle.stream.getReader();
      while (!(await reader.read()).done) { /* drain */ }
      vi.restoreAllMocks();
      return (handle as { getAdditionalBodyRetryEligible?: () => boolean }).getAdditionalBodyRetryEligible?.() ?? false;
    };
    expect(await run({ raw: '{"top_k":3}' })).toBe(true);
    expect(await run()).toBe(false);
    expect(await run({ raw: '{}' })).toBe(false);
  });
});
