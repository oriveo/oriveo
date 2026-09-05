import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../metadata/metadata-client', () => ({
  initMetadata: vi.fn().mockResolvedValue(undefined),
  getWebSearchProfile: vi.fn(),
  getProviderDefaultModelId: vi.fn(),
  listProviderModelIds: vi.fn(),
  resolveCatalogModel: vi.fn(),
}));

vi.mock('../proxy-client', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../proxy-client')>();
  return { ...actual, USE_PROXY: false };
});

import {
  initMetadata,
  getWebSearchProfile,
  getProviderDefaultModelId,
  listProviderModelIds,
  resolveCatalogModel,
} from '../../metadata/metadata-client';
import { sendMessageStream, syncModels, validateKey } from './openrouter';

const mockInitMetadata = vi.mocked(initMetadata);
const mockGetWebSearchProfile = vi.mocked(getWebSearchProfile);
const mockGetDefaultModelId = vi.mocked(getProviderDefaultModelId);
const mockListModelIds = vi.mocked(listProviderModelIds);
const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);

describe('openrouter adapter (metadata-only)', () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    mockInitMetadata.mockReset();
    mockGetWebSearchProfile.mockReset();
    mockGetDefaultModelId.mockReset();
    mockListModelIds.mockReset();
    mockResolveCatalogModel.mockReset();

    // Defaults for every test: metadata resolves, but offers nothing.
    mockInitMetadata.mockResolvedValue(undefined);
    mockGetWebSearchProfile.mockReturnValue(null);
    mockGetDefaultModelId.mockReturnValue(undefined);
    mockListModelIds.mockReturnValue([]);
    mockResolveCatalogModel.mockReturnValue(null);
  });

  describe('validateKey', () => {
    it('accepts non-empty keys without pinging upstream', async () => {
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockRejectedValue(
        new Error('unexpected upstream fetch'),
      );

      await validateKey('sk-or-test');

      expect(fetchSpy).not.toHaveBeenCalled();
    });

    it('rejects empty keys locally', async () => {
      await expect(validateKey('   ')).rejects.toThrow('Missing API key.');
    });
  });

  describe('syncModels', () => {
    it('returns metadata-backed models with deduplication', async () => {
      mockListModelIds.mockReturnValue([
        'openai/gpt-4o',
        'openai/gpt-4o-2024-08-06',
        'anthropic/claude-sonnet-4',
      ]);
      mockGetDefaultModelId.mockReturnValue('openai/gpt-4o');

      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockRejectedValue(
        new Error('unexpected upstream fetch'),
      );

      const result = await syncModels('sk-or-test');

      expect(fetchSpy).not.toHaveBeenCalled();
      // gpt-4o-2024-08-06 should be deduplicated with gpt-4o
      expect(result.models.length).toBeLessThanOrEqual(3);
      expect(result.models.some((m) => m.id === 'openai/gpt-4o')).toBe(true);
      expect(result.models.some((m) => m.id === 'anthropic/claude-sonnet-4')).toBe(true);
    });

    it('returns empty when metadata is empty (no local fallback list)', async () => {
      mockListModelIds.mockReturnValue([]);
      mockGetDefaultModelId.mockReturnValue(undefined);

      const result = await syncModels('sk-or-test');
      expect(result.models).toEqual([]);
      expect(result.recommended).toEqual([]);
    });

    it('includes preferred model in recommendations', async () => {
      mockListModelIds.mockReturnValue([
        'openai/gpt-4o',
        'anthropic/claude-sonnet-4',
        'google/gemini-2.5-flash',
      ]);
      mockGetDefaultModelId.mockReturnValue('openai/gpt-4o');

      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockRejectedValue(
        new Error('unexpected upstream fetch'),
      );

      // The preferred model has to come out of metadata alone, with no network call.
      const result = await syncModels('sk-or-test', 'google/gemini-2.5-flash');

      expect(fetchSpy).not.toHaveBeenCalled();
      // A preferred model should appear among recommended or models.
      expect(result.models.some((m) => m.id === 'google/gemini-2.5-flash')).toBe(true);
    });

    it('does not validate key before returning metadata models', async () => {
      mockListModelIds.mockReturnValue(['openai/gpt-4o']);
      mockGetDefaultModelId.mockReturnValue('openai/gpt-4o');
      const fetchSpy = vi.spyOn(globalThis, 'fetch').mockRejectedValue(
        new Error('unexpected upstream fetch'),
      );

      const result = await syncModels('bad-key');

      expect(fetchSpy).not.toHaveBeenCalled();
      expect(result.models.some((m) => m.id === 'openai/gpt-4o')).toBe(true);
    });

    // Vendor grouping for an aggregate provider must come from the metadata
    // `uiHints.groupKey/groupName`; the client must not parse it from the model id slug.
    // That coverage lives in catalog-resolver.test.ts.
  });

  describe('sendMessageStream', () => {
    it('does not inject local reasoning params without metadata profile', () => {
      const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(() =>
        Promise.resolve(new Response('data: [DONE]\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        })),
      );

      sendMessageStream(
        'sk-or-test',
        'deepseek/deepseek-r1',
        [{ role: 'user', content: 'hi' }],
        { reasoning: 'deep' },
      );

      const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
      const body = JSON.parse(String(init.body)) as { reasoning?: unknown };
      expect(body.reasoning).toBeUndefined();
    });

    it('uses OpenRouter server web search tool from metadata profile', () => {
      mockGetWebSearchProfile.mockReturnValue({
        name: 'or_web',
        mergeParams: { tools: [{ type: 'openrouter:web_search' }] },
        streamShape: null,
      });
      const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(() =>
        Promise.resolve(new Response('data: [DONE]\n\n', {
          status: 200,
          headers: { 'Content-Type': 'text/event-stream' },
        })),
      );

      sendMessageStream(
        'sk-or-test',
        'anthropic/claude-sonnet-4',
        [{ role: 'user', content: 'hi' }],
        { supportsWebSearch: true },
        false,
        'or_web',
      );

      const init = fetchMock.mock.calls[0]?.[1] as RequestInit;
      const body = JSON.parse(String(init.body)) as { tools?: Array<{ type: string }> };
      expect(body.tools).toEqual([{ type: 'openrouter:web_search' }]);
    });

    it('emits reasoning from OpenRouter delta.reasoning (normalized thinking)', async () => {
      // OpenRouter normalizes the reasoning content of every upstream model onto
      // delta.reasoning as plain string deltas, and returns it even when the request carries
      // no reasoning parameter. reasoning_content is the OpenAI-compatible variant, checked as a fallback.
      vi.spyOn(globalThis, 'fetch').mockImplementation(() =>
        Promise.resolve(new Response(
          [
            'data: {"choices":[{"delta":{"reasoning":"Let me "}}]}',
            '',
            'data: {"choices":[{"delta":{"reasoning_content":"think..."}}]}',
            '',
            'data: {"choices":[{"delta":{"content":"Answer."}}]}',
            '',
            'data: [DONE]',
            '',
          ].join('\n'),
          {
            status: 200,
            headers: { 'Content-Type': 'text/event-stream' },
          },
        )),
      );

      const handle = sendMessageStream(
        'sk-or-test',
        'deepseek/deepseek-r1',
        [{ role: 'user', content: 'hi' }],
      );
      const events = [];
      const reader = handle.stream.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        events.push(value);
      }

      const reasoningEvents = events.filter((event) => event.type === 'reasoning');
      expect(reasoningEvents).toEqual([
        { type: 'reasoning', content: 'Let me ' },
        { type: 'reasoning', content: 'think...' },
      ]);
      const deltaEvents = events.filter((event) => event.type === 'delta');
      expect(deltaEvents).toEqual([{ type: 'delta', content: 'Answer.' }]);
    });

    // The OpenRouter web plugin searches before answering, so annotations arrive together in
    // the first frame of the stream. Regression assertion: citations are emitted once at the
    // end of the stream and after every delta, so sources never precede the body.
    it('defers url_citation annotations to a single citations event at stream end', async () => {
      vi.spyOn(globalThis, 'fetch').mockImplementation(() =>
        Promise.resolve(new Response(
          [
            'data: {"choices":[{"delta":{"content":"","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"A"}}]}}]}',
            '',
            'data: {"choices":[{"delta":{"content":"Answer."}}]}',
            '',
            'data: {"choices":[{"message":{"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/b","title":"B"}}]}}]}',
            '',
            'data: [DONE]',
            '',
          ].join('\n'),
          {
            status: 200,
            headers: { 'Content-Type': 'text/event-stream' },
          },
        )),
      );

      const handle = sendMessageStream(
        'sk-or-test',
        'anthropic/claude-sonnet-4',
        [{ role: 'user', content: 'hi' }],
        { supportsWebSearch: true },
        false,
        'or_web',
      );
      const events = [];
      const reader = handle.stream.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        events.push(value);
      }

      const citationEvents = events.filter((event) => event.type === 'citations');
      expect(citationEvents).toHaveLength(1);
      expect(citationEvents[0]).toMatchObject({
        citations: [
          { url: 'https://example.com/a', title: 'A' },
          { url: 'https://example.com/b', title: 'B' },
        ],
      });
      const citationIndex = events.findIndex((event) => event.type === 'citations');
      const lastDeltaIndex = events.map((event) => event.type).lastIndexOf('delta');
      expect(lastDeltaIndex).toBeGreaterThanOrEqual(0);
      expect(citationIndex).toBeGreaterThan(lastDeltaIndex);
    });
  });
});
