import { describe, expect, it } from 'vitest';
import { createProxyChunkParser } from '../proxy-chunk-parser';
import { mapContinuationForRecipe } from '../request-builders/continuation-replay';
import { validateContinuation } from '../request-preference/continuation';
import type { StreamEvent } from '../types';

/**
 * Tests for createProxyChunkParser, focused on the per-stream closure isolation invariant.
 *
 * The desktop main process runs several streams concurrently through one parser (one per
 * conversation). Anthropic sends input_tokens only in message_start and output_tokens in
 * message_delta, and the closure cache merges them across frames. Turning that into a shared
 * singleton closure would cross-contaminate usage between concurrent streams (A's message_delta
 * reading B's input_tokens). These tests pin the isolation down.
 */

function feed(parser: ReturnType<typeof createProxyChunkParser>, eventType: string | null, data: string): StreamEvent[] {
  const out = parser(eventType, data);
  if (out == null) return [];
  return Array.isArray(out) ? out : [out];
}

describe('createProxyChunkParser - per-stream closure isolation', () => {
  it('only forwards a contract-valid internal continuation event', () => {
    const parser = createProxyChunkParser('moonshot');
    expect(feed(parser, null, JSON.stringify({
      type: 'continuation',
      continuation: { kind: 'tool_loop', variant: 'fiber', step: 1, state: { completedMessages: completeToolMessages('opaque') } },
    }))).toEqual([{ type: 'continuation', continuation: { kind: 'tool_loop', variant: 'fiber', step: 1, state: { completedMessages: completeToolMessages('opaque') } } }]);
    expect(feed(parser, null, JSON.stringify({
      type: 'continuation', continuation: { kind: 'unknown', step: 1, state: {} },
    }))).toEqual([]);
  });

  it('keeps input_tokens of two concurrent Anthropic streams separate when frames are interleaved', () => {
    const a = createProxyChunkParser('anthropic');
    const b = createProxyChunkParser('anthropic');

    // Interleaved: A.message_start(120), B.message_start(999), A.message_delta, B.message_delta
    feed(a, 'message_start', JSON.stringify({
      type: 'message_start',
      message: { usage: { input_tokens: 120, cache_read_input_tokens: 30 } },
    }));
    feed(b, 'message_start', JSON.stringify({
      type: 'message_start',
      message: { usage: { input_tokens: 999 } },
    }));

    const aUsage = feed(a, 'message_delta', JSON.stringify({
      type: 'message_delta',
      usage: { output_tokens: 45 },
    })).find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    const bUsage = feed(b, 'message_delta', JSON.stringify({
      type: 'message_delta',
      usage: { output_tokens: 7 },
    })).find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;

    // A must see its own 120 (including cache_read=30) and never B's 999.
    expect(aUsage.usage.prompt_tokens).toBe(120);
    expect(aUsage.usage.completion_tokens).toBe(45);
    expect(aUsage.usage.breakdown?.cachedInputTokens).toBe(30);
    // B must see its own 999 and never A's 120.
    expect(bUsage.usage.prompt_tokens).toBe(999);
    expect(bUsage.usage.completion_tokens).toBe(7);
    expect(bUsage.usage.breakdown?.cachedInputTokens).toBe(0);
  });

  it('keeps citation accumulation of two concurrent Responses streams separate', () => {
    const a = createProxyChunkParser('openAI');
    const b = createProxyChunkParser('openAI');

    feed(a, 'response.output_text.annotation.added', JSON.stringify({
      annotation: { type: 'url_citation', url: 'https://a.example/1', title: 'A1' },
    }));
    const bEvents = feed(b, 'response.output_text.annotation.added', JSON.stringify({
      annotation: { type: 'url_citation', url: 'https://b.example/1', title: 'B1' },
    }));
    const bCitations = bEvents.find((e) => e.type === 'citations') as Extract<StreamEvent, { type: 'citations' }>;

    // B's citation snapshot holds only its own sources, none of A's.
    expect(bCitations.citations).toHaveLength(1);
    expect(bCitations.citations[0].url).toBe('https://b.example/1');
  });

  it('parses OpenAI-compatible usage plus the cached breakdown standalone', () => {
    const parser = createProxyChunkParser('openAI');
    const events = feed(parser, null, JSON.stringify({
      choices: [],
      usage: { prompt_tokens: 200, completion_tokens: 50, total_tokens: 250, prompt_tokens_details: { cached_tokens: 80 } },
    }));
    const usage = events.find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    expect(usage.usage.breakdown).toMatchObject({ promptTokens: 120, cachedInputTokens: 80, completionTokens: 50 });
  });

  // The Responses detail path is input_tokens_details / output_tokens_details, which is named
  // differently from prompt_tokens_details in chat-completions. Only the top-level token names
  // were once updated here, so cache reads were always 0 and cacheReadObserved always false. This
  // exercises the real browser/desktop production path (USE_PROXY, sendStreamProxy,
  // createProxyChunkParser), not transport/strategies.
  it('reads input_tokens_details.cached_tokens and output_tokens_details.reasoning_tokens for the Responses shape', () => {
    const parser = createProxyChunkParser('openAI');
    const events = feed(parser, 'response.completed', JSON.stringify({
      response: {
        usage: {
          input_tokens: 1000,
          output_tokens: 120,
          total_tokens: 1120,
          input_tokens_details: { cached_tokens: 900 },
          output_tokens_details: { reasoning_tokens: 64 },
        },
      },
    }));
    const usage = events.find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    expect(usage.usage.breakdown).toMatchObject({
      promptTokens: 100,
      cachedInputTokens: 900,
      completionTokens: 120,
      reasoningTokens: 64,
      cacheReadObserved: true,
    });
    expect(usage.usage.prompt_tokens).toBe(1000);
    expect(usage.usage.completion_tokens).toBe(120);
  });

  it('treats an explicit Responses cached_tokens: 0 as observed, and only a missing field as unobserved', () => {
    const observed = feed(createProxyChunkParser('openAI'), 'response.completed', JSON.stringify({
      response: { usage: { input_tokens: 500, output_tokens: 10, input_tokens_details: { cached_tokens: 0 } } },
    })).find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    expect(observed.usage.breakdown).toMatchObject({ cachedInputTokens: 0, cacheReadObserved: true });

    const missing = feed(createProxyChunkParser('openAI'), 'response.completed', JSON.stringify({
      response: { usage: { input_tokens: 500, output_tokens: 10 } },
    })).find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    expect(missing.usage.breakdown?.cacheReadObserved).toBe(false);
  });

  // Zeroing regression: parseUsageGrok reads only prompt_tokens/completion_tokens and has **no**
  // input_tokens fallback. Grok over /responses is a real production path, and without the
  // normalization the whole usage record comes out as 0/0.
  it('keeps usage non-zero for Grok over Responses and still converts cost_in_usd_ticks by 1e10', () => {
    const events = feed(createProxyChunkParser('grok'), 'response.completed', JSON.stringify({
      response: {
        usage: {
          input_tokens: 800,
          output_tokens: 200,
          input_tokens_details: { cached_tokens: 300 },
          output_tokens_details: { reasoning_tokens: 40 },
          cost_in_usd_ticks: 37_756_000,
        },
      },
    }));
    const usage = events.find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    expect(usage.usage.breakdown).toMatchObject({
      promptTokens: 500,
      cachedInputTokens: 300,
      completionTokens: 200,
      reasoningTokens: 40,
      cacheReadObserved: true,
    });
    expect(usage.usage.breakdown?.upstreamCost).toBeCloseTo(0.0037756, 9);
  });

  it('recipe-gated Responses producer only persists a completed response id', () => {
    const parser = createProxyChunkParser('openAI', { kind: 'previous_id', protocol: 'openai_responses', responseParserKind: 'openai_responses_reasoning_v1' });
    expect(feed(parser, 'response.created', JSON.stringify({ response: { id: 'resp_pending', status: 'in_progress' } }))).toEqual([]);
    expect(feed(parser, 'response.completed', JSON.stringify({ response: { id: 'resp_done', status: 'completed' } }))).toContainEqual({
      type: 'continuation', continuation: { kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_done' } },
    });
  });

  it('recipe-gated Anthropic producer reconstructs signed blocks only at message_stop', () => {
    const parser = createProxyChunkParser('anthropic', { kind: 'replay_blocks', protocol: 'anthropic_messages', responseParserKind: 'anthropic_thinking_v1' });
    feed(parser, 'content_block_start', JSON.stringify({ type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '', signature: '' } }));
    feed(parser, 'content_block_delta', JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'opaque thought' } }));
    feed(parser, 'content_block_delta', JSON.stringify({ type: 'content_block_delta', index: 0, delta: { type: 'signature_delta', signature: 'opaque-signature' } }));
    expect(feed(parser, 'message_stop', JSON.stringify({ type: 'message_stop' }))).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_blocks', step: 1, state: { blocks: [{ type: 'thinking', thinking: 'opaque thought', signature: 'opaque-signature' }] } },
    });
  });

  it('MiniMax Anthropic non-stream preserves server tool blocks, citations and exact continuation', () => {
    const config = {
      kind: 'replay_blocks', protocol: 'anthropic_messages', responseParserKind: 'minimax_anthropic_web_v1',
    };
    const blocks = [
      { type: 'thinking', thinking: 'opaque thought', signature: 'opaque-signature' },
      { type: 'server_tool_use', id: 'web_1', name: 'web_search', input: { query: 'news' } },
      { type: 'web_search_tool_result', tool_use_id: 'web_1', content: [{
        type: 'web_search_result', title: 'Example', url: 'https://example.com/news',
        page_age: '2026-08-23', content: 'provider snippet',
      }] },
      { type: 'text', text: 'final answer' },
    ];
    const events = feed(createProxyChunkParser('miniMax', config), null, JSON.stringify({
      type: 'message', content: blocks,
    }));
    expect(events).toContainEqual({ type: 'reasoning', content: 'opaque thought' });
    expect(events).toContainEqual({ type: 'delta', content: 'final answer' });
    expect(events).toContainEqual({
      type: 'citations', citations: [{
        url: 'https://example.com/news', title: 'Example', snippet: 'provider snippet',
      }],
    });
    expect(events).toContainEqual({ type: 'tool_result', tool: 'web_search', summary: 'Example', step: 2 });
    expect(events).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_blocks', step: 1, state: { blocks } },
    });

    const malformed = feed(createProxyChunkParser('miniMax', config), null, JSON.stringify({
      type: 'message', content: [{ type: 'unknown_provider_block', opaque: true }],
    }));
    expect(malformed.some((event) => event.type === 'continuation')).toBe(false);
  });

  it('recipe-gated Gemini producer preserves thoughtSignature in the model Content block', () => {
    const parser = createProxyChunkParser('gemini', { kind: 'replay_blocks', protocol: 'gemini_generate_content', responseParserKind: 'gemini_thinking_v1' });
    expect(feed(parser, null, JSON.stringify({ candidates: [{ content: { role: 'model', parts: [{ functionCall: { name: 'lookup', args: { q: 'news' } }, thoughtSignature: 'opaque-signature' }] }, finishReason: 'STOP' }] }))).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_blocks', step: 1, state: { blocks: [{ role: 'model', parts: [{ functionCall: { name: 'lookup', args: { q: 'news' } }, thoughtSignature: 'opaque-signature' }] }] } },
    });
  });

  it('recipe-gated OpenRouter and Moonshot producers preserve protocol-exact assistant messages', () => {
    const openRouter = createProxyChunkParser('openRouter', { kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'openrouter_reasoning_v1' });
    feed(openRouter, null, JSON.stringify({ choices: [{ delta: {
      reasoning_details: [{ type: 'reasoning.summary', summary: 'first' }],
    } }] }));
    feed(openRouter, null, JSON.stringify({ choices: [{ delta: {
      reasoning_details: [{ type: 'reasoning.summary', summary: 'second' }],
    } }] }));
    feed(openRouter, null, JSON.stringify({ choices: [{ delta: {
      reasoning_details: [{ index: 7, type: 'reasoning.encrypted', data: 'opa' }],
      tool_calls: [{ index: 0, id: 'call_or', type: 'function', function: { name: 'look', arguments: '{"q"' } }],
    } }] }));
    feed(openRouter, null, JSON.stringify({ choices: [{ delta: {
      reasoning_details: [{ index: 7, data: 'que' }],
      tool_calls: [{ index: 0, function: { name: 'up', arguments: ':"news"}' } }],
    } }] }));
    const openRouterDone = feed(openRouter, null, JSON.stringify({ choices: [{ delta: { content: 'answer' }, finish_reason: 'stop' }] }));
    const openRouterContinuation = openRouterDone.find((event) => event.type === 'continuation');
    expect(openRouterContinuation).toEqual({
      type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{
        role: 'assistant', content: 'answer',
        reasoning_details: [
          { type: 'reasoning.summary', summary: 'first' },
          { type: 'reasoning.summary', summary: 'second' },
          { index: 7, type: 'reasoning.encrypted', data: 'opaque' },
        ],
        tool_calls: [{ id: 'call_or', type: 'function', function: { name: 'lookup', arguments: '{"q":"news"}' } }],
      }] } },
    });
    expect(mapContinuationForRecipe({
      id: 'openrouter.chat.reasoning.v1', providerKind: 'openRouter', capability: 'reasoning',
      executionKind: 'request_overlay', requestOps: [], continuationKind: 'replay_reasoning',
      responseParserKind: 'openrouter_reasoning_v1', transport: { protocol: 'openai_chat' },
    }, openRouterContinuation?.type === 'continuation' ? openRouterContinuation.continuation : null)).toEqual({
      accepted: true, target: 'message_append',
      messages: (openRouterContinuation as Extract<StreamEvent, { type: 'continuation' }>).continuation.state.assistantMessages,
    });

    const moonshot = createProxyChunkParser('moonshot', { kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'moonshot_reasoning_v1' });
    feed(moonshot, null, JSON.stringify({ choices: [{ delta: { reasoning_content: 'opaque thought', tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{"q"' } }] } }] }));
    const moonshotDone = feed(moonshot, null, JSON.stringify({ choices: [{ delta: { content: 'answer', tool_calls: [{ index: 0, function: { arguments: ':"news"}' } }] }, finish_reason: 'tool_calls' }] }));
    expect(moonshotDone).toContainEqual({ type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{ role: 'assistant', content: 'answer', reasoning_content: 'opaque thought', tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{"q":"news"}' } }] }] } } });
  });

  it('OpenRouter indexed detail conflict and malformed tool fragment fail closed', () => {
    const config = {
      kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'openrouter_reasoning_v1',
    };
    const conflict = createProxyChunkParser('openRouter', config);
    feed(conflict, null, JSON.stringify({ choices: [{ delta: {
      reasoning_details: [{ index: 0, type: 'reasoning.encrypted', data: 'opaque' }],
    } }] }));
    feed(conflict, null, JSON.stringify({ choices: [{ delta: {
      reasoning_details: [{ index: 0, type: 'reasoning.summary', summary: 'conflict' }],
    } }] }));
    expect(feed(conflict, null, JSON.stringify({ choices: [{ delta: { content: 'answer' }, finish_reason: 'stop' }] }))
      .some((event) => event.type === 'continuation')).toBe(false);

    const malformedTool = createProxyChunkParser('openRouter', config);
    expect(feed(malformedTool, null, JSON.stringify({ choices: [{ message: {
      content: 'answer', reasoning_details: [{ type: 'reasoning.encrypted', data: 'opaque' }],
      tool_calls: [{ index: 0, type: 'function', function: { arguments: '{}' } }],
    }, finish_reason: 'tool_calls' }] })).some((event) => event.type === 'continuation')).toBe(false);
  });

  it('OpenRouter non-stream message preserves ordered details and complete tool_calls', () => {
    const parser = createProxyChunkParser('openRouter', {
      kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'openrouter_reasoning_v1',
    });
    expect(feed(parser, null, JSON.stringify({ choices: [{ message: {
      content: 'answer',
      reasoning_details: [
        { type: 'reasoning.summary', summary: 'first' },
        { type: 'reasoning.encrypted', data: 'opaque' },
      ],
      tool_calls: [{ id: 'call_nonstream', type: 'function', function: { name: 'lookup', arguments: '{"q":"news"}' } }],
    }, finish_reason: 'tool_calls' }] }))).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{
        role: 'assistant', content: 'answer',
        reasoning_details: [
          { type: 'reasoning.summary', summary: 'first' },
          { type: 'reasoning.encrypted', data: 'opaque' },
        ],
        tool_calls: [{ id: 'call_nonstream', type: 'function', function: { name: 'lookup', arguments: '{"q":"news"}' } }],
      }] } },
    });
  });

  it('MiniMax streaming preserves ordered content, reasoning_details and tool_calls into replay', () => {
    const parser = createProxyChunkParser('miniMax', {
      kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'minimax_reasoning_v1',
    });
    feed(parser, null, JSON.stringify({ choices: [{ delta: {
      content: '',
      reasoning_details: [{ index: 0, type: 'reasoning.encrypted', data: 'opaque-' }],
      tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{"q"' } }],
    } }] }));
    const completed = feed(parser, null, JSON.stringify({ choices: [{ delta: {
      content: 'answer',
      reasoning_details: [{ index: 0, type: 'reasoning.encrypted', data: 'state' }],
      tool_calls: [{ index: 0, function: { arguments: ':"news"}' } }],
    }, finish_reason: 'tool_calls' }] }));
    const continuation = completed.find((event) => event.type === 'continuation');
    expect(continuation).toEqual({
      type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{
        role: 'assistant', content: 'answer',
        reasoning_details: [{ index: 0, type: 'reasoning.encrypted', data: 'opaque-state' }],
        tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{"q":"news"}' } }],
      }] } },
    });
    expect(mapContinuationForRecipe({
      id: 'minimax.reasoning.v1', providerKind: 'miniMax', capability: 'reasoning',
      executionKind: 'request_overlay', requestOps: [], continuationKind: 'replay_reasoning',
      responseParserKind: 'minimax_reasoning_v1', transport: { protocol: 'openai_chat' },
    }, continuation?.type === 'continuation' ? continuation.continuation : null)).toEqual({
      accepted: true, target: 'message_append',
      messages: (continuation as Extract<StreamEvent, { type: 'continuation' }>).continuation.state.assistantMessages,
    });
  });

  it('MiniMax non-stream preserves null content and malformed opaque state fails closed', () => {
    const config = {
      kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'minimax_reasoning_v1',
    };
    const valid = feed(createProxyChunkParser('miniMax', config), null, JSON.stringify({ choices: [{
      message: {
        role: 'assistant', content: null,
        reasoning_details: [{ type: 'reasoning.encrypted', data: 'opaque' }],
        tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{}' } }],
      }, finish_reason: 'tool_calls',
    }] }));
    expect(valid).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{
        role: 'assistant', content: null,
        reasoning_details: [{ type: 'reasoning.encrypted', data: 'opaque' }],
        tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{}' } }],
      }] } },
    });

    for (const message of [
      { role: 'assistant', content: 1, reasoning_details: [{ data: 'opaque' }] },
      { role: 'assistant', content: '', reasoning_details: ['opaque'] },
      { role: 'assistant', content: '', reasoning_details: [{ data: 'opaque' }], tool_calls: [{ id: 'call_1', type: 'function', function: { name: '', arguments: '{}' } }] },
    ]) {
      expect(feed(createProxyChunkParser('miniMax', config), null, JSON.stringify({
        choices: [{ message, finish_reason: 'stop' }],
      })).some((event) => event.type === 'continuation')).toBe(false);
    }
  });
});

function completeToolMessages(content: string) {
  return [
    { role: 'assistant', content: '', reasoning_content: 'opaque reasoning', tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'web_search', arguments: '{"q":"news"}' } }] },
    { role: 'tool', tool_call_id: 'call_1', name: 'web_search', content },
  ];
}

describe('createProxyChunkParser - content block arrays (Mistral Magistral thinking protocol)', () => {
  it('rebuilds ordered thinking/text and tool_calls for a streaming continuation and carries them unchanged into the next request', () => {
    const parser = createProxyChunkParser('mistral', {
      kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'mistral_reasoning_v1',
    });
    feed(parser, null, JSON.stringify({ choices: [{ delta: { role: 'assistant', content: '' } }] }));
    feed(parser, null, JSON.stringify({ choices: [{ delta: { content: [
      { type: 'thinking', thinking: [{ type: 'text', text: 'thinking A' }] },
    ] } }] }));
    feed(parser, null, JSON.stringify({ choices: [{ delta: {
      content: [
        { type: 'thinking', thinking: [{ type: 'text', text: 'thinking B' }], closed: true },
        { type: 'text', text: 'body ' },
      ],
      tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{"q"' } }],
    } }] }));
    const completed = feed(parser, null, JSON.stringify({ choices: [{ delta: {
      content: 'text', tool_calls: [{ index: 0, function: { arguments: ':"news"}' } }],
    }, finish_reason: 'tool_calls' }] }));
    const continuation = completed.find((event) => event.type === 'continuation');
    expect(continuation).toEqual({
      type: 'continuation',
      continuation: {
        kind: 'replay_reasoning', step: 1,
        state: { assistantMessages: [{
          role: 'assistant',
          content: [
            { type: 'thinking', thinking: [{ type: 'text', text: 'thinking A' }, { type: 'text', text: 'thinking B' }], closed: true },
            { type: 'text', text: 'body text' },
          ],
          tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'lookup', arguments: '{"q":"news"}' } }],
        }] },
      },
    });

    const mapped = mapContinuationForRecipe({
      id: 'mistral.chat.reasoning.v1', providerKind: 'mistral', capability: 'reasoning',
      executionKind: 'request_overlay', requestOps: [], continuationKind: 'replay_reasoning',
      responseParserKind: 'mistral_reasoning_v1', transport: { protocol: 'openai_chat' },
    }, continuation?.type === 'continuation' ? continuation.continuation : null);
    expect(mapped).toEqual({
      accepted: true, target: 'message_append',
      messages: (continuation as Extract<StreamEvent, { type: 'continuation' }>).continuation.state.assistantMessages,
    });
  });

  it('preserves both a plain string and a full block array for a non-streaming continuation', () => {
    const config = { kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'mistral_reasoning_v1' };
    const stringEvents = feed(createProxyChunkParser('mistral', config), null, JSON.stringify({
      choices: [{ message: { role: 'assistant', content: 'the complete body text' }, finish_reason: 'stop' }],
    }));
    expect(stringEvents).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [
        { role: 'assistant', content: 'the complete body text' },
      ] } },
    });

    const blocks = [
      { type: 'thinking', thinking: [{ type: 'text', text: 'the complete thinking' }], closed: true },
      { type: 'text', text: 'the complete body text' },
    ];
    const blockEvents = feed(createProxyChunkParser('mistral', config), null, JSON.stringify({
      choices: [{ message: { role: 'assistant', content: blocks }, finish_reason: 'stop' }],
    }));
    expect(blockEvents).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [
        { role: 'assistant', content: blocks },
      ] } },
    });
  });

  it('Mistral generic validator only accepts the exact message shape and an unknown parser still fails closed', () => {
    const valid = { kind: 'replay_reasoning', step: 1, state: { assistantMessages: [{
      role: 'assistant', content: [{ type: 'thinking', thinking: [], closed: true }, { type: 'text', text: 'answer' }],
    }] } };
    expect(validateContinuation(valid)).toEqual({ accepted: true, reason: null });
    expect(validateContinuation({ ...valid, state: { assistantMessages: [{
      role: 'assistant', content: [{ type: 'thinking', thinking: [], closed: true, provider_payload: 'opaque' }],
    }] } })).toEqual({ accepted: false, reason: 'invalid_reasoning_replay_state' });

    const unknown = createProxyChunkParser('mistral', {
      kind: 'replay_reasoning', protocol: 'openai_chat', responseParserKind: 'unknown_reasoning_v1',
    });
    expect(feed(unknown, null, JSON.stringify({ choices: [{ message: { content: 'answer' }, finish_reason: 'stop' }] }))).toEqual([
      { type: 'delta', content: 'answer' },
    ]);
  });

  it('streaming: thinking blocks become reasoning, an empty closing array emits nothing, and text falls back to a string', () => {
    const parser = createProxyChunkParser('mistral');

    // role frame: content is an empty string
    expect(feed(parser, null, JSON.stringify({
      choices: [{ delta: { role: 'assistant', content: '' } }],
    }))).toEqual([]);

    // Thinking phase, with a non-standard "p" field mixed in that should simply be ignored.
    expect(feed(parser, null, JSON.stringify({
      p: 'noise',
      choices: [{ delta: { content: [{ type: 'thinking', thinking: [{ type: 'text', text: 'token by token' }] }] } }],
    }))).toEqual([{ type: 'reasoning', content: 'token by token' }]);

    // End-of-thinking marker: an empty thinking array.
    expect(feed(parser, null, JSON.stringify({
      choices: [{ delta: { content: [{ type: 'thinking', thinking: [] }] } }],
    }))).toEqual([]);

    // Text falls back to a plain string delta.
    expect(feed(parser, null, JSON.stringify({
      choices: [{ delta: { content: 'body text' } }],
    }))).toEqual([{ type: 'delta', content: 'body text' }]);
  });

  it('streaming finish chunk: usage follows the OpenAI-compatible template (prompt_tokens_details.cached_tokens)', () => {
    const parser = createProxyChunkParser('mistral');
    const events = feed(parser, null, JSON.stringify({
      choices: [{ delta: { content: '' }, finish_reason: 'stop' }],
      usage: {
        prompt_tokens: 100,
        completion_tokens: 40,
        total_tokens: 140,
        prompt_tokens_details: { cached_tokens: 25 },
      },
    }));
    const usage = events.find((e) => e.type === 'usage') as Extract<StreamEvent, { type: 'usage' }>;
    expect(usage.usage.prompt_tokens).toBe(100);
    expect(usage.usage.breakdown).toMatchObject({
      promptTokens: 75,
      cachedInputTokens: 25,
      completionTokens: 40,
    });
  });

  it('non-streaming: a message.content block array collapses into reasoning plus delta', () => {
    const parser = createProxyChunkParser('mistral');
    const events = feed(parser, null, JSON.stringify({
      choices: [{
        message: {
          content: [
            { type: 'thinking', thinking: [{ type: 'text', text: 'the complete thinking' }], closed: true },
            { type: 'text', text: 'body text' },
          ],
        },
      }],
    }));
    expect(events).toEqual([
      { type: 'reasoning', content: 'the complete thinking' },
      { type: 'delta', content: 'body text' },
    ]);
  });

  it('block array parsing is provider independent: relay also receives thinking blocks', () => {
    const parser = createProxyChunkParser('relay');
    const events = feed(parser, null, JSON.stringify({
      choices: [{ delta: { content: [
        { type: 'thinking', thinking: [{ type: 'text', text: 'r' }] },
        { type: 'text', text: 'body' },
      ] } }],
    }));
    expect(events).toEqual([
      { type: 'reasoning', content: 'r' },
      { type: 'delta', content: 'body' },
    ]);
  });
});

describe('createProxyChunkParser - Library tool events', () => {
  it('forwards OpenAI streaming tool_calls deltas and keeps the text in the same frame', () => {
    const parser = createProxyChunkParser('openAI');

    expect(feed(parser, null, JSON.stringify({
      choices: [{
        delta: {
          content: 'let me search first',
          tool_calls: [{
            index: 0,
            id: 'call-1',
            type: 'function',
            function: { name: 'library_search', arguments: '{"query"' },
          }],
        },
      }],
    }))).toEqual([
      {
        type: 'tool_calls',
        toolCalls: [{
          index: 0,
          id: 'call-1',
          type: 'function',
          name: 'library_search',
          arguments: '{"query"',
        }],
      },
      { type: 'delta', content: 'let me search first' },
    ]);

    expect(feed(parser, null, JSON.stringify({
      choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: ':"pricing"}' } }] } }],
    }))).toEqual([{
      type: 'tool_calls',
      toolCalls: [{ index: 0, arguments: ':"pricing"}' }],
    }]);
  });

  it('normalizes non-streaming message.tool_calls by array position when index is missing', () => {
    const parser = createProxyChunkParser('openAI');
    expect(feed(parser, null, JSON.stringify({
      choices: [{
        message: {
          tool_calls: [{
            id: 'call-2',
            type: 'function',
            function: { name: 'library_read', arguments: '{}' },
          }],
        },
      }],
    }))).toEqual([{
      type: 'tool_calls',
      toolCalls: [{
        index: 0,
        id: 'call-2',
        type: 'function',
        name: 'library_read',
        arguments: '{}',
      }],
    }]);
  });

  it('validates and forwards a well-formed local Library event', () => {
    const parser = createProxyChunkParser('openAI');
    expect(feed(parser, null, JSON.stringify({
      type: 'tool_calls',
      toolCalls: [{
        index: 0,
        id: 'call-3',
        type: 'function',
        name: 'library_list',
        arguments: '{}',
      }],
    }))).toEqual([{
      type: 'tool_calls',
      toolCalls: [{
        index: 0,
        id: 'call-3',
        type: 'function',
        name: 'library_list',
        arguments: '{}',
      }],
    }]);
    expect(feed(parser, null, JSON.stringify({
      type: 'tool_call',
      tool: 'library_search',
      args: { query: 'pricing' },
      step: 1,
    }))).toEqual([{
      type: 'tool_call',
      tool: 'library_search',
      args: { query: 'pricing' },
      step: 1,
    }]);
    expect(feed(parser, null, JSON.stringify({
      type: 'tool_result',
      tool: 'library_search',
      summary: '3 matches',
      step: 1,
    }))).toEqual([{
      type: 'tool_result',
      tool: 'library_search',
      summary: '3 matches',
      step: 1,
    }]);
    expect(feed(parser, null, JSON.stringify({
      type: 'confirm_required',
      reason: 'sensitive',
      detail: { kinds: ['secret'] },
    }))).toEqual([{
      type: 'confirm_required',
      reason: 'sensitive',
      detail: { kinds: ['secret'] },
    }]);
  });

  it('ignores a local Library event with an invalid payload', () => {
    const parser = createProxyChunkParser('openAI');
    expect(feed(parser, null, JSON.stringify({
      type: 'tool_call', tool: '', args: [], step: -1,
    }))).toEqual([]);
    expect(feed(parser, null, JSON.stringify({
      type: 'confirm_required', reason: 'unknown', detail: 'raw',
    }))).toEqual([]);
  });
});
