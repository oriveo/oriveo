import { describe, expect, it } from 'vitest';
import { createProxyChunkParser } from '../proxy-chunk-parser';
import { anthropicMessagesStrategy } from '../transport/strategies/anthropic-messages';
import { openAIResponsesStrategy } from '../transport/strategies/openai-responses';
import { createStreamContext } from '../transport/transport-strategy';
import type { StreamEvent } from '../types';

/**
 * The "web search has started" signal.
 *
 * The frames are copied from recordings of real Anthropic and OpenAI Responses web-search
 * streams, not reverse-engineered from what the parser accepts. Each one goes in through a
 * production parsing entry point: the proxy parser and the direct strategy are two separate
 * paths, so each gets its own assertion.
 */
const ANTHROPIC_SEARCH_START =
  '{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"srvtoolu_01bug3W20DWB0LwoUvGoH0nW","name":"web_search","input":{}}}';
const RESPONSES_SEARCH_START =
  '{"type":"response.output_item.added","item":{"id":"ws_0db23ea2a095e5de016abc91770ff087d09539b3f4e190a5cf","type":"web_search_call","status":"in_progress"},"output_index":0,"sequence_number":2}';

const ACTIVITY: StreamEvent = { type: 'activity', activity: 'web_search' };

function toArr(out: StreamEvent | StreamEvent[] | null | undefined): StreamEvent[] {
  if (out == null) return [];
  return Array.isArray(out) ? out : [out];
}

function activities(events: StreamEvent[]): StreamEvent[] {
  return events.filter((event) => event.type === 'activity');
}

// The input frames that follow the server_tool_use block in the same recording.
const ANTHROPIC_SEARCH_INPUT = [
  '{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{"}}',
  '{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"query"}}',
];

describe('Anthropic server_tool_use input is not a client tool call', () => {
  it('never turns the input_json_delta of web_search into tool_calls, in the proxy parser or the direct strategy', () => {
    const proxy = createProxyChunkParser('anthropic');
    const ctx = createStreamContext('anthropic');
    const seen: StreamEvent[] = [
      ...toArr(proxy('content_block_start', ANTHROPIC_SEARCH_START)),
      ...toArr(anthropicMessagesStrategy.parseStreamChunk('content_block_start', ANTHROPIC_SEARCH_START, ctx, null)),
    ];
    for (const frame of ANTHROPIC_SEARCH_INPUT) {
      seen.push(...toArr(proxy('content_block_delta', frame)));
      seen.push(...toArr(anthropicMessagesStrategy.parseStreamChunk('content_block_delta', frame, ctx, null)));
    }
    expect(
      seen.filter((event) => event.type === 'tool_calls'),
      'The input of the built-in web search was read as a client tool call; the reply would end with an extra unknown_tool card that nothing can execute.',
    ).toEqual([]);
  });

  it('still accumulates the input of a real tool_use block', () => {
    const proxy = createProxyChunkParser('anthropic');
    const start = JSON.stringify({
      type: 'content_block_start',
      index: 2,
      content_block: { type: 'tool_use', id: 'toolu_1', name: 'lookup', input: {} },
    });
    const delta = JSON.stringify({
      type: 'content_block_delta',
      index: 2,
      delta: { type: 'input_json_delta', partial_json: '{"q":1}' },
    });
    expect(toArr(proxy('content_block_start', start))).toEqual([
      { type: 'tool_calls', toolCalls: [{ index: 2, id: 'toolu_1', type: 'function', name: 'lookup' }] },
    ]);
    expect(toArr(proxy('content_block_delta', delta))).toEqual([
      { type: 'tool_calls', toolCalls: [{ index: 2, arguments: '{"q":1}' }] },
    ]);
  });
});

describe('stream activity: web search start signal', () => {
  it('Anthropic server_tool_use(web_search) -> activity, in the proxy parser and the direct strategy', () => {
    const proxy = createProxyChunkParser('anthropic');
    expect(toArr(proxy('content_block_start', ANTHROPIC_SEARCH_START))).toEqual([ACTIVITY]);

    const direct = anthropicMessagesStrategy.parseStreamChunk(
      'content_block_start',
      ANTHROPIC_SEARCH_START,
      createStreamContext('anthropic'),
      null,
    );
    expect(toArr(direct)).toEqual([ACTIVITY]);
  });

  it('OpenAI Responses web_search_call added -> activity, in the proxy parser and the direct strategy', () => {
    const proxy = createProxyChunkParser('openAI');
    expect(activities(toArr(proxy('response.output_item.added', RESPONSES_SEARCH_START)))).toEqual([ACTIVITY]);

    const direct = openAIResponsesStrategy.parseStreamChunk(
      'response.output_item.added',
      RESPONSES_SEARCH_START,
      createStreamContext('openAI'),
      null,
    );
    expect(activities(toArr(direct))).toEqual([ACTIVITY]);
  });

  it('Moonshot built-in $web_search tool call -> activity', () => {
    const proxy = createProxyChunkParser('moonshot');
    const chunk = JSON.stringify({
      choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'builtin_function', function: { name: '$web_search', arguments: '' } }] } }],
    });
    expect(activities(toArr(proxy(null, chunk)))).toEqual([ACTIVITY]);
  });

  it('never reports an ordinary tool, an unknown server tool or the search-finished frame as a search', () => {
    const anthropic = createProxyChunkParser('anthropic');
    const clientTool = JSON.stringify({
      type: 'content_block_start',
      index: 1,
      content_block: { type: 'tool_use', id: 'toolu_1', name: 'web_search', input: {} },
    });
    const otherServerTool = JSON.stringify({
      type: 'content_block_start',
      index: 1,
      content_block: { type: 'server_tool_use', id: 'srvtoolu_2', name: 'code_execution', input: {} },
    });
    expect(activities(toArr(anthropic('content_block_start', clientTool)))).toEqual([]);
    expect(activities(toArr(anthropic('content_block_start', otherServerTool)))).toEqual([]);

    const responses = createProxyChunkParser('openAI');
    const functionCall = JSON.stringify({
      type: 'response.output_item.added',
      item: { id: 'fc_1', type: 'function_call', call_id: 'call_1', name: 'web_search', arguments: '' },
      output_index: 0,
    });
    const searchDone = RESPONSES_SEARCH_START.replace('response.output_item.added', 'response.output_item.done');
    expect(activities(toArr(responses('response.output_item.added', functionCall)))).toEqual([]);
    expect(activities(toArr(responses('response.output_item.done', searchDone)))).toEqual([]);

    const chat = createProxyChunkParser('openAI');
    const namedLikeSearch = JSON.stringify({
      choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'web_search', arguments: '{}' } }] } }],
    });
    expect(activities(toArr(chat(null, namedLikeSearch)))).toEqual([]);
  });
});
