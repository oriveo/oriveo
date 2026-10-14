/**
 * Gemini Interactions request body golden + streaming replay (same-named cases on all three clients).
 *
 * Fixtures are read-only: shared/test-fixtures/provider-toolcall/gemini_interactions.request-golden.v1.json,
 * recorded/gemini_interactions.expected.json and recorded/gemini_interactions_*.sse (including recorded_samples real samples).
 * The request side goes entirely through the production builder (pre_activation files are first turned into xml-v1 text by the production attachment injector),
 * the stream side through the production response adapter + production proxy chunk parser. It lives in apps/app because the attachment injector is here.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { attachmentTransportProfile } from '@oriveo/core/providers/attachment-transport';
import { buildGeminiInteractionsRequest } from '@oriveo/core/providers/request-builders/gemini-interactions';
import type { EndpointRouteRecipe, RuntimeRecipe } from '@oriveo/core/providers/request-builders/capability-execution';
import type { ProxyMessage } from '@oriveo/core/providers/request-builders/runtime';
import type { RequestParams } from '@oriveo/core/providers/request-builders/types';
import { adaptGeminiInteractionsResponse } from '@oriveo/core/providers/response-adapters/gemini-interactions';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { parseSSELines } from '@oriveo/core/providers/sse-parser';
import type { ContentPart, StreamEvent } from '@oriveo/core/providers/types';
import { AttachmentInjector } from '../../attachments/attachment-injector';
import { DEFAULT_LIMITS } from '../../attachments/file-text-extractor';

const repoRoot = resolve(process.cwd(), '../../..');
const fixtureDir = resolve(repoRoot, 'shared/test-fixtures/provider-toolcall');
const golden = JSON.parse(readFileSync(resolve(fixtureDir, 'gemini_interactions.request-golden.v1.json'), 'utf8')) as Golden;
const replay = JSON.parse(readFileSync(resolve(fixtureDir, 'recorded/gemini_interactions.expected.json'), 'utf8')) as Replay;
const registry = JSON.parse(readFileSync(
  resolve(repoRoot, 'shared/capabilityrecipe/capability_runtime.v1.json'),
  'utf8',
)) as { recipes: Record<string, RuntimeRecipe> };
const webRecipe = registry.recipes['gemini.interactions.web.v1']!;
const route = webRecipe.route as EndpointRouteRecipe;

interface GoldenPart { type: 'text' | 'image' | 'document'; text?: string; mime_type?: string; data?: string; name?: string; extracted_text?: string }
interface GoldenCase {
  id: string;
  input: {
    model: string; system: string; web: boolean; reasoning_recipe: boolean;
    reasoning: 'off' | 'low' | 'balanced' | 'deep' | 'max' | null;
    attachment_profile: 'pre_activation' | 'activated';
    messages: Array<{ role: 'user' | 'assistant'; parts: GoldenPart[] }>;
  };
  expected_body?: Record<string, unknown>;
  assertions?: {
    input_step_types?: string[]; content_types_only?: string[]; user_text_contains?: string[];
    absent_keys_anywhere?: string[]; absent_substrings?: string[]; absent_pointers?: string[]; store?: boolean;
  };
}
interface Golden { reasoning_recipe: RuntimeRecipe; image_placeholder: string; cases: GoldenCase[] }
interface ReplayExpected {
  text: string; thinking: string;
  citations: Array<{ url: string; title?: string; start_index?: number; end_index?: number }>;
  search_evidence: Array<{ is_error: boolean }>;
  error: { code: string; message: string | null; phase: 'before_content' | 'after_content' } | null;
  terminal: 'completed' | 'incomplete' | 'error' | 'interrupted';
  usage: { input_total: number; output_total: number; reasoning: number } | null;
}
interface Replay {
  fixtures: Array<{ file: string; expected: ReplayExpected }>;
  recorded_samples: Array<{ file: string; kind: string; expected?: ReplayExpected }>;
}

function toProxyMessages(input: GoldenCase['input']): ProxyMessage[] {
  const wrapper = attachmentTransportProfile('gemini_interactions').wrapper;
  const messages: ProxyMessage[] = input.system ? [{ role: 'system', content: input.system }] : [];
  for (const message of input.messages) {
    if (message.role === 'assistant') {
      messages.push({ role: 'assistant', content: message.parts.map((part) => part.text ?? '').join('') });
      continue;
    }
    let text = message.parts.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('\n');
    const media: ContentPart[] = [];
    for (const part of message.parts) {
      if (part.type === 'image') {
        media.push({ type: 'image_url', image_url: { url: `data:${part.mime_type};base64,${part.data}` } });
      } else if (part.type === 'document' && input.attachment_profile === 'pre_activation') {
        // Production pre_activation: before the builder, the attachment injector turns files into text per the line wrapper.
        const extracted = part.extracted_text ?? '';
        text = AttachmentInjector.injectAll(text, [{
          fileName: part.name ?? 'document',
          mimeType: part.mime_type ?? 'application/octet-stream',
          sizeBytes: Math.ceil(((part.data ?? '').length * 3) / 4),
          extracted: { content: extracted, totalLines: extracted.split('\n').length, truncated: false, sizeBytes: extracted.length },
        }], DEFAULT_LIMITS, wrapper).text;
      } else if (part.type === 'document') {
        media.push({ type: 'file', file: { filename: part.name ?? 'document.pdf', file_data: `data:${part.mime_type};base64,${part.data}` } });
      }
    }
    messages.push({ role: 'user', content: [{ type: 'text', text }, ...media] });
  }
  return messages;
}

function buildCase(item: GoldenCase) {
  const params: RequestParams = {
    providerKind: 'gemini', apiKey: 'key', modelID: item.input.model, messages: toProxyMessages(item.input),
  };
  return buildGeminiInteractionsRequest(params, route, {
    ...(item.input.web ? { webRecipe } : {}),
    ...(item.input.reasoning_recipe ? { reasoningRecipe: golden.reasoning_recipe } : {}),
    reasoningIntent: item.input.reasoning,
    attachmentProfile: item.input.attachment_profile,
  });
}

function keysAnywhere(value: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(value)) value.forEach((item) => keysAnywhere(item, out));
  else if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) { out.add(key); keysAnywhere(child, out); }
  }
  return out;
}

function pointerExists(body: unknown, pointer: string): boolean {
  let cursor: unknown = body;
  for (const segment of pointer.slice(1).split('/')) {
    if (!cursor || typeof cursor !== 'object' || !Object.hasOwn(cursor, segment)) return false;
    cursor = (cursor as Record<string, unknown>)[segment];
  }
  return true;
}

describe('Gemini Interactions request golden — production builder', () => {
  for (const item of golden.cases) {
    it(item.id, () => {
      const request = buildCase(item);
      const body = JSON.parse(JSON.stringify(request.body)) as Record<string, any>;
      expect(Object.hasOwn(body, 'previous_interaction_id')).toBe(false);
      expect(body.store).toBe(false);
      if (item.expected_body) expect(body).toEqual(item.expected_body);
      const assertions = item.assertions;
      if (!assertions) return;
      const steps = body.input as Array<{ type: string; content: Array<{ type: string; text?: string }> }>;
      if (assertions.input_step_types) expect(steps.map((step) => step.type)).toEqual(assertions.input_step_types);
      if (assertions.content_types_only) {
        const types = new Set(steps.flatMap((step) => step.content.map((part) => part.type)));
        expect([...types]).toEqual(assertions.content_types_only);
      }
      if (assertions.user_text_contains) {
        const userText = steps.filter((step) => step.type === 'user_input')
          .flatMap((step) => step.content.map((part) => part.text ?? '')).join('\n');
        for (const needle of assertions.user_text_contains) expect(userText).toContain(needle);
      }
      const keys = keysAnywhere(body);
      for (const key of assertions.absent_keys_anywhere ?? []) expect(keys.has(key), key).toBe(false);
      const serialized = JSON.stringify(body);
      for (const needle of assertions.absent_substrings ?? []) expect(serialized).not.toContain(needle);
      for (const pointer of assertions.absent_pointers ?? []) expect(pointerExists(body, pointer), pointer).toBe(false);
      if (assertions.store !== undefined) expect(body.store).toBe(assertions.store);
    });
  }

  it('GI_PATH_FROM_RECIPE', () => {
    const params: RequestParams = { providerKind: 'gemini', apiKey: 'key', modelID: 'gemini-3.1-flash-lite', messages: [{ role: 'user', content: 'Hello' }] };
    const beta = buildGeminiInteractionsRequest(params, { ...route, path: '/v1beta/interactions' });
    expect(beta.url.endsWith('/v1beta/interactions')).toBe(true);
    expect(beta.url).not.toContain('/v1beta/v1beta');
    // The production recipe uses /v1beta (real sample 2026-10-13: /v1 returns 400 for google_search / system_instruction); /v1 stays on the allowlist.
    expect(buildGeminiInteractionsRequest(params, route).url.endsWith('/v1beta/interactions')).toBe(true);
    expect(buildGeminiInteractionsRequest(params, { ...route, path: '/v1/interactions' }).url.endsWith('/v1/interactions')).toBe(true);
    expect(() => buildGeminiInteractionsRequest(params, { ...route, path: '/v1/models/x:generateContent' })).toThrow();
    expect(() => buildGeminiInteractionsRequest(params, { ...route, path: '/v2/interactions' })).toThrow();
  });
});

/** Terminal mechanism on this client: error = the error frame rewritten by the production adapter (the stream parser recognizes it as streamErrorFrame);
 * completed / incomplete = end with `[DONE]` (Web treats max_tokens truncation and normal completion with the same ending);
 * interrupted (cancelled / stream cut with no terminal state) is handled as error: the same error frame mechanism, with code
 * interaction_cancelled / interaction_stream_closed, and the body already received is kept. */
const INTERRUPTED_CODES: Record<string, string> = {
  'gemini_interactions_cancelled.sse': 'interaction_cancelled',
  'gemini_interactions_truncated.sse': 'interaction_stream_closed',
};

async function replayFixture(file: string) {
  const raw = readFileSync(resolve(fixtureDir, 'recorded', file), 'utf8');
  const adapted = await adaptGeminiInteractionsResponse(new Response(raw, { headers: { 'Content-Type': 'text/event-stream' } })).text();
  const parse = createProxyChunkParser('gemini');
  const events: StreamEvent[] = [];
  const frames: Array<Record<string, any>> = [];
  let sawDone = false;
  for (const entry of parseSSELines(adapted)) {
    if (entry.data === '[DONE]') { sawDone = true; continue; }
    frames.push(JSON.parse(entry.data));
    const parsed = parse(entry.event, entry.data);
    if (parsed != null) events.push(...(Array.isArray(parsed) ? parsed : [parsed]));
  }
  return { events, frames, sawDone };
}

// The fixture and real samples share the same comparison rules; returns the body for the caller to add assertions.
async function assertReplay(fixture: { file: string; expected: ReplayExpected }, options: { dedupeCitations?: boolean } = {}): Promise<string> {
  const { events, frames, sawDone } = await replayFixture(fixture.file);
  const expected = fixture.expected;
  const text = events.flatMap((event) => event.type === 'delta' ? [event.content] : []).join('');
  const thinking = events.flatMap((event) => event.type === 'reasoning' ? [event.content] : []).join('');
  expect(text).toBe(expected.text);
  expect(thinking).toBe(expected.thinking);

  // The Web citation model (Citation) has no index field, and per contract none is added, so only url / title are compared.
  const citations = events.filter((event) => event.type === 'citations').at(-1);
  // In real samples the same link can repeat in several spans, and the production adapter dedupes by url; compare after deduping expected (keeping the first).
  const expectedCitations = expected.citations.map(({ url, title }) => ({ url, title }))
    .filter((item, index, all) => !options.dedupeCitations || all.findIndex((other) => other.url === item.url) === index);
  expect(citations?.type === 'citations' ? citations.citations.map(({ url, title }) => ({ url, title })) : [])
    .toEqual(expectedCitations);

  const evidence = events.filter((event) => event.type === 'tool_result' && event.tool === 'google_search');
  expect(evidence).toHaveLength(expected.search_evidence.filter((item) => item.is_error !== true).length);

  expect(events.some((event) => event.type === 'continuation')).toBe(false);

  const errorFrames = frames.filter((frame) => frame.error && typeof frame.error === 'object');
  const errorEvents = events.filter((event) => event.type === 'error');
  if (expected.error) {
    expect(errorFrames).toHaveLength(1);
    expect(errorFrames[0]!.error.code).toBe(expected.error.code);
    if (expected.error.message) expect(errorFrames[0]!.error.message).toBe(expected.error.message);
    expect(errorEvents).toHaveLength(1);
    expect(errorEvents[0]).toMatchObject({ streamErrorFrame: true });
    // phase is decided by whether body / thinking already arrived before the error; the Web failure message keeps what was already received.
    expect(text.length + thinking.length > 0 ? 'after_content' : 'before_content').toBe(expected.error.phase);
    expect(sawDone).toBe(false);
  } else if (expected.terminal === 'interrupted') {
    expect(INTERRUPTED_CODES[fixture.file], fixture.file).toBeDefined();
    expect(errorFrames).toHaveLength(1);
    expect(errorFrames[0]!.error.code).toBe(INTERRUPTED_CODES[fixture.file]);
    expect(errorEvents).toHaveLength(1);
    expect(errorEvents[0]).toMatchObject({ streamErrorFrame: true });
    // Body already received -> message fails, keeps what was received, no resend.
    expect(text).toBe(expected.text);
    expect(sawDone).toBe(false);
  } else {
    expect(errorFrames).toHaveLength(0);
    expect(errorEvents).toHaveLength(0);
  }

  if (expected.terminal === 'completed' || expected.terminal === 'incomplete') expect(sawDone).toBe(true);

  const usage = events.filter((event) => event.type === 'usage').at(-1);
  if (expected.usage) {
    expect(usage?.type).toBe('usage');
    const breakdown = usage?.type === 'usage' ? usage.usage.breakdown : undefined;
    expect((breakdown?.promptTokens ?? 0) + (breakdown?.cachedInputTokens ?? 0)).toBe(expected.usage.input_total);
    // Thinking tokens are billed as output (same rule as generateContent): completion = output + thought.
    expect(breakdown?.completionTokens).toBe(expected.usage.output_total + expected.usage.reasoning);
    expect(breakdown?.reasoningTokens).toBe(expected.usage.reasoning);
  } else {
    expect(usage).toBeUndefined();
  }
  return text;
}

describe('Gemini Interactions SSE replay — production adapter + proxy parser', () => {
  for (const fixture of replay.fixtures) {
    it(fixture.file.replace(/\.sse$/, ''), async () => {
      await assertReplay(fixture);
    });
  }
});

// Real samples (recorded 2026-10-13) replay only c4_sample; measurement is an observation record and is not replayed.
describe('GI_LIVE_RECORDED_SAMPLES', () => {
  const samples = replay.recorded_samples.filter((sample) => sample.kind === 'c4_sample');

  it('GI_LIVE_RECORDED_SAMPLES count', () => {
    expect(samples).toHaveLength(5);
  });

  for (const sample of samples) {
    it(`GI_LIVE_RECORDED_SAMPLES ${sample.file.replace(/\.sse$/, '')}`, async () => {
      expect(sample.expected, sample.file).toBeDefined();
      const text = await assertReplay({ file: sample.file, expected: sample.expected! }, { dedupeCitations: true });
      expect(text.length).toBeGreaterThan(0);
    });
  }
});
