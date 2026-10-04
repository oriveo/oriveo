/**
 * The shared SSE framing fixture (`shared/test-fixtures/provider-stream/sse-framing.v1.json`) run
 * against the MCP parser. The fixture is read only, and every assertion is made on what the
 * production `McpSseParser` handed out.
 *
 * The MCP parser emits JSON messages only and keeps no event / id / retry, and when the first data
 * line of an event parses on its own it is emitted before the blank line arrives. The framing group
 * therefore swaps payload parsing for the identity function: a single-line event yields its data, a
 * multi-line event yields its first line and then, at the blank line, the joined whole. The second
 * group runs the full production path with the default JSON parsing.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { McpSseParser } from './mcp-sse';
import type { JsonValue } from './mcp-types';

interface FixtureChunking {
  name: string;
  offsets?: number[];
  every?: number;
}

interface FixtureCase {
  id: string;
  bytes_base64: string;
  chunkings: FixtureChunking[];
  expect: { frames: Array<{ data: string }> };
}

const fixture = JSON.parse(
  readFileSync(
    resolve(process.cwd(), '../../../shared/test-fixtures/provider-stream/sse-framing.v1.json'),
    'utf8',
  ),
) as { schema: string; cases: FixtureCase[] };

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

/** The way `mcp-client.ts` reads an SSE response body: streaming TextDecoder, then push, then finish. */
function run(parser: McpSseParser, chunks: Uint8Array[]): JsonValue[] {
  const decoder = new TextDecoder();
  const out: JsonValue[] = [];
  for (const chunk of chunks) out.push(...parser.push(decoder.decode(chunk, { stream: true })));
  out.push(...parser.push(decoder.decode()), ...parser.finish());
  return out;
}

function parses(text: string): boolean {
  try {
    JSON.parse(text);
    return true;
  } catch {
    return false;
  }
}

it('reads the fixture version this test knows, with all 22 cases', () => {
  expect(fixture.schema).toBe('oriveo.fixture.sse-framing/v1');
  expect(fixture.cases).toHaveLength(22);
});

describe('sse-framing: McpSseParser line splitting and field parsing (payload returned as is)', () => {
  for (const testCase of fixture.cases) {
    for (const chunking of testCase.chunkings) {
      it(`${testCase.id} · ${chunking.name}`, () => {
        const actual = run(
          new McpSseParser((text) => text),
          cut(Buffer.from(testCase.bytes_base64, 'base64'), chunking),
        );
        const expected = testCase.expect.frames.flatMap(({ data }) =>
          data.includes('\n') ? [data.slice(0, data.indexOf('\n')), data] : [data],
        );
        expect(actual).toEqual(expected);
      });
    }
  }
});

describe('sse-framing: McpSseParser with the default JSON parsing (full production path)', () => {
  for (const testCase of fixture.cases) {
    for (const chunking of testCase.chunkings) {
      it(`${testCase.id} · ${chunking.name}`, () => {
        const actual = run(new McpSseParser(), cut(Buffer.from(testCase.bytes_base64, 'base64'), chunking));
        const expected = testCase.expect.frames
          .filter(({ data }) => data.length > 0 && parses(data))
          .map(({ data }) => JSON.parse(data) as JsonValue);
        expect(actual).toEqual(expected);
      });
    }
  }
});
