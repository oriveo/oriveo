/**
 * The shared SSE framing fixture (`shared/test-fixtures/provider-stream/sse-framing.v1.json`) run
 * against the web chat parser. The fixture is read only: the raw bytes of every case are fed through
 * the production path under each chunking the fixture lists, and every assertion is made on what
 * the production parser handed out.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { TransportResponse } from '../../ports';
import { createProxyChunkParser } from '../proxy-chunk-parser';
import { createSSEStream, parseSSELines, SSEFrameDecoder, type SSEFrame } from '../sse-parser';
import type { StreamEvent } from '../types';

interface FixtureFrame {
  event: string | null;
  data: string;
  id: string | null;
  retry: number | null;
}

interface FixtureChunking {
  name: string;
  offsets?: number[];
  every?: number;
}

interface FixtureCase {
  id: string;
  rule: string;
  title: string;
  bytes_base64: string;
  chunkings: FixtureChunking[];
  expect: { frames: FixtureFrame[]; comments: number };
  openai_chat?: { text: string; finish_reason: string | null; done: boolean };
}

const fixture = JSON.parse(
  readFileSync(
    resolve(process.cwd(), '../../../shared/test-fixtures/provider-stream/sse-framing.v1.json'),
    'utf8',
  ),
) as { schema: string; cases: FixtureCase[] };

const DONE = '[DONE]';

function cut(bytes: Uint8Array, chunking: FixtureChunking): Uint8Array[] {
  const offsets = chunking.every
    ? Array.from({ length: Math.max(0, Math.ceil(bytes.length / chunking.every) - 1) }, (_, i) => (i + 1) * chunking.every!)
    : chunking.offsets ?? [];
  const chunks: Uint8Array[] = [];
  let start = 0;
  for (const offset of offsets) {
    chunks.push(bytes.slice(start, offset));
    start = offset;
  }
  chunks.push(bytes.slice(start));
  return chunks;
}

function responseOf(chunks: Uint8Array[]): TransportResponse {
  let index = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(ctrl) {
      if (index < chunks.length) ctrl.enqueue(chunks[index++]!);
      else ctrl.close();
    },
  });
  return { ok: true, status: 200, body, text: async () => '', headers: new Headers(), url: '' } as unknown as TransportResponse;
}

async function collect(stream: ReadableStream<StreamEvent>): Promise<StreamEvent[]> {
  const events: StreamEvent[] = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) return events;
    events.push(value);
  }
}

/** The frames before the end sentinel: `createSSEStream` closes at the sentinel, which shows up as the done event. */
function beforeSentinel(frames: FixtureFrame[]): Array<{ event: string | null; data: string }> {
  const end = frames.findIndex((frame) => frame.data === DONE);
  return (end < 0 ? frames : frames.slice(0, end)).map(({ event, data }) => ({ event, data }));
}

it('reads the fixture version this test knows, with all 22 cases', () => {
  expect(fixture.schema).toBe('oriveo.fixture.sse-framing/v1');
  expect(fixture.cases).toHaveLength(22);
});

describe('sse-framing: SSEFrameDecoder frame by frame (event / data / id / retry / comment count)', () => {
  for (const testCase of fixture.cases) {
    for (const chunking of testCase.chunkings) {
      it(`${testCase.id} · ${chunking.name}`, () => {
        const decoder = new SSEFrameDecoder();
        const frames: SSEFrame[] = [];
        for (const chunk of cut(Buffer.from(testCase.bytes_base64, 'base64'), chunking)) {
          frames.push(...decoder.push(chunk));
        }
        frames.push(...decoder.finish());
        expect(frames.map(({ event, data, id, retry }) => ({ event, data, id, retry }))).toEqual(testCase.expect.frames);
        expect(decoder.comments).toBe(testCase.expect.comments);
      });
    }
  }
});

describe('sse-framing: the event name and data createSSEStream hands to parseChunk', () => {
  for (const testCase of fixture.cases) {
    for (const chunking of testCase.chunkings) {
      it(`${testCase.id} · ${chunking.name}`, async () => {
        const seen: Array<{ event: string | null; data: string }> = [];
        const events = await collect(
          createSSEStream(
            responseOf(cut(Buffer.from(testCase.bytes_base64, 'base64'), chunking)),
            (event, data) => {
              seen.push({ event, data });
              return null;
            },
          ),
        );
        expect(seen).toEqual(beforeSentinel(testCase.expect.frames));
        expect(events).toEqual([{ type: 'done' }]);
      });
    }
  }
});

describe('sse-framing: parseSSELines on the whole text', () => {
  for (const testCase of fixture.cases) {
    it(testCase.id, () => {
      const text = new TextDecoder().decode(Buffer.from(testCase.bytes_base64, 'base64'));
      expect(parseSSELines(text)).toEqual(testCase.expect.frames.map(({ event, data }) => ({ event, data })));
    });
  }
});

describe('sse-framing: openai_chat assembly (production proxy chunk parser)', () => {
  for (const testCase of fixture.cases.filter((c) => c.openai_chat)) {
    for (const chunking of testCase.chunkings) {
      it(`${testCase.id} · ${chunking.name}`, async () => {
        const events = await collect(
          createSSEStream(
            responseOf(cut(Buffer.from(testCase.bytes_base64, 'base64'), chunking)),
            createProxyChunkParser('openAI'),
          ),
        );
        const text = events.map((event) => (event.type === 'delta' ? event.content : '')).join('');
        expect(text).toBe(testCase.openai_chat!.text);
        expect(events.filter((event) => event.type === 'error')).toEqual([]);
        expect(events.at(-1)).toEqual({ type: 'done' });
      });
    }
  }
});

describe('beyond the fixture: upstreams that do not follow the specification', () => {
  it('delivers line by line when JSON messages are separated by a single line break and no blank line, keeping the text', async () => {
    const body = [
      'data: {"choices":[{"index":0,"delta":{"content":"A"}}]}',
      'data: {"choices":[{"index":0,"delta":{"content":"B"}}]}',
      'data: [DONE]',
      'data: {"choices":[{"index":0,"delta":{"content":"after the sentinel"}}]}',
      '',
    ].join('\n');
    const events = await collect(
      createSSEStream(responseOf([new TextEncoder().encode(body)]), createProxyChunkParser('openAI')),
    );
    expect(events.map((event) => (event.type === 'delta' ? event.content : '')).join('')).toBe('AB');
    expect(events.at(-1)).toEqual({ type: 'done' });
  });

  it('delivers each data line with its own event name when event / data pairs come without a blank line between events', async () => {
    const body = [
      'event: content_block_delta',
      'data: {"i":1}',
      'event: content_block_delta',
      'data: {"i":2}',
      'event: message_stop',
      'data: {"i":3}',
      '',
    ].join('\n');
    const seen: Array<[string | null, string]> = [];
    await collect(
      createSSEStream(responseOf([new TextEncoder().encode(body)]), (event, data) => {
        seen.push([event, data]);
        JSON.parse(data);
        return null;
      }),
    );
    // The first entry is the whole joined per the specification, which parseChunk rejects with a SyntaxError; the line-by-line fallback follows.
    expect(seen.slice(1)).toEqual([
      ['content_block_delta', '{"i":1}'],
      ['content_block_delta', '{"i":2}'],
      ['message_stop', '{"i":3}'],
    ]);
  });
});
