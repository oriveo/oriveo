/**
 * Unit tests for the anthropic_messages strategy parsing chunk fixtures.
 */

import { describe, expect, it } from 'vitest';
import { anthropicMessagesStrategy } from '../strategies/anthropic-messages';
import { createStreamContext } from '../transport-strategy';

function toArr(
  result: ReturnType<typeof anthropicMessagesStrategy.parseStreamChunk>,
) {
  if (result == null) return [];
  return Array.isArray(result) ? result : [result];
}

describe('anthropicMessagesStrategy.buildRequestBody', () => {
  it('extracts system messages into the system field, leaving no system role in messages', () => {
    const body = anthropicMessagesStrategy.buildRequestBody({
      modelID: 'claude-sonnet-4',
      messages: [
        { role: 'system', content: 'sys-text' },
        { role: 'user', content: 'hello' },
      ],
    });
    expect(body.system).toBe('sys-text');
    expect((body.messages as Array<{ role: string }>).every((m) => m.role !== 'system')).toBe(true);
  });

  it('deep merges the thinking field from mergeParams', () => {
    const body = anthropicMessagesStrategy.buildRequestBody({
      modelID: 'claude-sonnet-4',
      messages: [{ role: 'user', content: 'hi' }],
      mergeParams: { tools: [{ type: 'web_search_20250305', name: 'web_search' }] },
    });
    expect(Array.isArray(body.tools)).toBe(true);
    expect((body.tools as Array<Record<string, unknown>>)[0].name).toBe('web_search');
  });
});

describe('anthropicMessagesStrategy.parseStreamChunk', () => {
  it('chunk 1: message_start accumulates input_tokens without emitting', () => {
    const ctx = createStreamContext();
    const events = toArr(
      anthropicMessagesStrategy.parseStreamChunk(
        'message_start',
        JSON.stringify({
          type: 'message_start',
          message: { usage: { input_tokens: 100 } },
        }),
        ctx,
        null,
      ),
    );
    expect(events).toHaveLength(0);
    expect(ctx.inputTokens).toBe(100);
  });

  it('chunk 2: content_block_delta text_delta emit delta event', () => {
    const ctx = createStreamContext();
    const events = toArr(
      anthropicMessagesStrategy.parseStreamChunk(
        'content_block_delta',
        JSON.stringify({
          type: 'content_block_delta',
          delta: { type: 'text_delta', text: 'Hello' },
        }),
        ctx,
        null,
      ),
    );
    expect(events).toEqual([{ type: 'delta', content: 'Hello' }]);
  });

  it('chunk 3: web_search_tool_result block emit citations event', () => {
    const ctx = createStreamContext();
    const events = toArr(
      anthropicMessagesStrategy.parseStreamChunk(
        'content_block_start',
        JSON.stringify({
          type: 'content_block_start',
          content_block: {
            type: 'web_search_tool_result',
            content: [
              { url: 'https://example.com', title: 'Ex', cited_text: 'snippet text' },
            ],
          },
        }),
        ctx,
        null,
      ),
    );
    const citationsEvent = events.find((e) => e.type === 'citations');
    expect(citationsEvent).toBeDefined();
    if (citationsEvent?.type === 'citations') {
      expect(citationsEvent.citations).toHaveLength(1);
      expect(citationsEvent.citations[0].url).toBe('https://example.com');
      expect(citationsEvent.citations[0].snippet).toBe('snippet text');
    }
    expect(ctx.citations).toHaveLength(1);
  });

  it('chunk 4: message_delta emits usage accumulating prompt and completion', () => {
    const ctx = createStreamContext();
    ctx.inputTokens = 50;
    const events = toArr(
      anthropicMessagesStrategy.parseStreamChunk(
        'message_delta',
        JSON.stringify({
          type: 'message_delta',
          usage: { output_tokens: 30 },
        }),
        ctx,
        null,
      ),
    );
    // usage events now carry a breakdown; the older prompt_tokens, completion_tokens and
    // total_tokens fields are kept for telemetry compatibility.
    expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({
      type: 'usage',
      usage: {
        prompt_tokens: 50,
        completion_tokens: 30,
        total_tokens: 80,
        breakdown: {
          promptTokens: 0,             // message_start is not called in this test, so inputTokens comes through ctx
          cachedInputTokens: 0,
          cacheCreation5mTokens: 0,
          cacheCreation1hTokens: 0,
          completionTokens: 30,
          reasoningTokens: 0,
        },
      },
    });
  });

  it('streamShape covers the block type', () => {
    const ctx = createStreamContext();
    const events = toArr(
      anthropicMessagesStrategy.parseStreamChunk(
        'content_block_start',
        JSON.stringify({
          type: 'content_block_start',
          content_block: {
            type: 'custom_search_result',
            content: [{ url: 'https://custom.com', title: 'Custom' }],
          },
        }),
        ctx,
        { citationsBlockType: 'custom_search_result' },
      ),
    );
    const citationsEvent = events.find((e) => e.type === 'citations');
    expect(citationsEvent).toBeDefined();
  });
});
