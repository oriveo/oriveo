/**
 * Unit tests for chunk fixture parsing in the openai_responses strategy.
 *
 * Covers streamShape.citationsArrayPath going through readPath, which supports dot notation.
 */

import { describe, expect, it } from 'vitest';
import { openAIResponsesStrategy } from '../strategies/openai-responses';
import { createStreamContext } from '../transport-strategy';

function toArr(result: ReturnType<typeof openAIResponsesStrategy.parseStreamChunk>) {
  if (result == null) return [];
  return Array.isArray(result) ? result : [result];
}

describe('openAIResponsesStrategy.parseStreamChunk', () => {
  it('chunk 1: response.output_text.delta emit delta', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIResponsesStrategy.parseStreamChunk(
        'response.output_text.delta',
        JSON.stringify({ delta: 'Hello' }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([{ type: 'delta', content: 'Hello' }]);
  });

  it('chunk 2: annotation url_citation emit citations event', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIResponsesStrategy.parseStreamChunk(
        'response.output_text.annotations.added',
        JSON.stringify({
          annotation: {
            type: 'url_citation',
            url: 'https://example.com',
            title: 'Example',
            start_index: 0,
            end_index: 10,
          },
        }),
        ctx,
        null,
      ),
    );
    const cit = events.find((e) => e.type === 'citations');
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations[0].url).toBe('https://example.com');
      expect(cit.citations[0].startIndex).toBe(0);
      expect(cit.citations[0].endIndex).toBe(10);
    }
  });

  it('chunk 3: response.completed emit usage', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIResponsesStrategy.parseStreamChunk(
        'response.completed',
        JSON.stringify({
          response: {
            usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 },
          },
        }),
        ctx,
        null,
      ),
    );
    const usage = events.find((e) => e.type === 'usage');
    expect(usage).toBeDefined();
    if (usage?.type === 'usage') {
      expect(usage.usage.prompt_tokens).toBe(10);
      expect(usage.usage.completion_tokens).toBe(20);
    }
  });

  it('streamShape.citationsArrayPath uses readPath and supports dot notation', () => {
    const ctx = createStreamContext();
    const events = toArr(
      openAIResponsesStrategy.parseStreamChunk(
        'response.output_item.added',
        JSON.stringify({
          item: {
            type: 'message',
            citations: [{ url: 'https://from-dot.com', title: 'Dot' }],
          },
        }),
        ctx,
        { citationsArrayPath: 'item.citations' },
      ),
    );
    const cit = events.find((e) => e.type === 'citations');
    expect(cit).toBeDefined();
    if (cit?.type === 'citations') {
      expect(cit.citations[0].url).toBe('https://from-dot.com');
    }
  });
});
