/**
 * Extended thinking output path of relay Anthropic Messages.
 *
 * The request already enables thinking per the reasoning tier; the thinking_delta / non-streaming thinking blocks sent by upstream
 * must produce reasoning just like the official parser (proxy-chunk-parser / anthropic-messages strategy),
 * otherwise relay users cannot see the thinking process.
 */
import { describe, expect, it } from 'vitest';
import { sendRelayStream, type RelayOrchestratorDeps } from '../relay-orchestrator';
import type { StreamEvent, StreamOptions } from '../types';
import type { UpstreamTransport } from '../../ports';

const SSE_WITH_THINKING = [
  'event: message_start',
  'data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}',
  '',
  'event: content_block_start',
  'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think"}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}',
  '',
  'event: content_block_start',
  'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}',
  '',
  'event: content_block_delta',
  'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Answer"}}',
  '',
  'event: message_delta',
  'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}',
  '',
  'event: message_stop',
  'data: {"type":"message_stop"}',
  '',
  '',
].join('\n');

const JSON_WITH_THINKING = JSON.stringify({
  type: 'message',
  content: [
    { type: 'thinking', thinking: 'Plan first', signature: 'sig-xyz' },
    { type: 'redacted_thinking', data: 'opaque' },
    { type: 'thinking', thinking: 'Then check', signature: 'sig-2' },
    { type: 'text', text: 'Done' },
  ],
  usage: { input_tokens: 3, output_tokens: 4 },
});

function upstream(body: string, contentType: string): UpstreamTransport {
  return {
    fetch: async () => new Response(body, { status: 200, headers: { 'Content-Type': contentType } }),
  };
}

function relayDeps(transport: UpstreamTransport): RelayOrchestratorDeps {
  return {
    transport,
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
}

async function drain(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    events.push(value);
  }
  return events;
}

async function run(options: StreamOptions, transport: UpstreamTransport): Promise<StreamEvent[]> {
  const handle = sendRelayStream(
    'sk-test',
    'claude-sonnet-4-5',
    [{ role: 'user', content: 'hello' }],
    'https://relay.example/v1',
    options,
    relayDeps(transport),
  );
  return drain(handle.stream);
}

const BASE: StreamOptions = {
  relayTransport: 'anthropic_messages',
  relayAuthMode: 'bearer',
  reasoning: 'deep',
};

describe('relay Anthropic thinking -> reasoning', () => {
  it('SSE replay: thinking_delta outputs reasoning, text_delta still outputs delta', async () => {
    const events = await run({ ...BASE, relayStream: true }, upstream(SSE_WITH_THINKING, 'text/event-stream'));
    const reasoning = events.filter((e) => e.type === 'reasoning');
    expect(reasoning).toEqual([{ type: 'reasoning', content: 'Let me think' }]);
    const deltas = events.filter((e) => e.type === 'delta');
    expect(deltas).toEqual([{ type: 'delta', content: 'Answer' }]);
    // signature_delta behaves like the official streaming parser: not a UI event, and does not pollute the text.
    expect(JSON.stringify(events)).not.toContain('sig-abc');
  });

  it('non-streaming: each thinking block outputs its own reasoning event, redacted_thinking stays out of the text', async () => {
    const events = await run({ ...BASE, relayStream: false }, upstream(JSON_WITH_THINKING, 'application/json'));
    expect(events.filter((e) => e.type === 'reasoning')).toEqual([
      { type: 'reasoning', content: 'Plan first' },
      { type: 'reasoning', content: 'Then check' },
    ]);
    expect(events.filter((e) => e.type === 'delta')).toEqual([{ type: 'delta', content: 'Done' }]);
  });
});
