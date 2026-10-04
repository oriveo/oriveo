/**
 * Characterization test over recorded provider traffic.
 *
 * `shared/test-fixtures/provider-toolcall/recorded/*.sse` holds raw SSE bytes captured from real
 * providers (only the response headers were dropped); the `*.sse` files one level up are
 * hand-written samples of each protocol. They are fed through the production path
 * `createSSEStream`, and two things are pinned in `sse-real-corpus.pinned.json` as a count and a
 * SHA-256: the (event, data) sequence the parser hands to parseChunk, the StreamEvent sequence the
 * production proxy chunk parser builds from it, and the text those events add up to.
 *
 * The pins guard the output for real traffic: a change to how the parser frames a stream must leave
 * this group green. When the output is meant to change, and each difference has been judged a fix
 * and not a regression, rewrite the pins with `ORIVEO_SSE_CORPUS_PIN_WRITE=1`.
 */
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { ProviderKind } from '@oriveo/shared/pure-types';
import { describe, expect, it } from 'vitest';
import type { TransportResponse } from '../../ports';
import { createProxyChunkParser } from '../proxy-chunk-parser';
import { createSSEStream } from '../sse-parser';
import type { StreamEvent } from '../types';

interface Pin {
  entries: number;
  entriesSha256: string;
  streamEvents: number;
  streamEventsSha256: string;
  textSha256: string;
}

const corpusDirectory = resolve(process.cwd(), '../../../shared/test-fixtures/provider-toolcall');
const pinPath = resolve(process.cwd(), 'src/providers/__tests__/sse-real-corpus.pinned.json');
const writePins = process.env.ORIVEO_SSE_CORPUS_PIN_WRITE === '1';

/** Corpus file and the ProviderKind the production proxy chunk parser is built for. */
const corpus: Array<{ file: string; provider: ProviderKind }> = [
  { file: 'recorded/groq.leg1.sse', provider: 'groq' },
  { file: 'recorded/together.leg1.sse', provider: 'togetherAI' },
  { file: 'recorded/fireworks.leg1.sse', provider: 'fireworksAI' },
  { file: 'recorded/qwen.leg1.sse', provider: 'qwen' },
  { file: 'recorded/zhipu.leg1.sse', provider: 'zhipu' },
  { file: 'recorded/siliconflow.leg1.sse', provider: 'siliconFlow' },
  { file: 'recorded/deepseek.leg1.sse', provider: 'deepseek' },
  { file: 'recorded/moonshot.leg1.sse', provider: 'moonshot' },
  { file: 'recorded/moonshot_web_search.leg1.sse', provider: 'moonshot' },
  { file: 'recorded/anthropic.leg1.sse', provider: 'anthropic' },
  { file: 'recorded/gemini.leg1.sse', provider: 'gemini' },
  { file: 'recorded/grok.leg1.sse', provider: 'grok' },
  { file: 'recorded/openai.leg1.sse', provider: 'openAI' },
  { file: 'openai_chat.tool_calls.sse', provider: 'openAI' },
  { file: 'openai_responses.function_call.sse', provider: 'openAI' },
  { file: 'anthropic.tool_use.sse', provider: 'anthropic' },
  { file: 'gemini.functionCall.sse', provider: 'gemini' },
  { file: 'grok_proxy.text_json_fence.sse', provider: 'grok' },
  { file: 'grok_proxy.text_tool_call_tag.sse', provider: 'grok' },
  { file: 'grok_proxy.text_html_fence.sse', provider: 'grok' },
  { file: 'grok_proxy.responses.web_search.sse', provider: 'grok' },
];

/** Chunkings: whole, every 13 bytes (bound to cut inside multi-byte characters and line ends), and every byte (small files only). */
const chunkSizes = [0, 13, 1];
const EVERY_BYTE_LIMIT = 30_000;

function cut(bytes: Uint8Array, size: number): Uint8Array[] {
  if (size === 0) return [bytes];
  const chunks: Uint8Array[] = [];
  for (let start = 0; start < bytes.length; start += size) chunks.push(bytes.slice(start, start + size));
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

function sha256(value: unknown): string {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

async function observe(bytes: Uint8Array, size: number, provider: ProviderKind): Promise<Pin> {
  const entries: Array<[string | null, string]> = [];
  await collect(
    createSSEStream(responseOf(cut(bytes, size)), (event, data) => {
      entries.push([event, data]);
      return null;
    }),
  );
  const streamEvents = await collect(
    createSSEStream(responseOf(cut(bytes, size)), createProxyChunkParser(provider)),
  );
  return {
    entries: entries.length,
    entriesSha256: sha256(entries),
    streamEvents: streamEvents.length,
    streamEventsSha256: sha256(streamEvents),
    textSha256: sha256(streamEvents.map((event) => (event.type === 'delta' ? event.content : '')).join('')),
  };
}

const pins: Record<string, Pin> = writePins ? {} : JSON.parse(readFileSync(pinPath, 'utf8'));

describe('recorded provider SSE traffic: pinned createSSEStream output', () => {
  it('has a pin for every corpus file', () => {
    if (writePins) return;
    expect(Object.keys(pins).sort()).toEqual(corpus.map((entry) => entry.file).sort());
  });

  for (const { file, provider } of corpus) {
    const bytes = new Uint8Array(readFileSync(resolve(corpusDirectory, file)));
    for (const size of chunkSizes) {
      if (size === 1 && bytes.length > EVERY_BYTE_LIMIT) continue;
      it(`${file} · ${size === 0 ? 'whole' : `every-${size}-bytes`}`, async () => {
        const actual = await observe(bytes, size, provider);
        if (writePins) {
          // Pins are written from the whole-chunk run only; the other chunkings assert against the same pins in read mode, which also shows the output does not depend on the cut.
          if (size === 0) pins[file] = actual;
          return;
        }
        expect(actual).toEqual(pins[file]);
      });
    }
  }

  it.runIf(writePins)('writes the pin file', () => {
    writeFileSync(pinPath, `${JSON.stringify(pins, null, 2)}\n`);
  });
});
