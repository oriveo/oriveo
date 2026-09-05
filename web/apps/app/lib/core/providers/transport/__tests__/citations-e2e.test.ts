/**
 * End-to-end unit test for the citations chain.
 *
 * strategy parses a chunk -> emits a 'citations' event -> readStream accumulates the snapshot ->
 * operations.ts writes ChatMessage.citations.
 *
 * This test covers the strategy -> readStream segment, the part most prone to regression.
 */

import { describe, expect, it } from 'vitest';
import type { StreamEvent } from '../../types';
import { anthropicMessagesStrategy } from '../strategies/anthropic-messages';
import { createStreamContext } from '../transport-strategy';
import { readStream } from '../../../../utils/chat-stream-utils';

function makeStreamFromChunks(chunks: string[]): ReadableStream<StreamEvent> {
  const ctx = createStreamContext();
  return new ReadableStream<StreamEvent>({
    start(controller) {
      for (const chunkData of chunks) {
        // Parse each chunk.
        const [eventType, body] = chunkData.split('|', 2);
        const result = anthropicMessagesStrategy.parseStreamChunk(eventType, body, ctx, null);
        if (result) {
          if (Array.isArray(result)) {
            for (const e of result) controller.enqueue(e);
          } else {
            controller.enqueue(result);
          }
        }
      }
      controller.enqueue({ type: 'done' });
      controller.close();
    },
  });
}

describe('citations end to end: an anthropic_messages stream through readStream', () => {
  it('leaves message.citations.length > 0 after a mocked SSE stream', async () => {
    const chunks = [
      `message_start|${JSON.stringify({ type: 'message_start', message: { usage: { input_tokens: 50 } } })}`,
      `content_block_delta|${JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: 'Sky is blue' } })}`,
      `content_block_start|${JSON.stringify({
        type: 'content_block_start',
        content_block: {
          type: 'web_search_tool_result',
          content: [
            { url: 'https://wikipedia.org/sky', title: 'Sky', cited_text: 'Sky appears blue due to scattering' },
            { url: 'https://nasa.gov/blue', title: 'NASA Blue Sky', cited_text: 'Rayleigh scattering' },
          ],
        },
      })}`,
      `message_delta|${JSON.stringify({ type: 'message_delta', usage: { output_tokens: 30 } })}`,
    ];

    const stream = makeStreamFromChunks(chunks);
    const collected: string[] = [];
    const result = await readStream(stream, '', (c) => {
      collected.push(c);
    });

    expect(result.fullText).toBe('Sky is blue');
    expect(result.citations).toBeDefined();
    expect(result.citations).toHaveLength(2);
    expect(result.citations?.[0].url).toBe('https://wikipedia.org/sky');
    expect(result.citations?.[1].url).toBe('https://nasa.gov/blue');
    // usage now carries a breakdown, with the older fields kept.
    expect(result.usage).toMatchObject({
      prompt_tokens: 50,
      completion_tokens: 30,
      total_tokens: 80,
      breakdown: {
        completionTokens: 30,
        cachedInputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
      },
    });
  });

  it('keeps the latest deduplicated snapshot when citations arrive several times in one stream', async () => {
    const ctx1 = createStreamContext();

    // Two content_block_start events where the second repeats a URL, so it is deduplicated.
    const stream = new ReadableStream<StreamEvent>({
      start(controller) {
        const r1 = anthropicMessagesStrategy.parseStreamChunk(
          'content_block_start',
          JSON.stringify({
            type: 'content_block_start',
            content_block: {
              type: 'web_search_tool_result',
              content: [{ url: 'https://a.com', title: 'A' }],
            },
          }),
          ctx1,
          null,
        );
        if (Array.isArray(r1)) {
          for (const e of r1) controller.enqueue(e);
        } else if (r1) {
          controller.enqueue(r1);
        }

        const r2 = anthropicMessagesStrategy.parseStreamChunk(
          'content_block_start',
          JSON.stringify({
            type: 'content_block_start',
            content_block: {
              type: 'web_search_tool_result',
              content: [
                { url: 'https://a.com', title: 'A (updated)' },
                { url: 'https://b.com', title: 'B' },
              ],
            },
          }),
          ctx1,
          null,
        );
        if (Array.isArray(r2)) {
          for (const e of r2) controller.enqueue(e);
        } else if (r2) {
          controller.enqueue(r2);
        }
        controller.enqueue({ type: 'done' });
        controller.close();
      },
    });

    const result = await readStream(stream, '', () => {});
    expect(result.citations).toHaveLength(2);
    // After deduplication A keeps the longer title (A -> A (updated)).
    expect(result.citations?.[0].title).toBe('A (updated)');
    expect(result.citations?.[1].url).toBe('https://b.com');
  });
});
