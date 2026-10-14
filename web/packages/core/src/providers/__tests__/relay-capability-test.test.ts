import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  RELAY_CAPABILITY_TEST_DEADLINE_MS,
  classifyRelayCapabilityTestOutcome,
  classifyRelayCapabilityTestResponse,
  relayCapabilityTestFunctionTool,
  relayCapabilityTestMessages,
  RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS,
  type RelayCapabilityTestShortTransport,
} from '../relay-capability-test';
import {
  buildRelayAnthropicMessagesBody,
  buildRelayChatCompletionsBody,
  buildRelayGeminiGenerateContentBody,
  buildRelayResponsesBody,
  type RelayMessages,
} from '../relay-orchestrator';
import type { StreamOptions } from '../types';

/* Fixture (source of truth): shared test-fixtures/relay/capability-test.v1.json */

interface ClassifyCase {
  caseId: string;
  status: number;
  contentType: string;
  body: string;
  expect: 'accepted' | 'rejected' | 'undetermined';
  reason: string;
}
type RequestKind = 'text' | 'image' | 'tool';
interface RequestShape {
  path: string;
  bodySubset: Record<string, unknown>;
  bodySubsetByKind: Partial<Record<RequestKind, Record<string, unknown>>>;
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'capability-test.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as {
      builtins: { maxOutputTokens: number; imagePNGBase64: string; tool: { name: string } };
      deadline: { perItemSeconds: number };
      requestShapes: Record<RelayCapabilityTestShortTransport, RequestShape>;
      mustContain: Record<RequestKind, string[]>;
      mustNotContain: Record<RequestKind, string[]>;
      classifyCases: ClassifyCase[];
    };
    dir = path.dirname(dir);
  }
  throw new Error('capability-test.v1.json not found');
})();

describe('capability test response verdicts (including SSE rules and reasons)', () => {
  it.each(fixture.classifyCases.map((item) => [item.caseId, item] as const))('%s', (_caseId, item) => {
    const input = { status: item.status, contentType: item.contentType, body: item.body };
    expect(classifyRelayCapabilityTestOutcome(input)).toEqual({ verdict: item.expect, reason: item.reason });
    // The chat rejection loop and native-file fallback still honor only the verdict.
    expect(classifyRelayCapabilityTestResponse(input)).toBe(item.expect);
  });
});

describe('per-item total time limit production value', () => {
  it('production constant = fixture deadline.perItemSeconds', () => {
    expect(RELAY_CAPABILITY_TEST_DEADLINE_MS).toBe(fixture.deadline.perItemSeconds * 1000);
    expect(RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS).toBe(fixture.builtins.maxOutputTokens);
  });
});

/* ── New constructor parameters: the output cap goes through the constructor's own channel, and the function tools contain only this one ── */

function isSubset(expected: unknown, actual: unknown): boolean {
  if (Array.isArray(expected)) {
    return Array.isArray(actual) && actual.length === expected.length
      && expected.every((item, index) => isSubset(item, actual[index]));
  }
  if (expected && typeof expected === 'object') {
    if (!actual || typeof actual !== 'object' || Array.isArray(actual)) return false;
    return Object.entries(expected).every(([key, value]) =>
      key in (actual as Record<string, unknown>) && isSubset(value, (actual as Record<string, unknown>)[key]));
  }
  return expected === actual;
}

function withModel<T>(value: T, modelID: string): T {
  return JSON.parse(JSON.stringify(value).split('{{model}}').join(modelID)) as T;
}

function buildBody(short: RelayCapabilityTestShortTransport, modelID: string, messages: RelayMessages, options: StreamOptions): Record<string, unknown> {
  switch (short) {
    case 'chat': return buildRelayChatCompletionsBody(modelID, messages, options).body;
    case 'responses': return buildRelayResponsesBody(modelID, messages, options, null).body;
    case 'messages': return buildRelayAnthropicMessagesBody(modelID, messages, options);
    case 'gemini': return buildRelayGeminiGenerateContentBody(messages, options);
  }
}

const SHORTS: RelayCapabilityTestShortTransport[] = ['chat', 'responses', 'messages', 'gemini'];

describe('capability test request body = chat constructor + output cap + function tool', () => {
  for (const short of SHORTS) {
    for (const kind of ['text', 'image', 'tool'] as const) {
      it(`${short}.${kind} satisfies requestShapes / mustContain / mustNotContain`, () => {
        const modelID = 'model-x';
        const shape = withModel(fixture.requestShapes[short], modelID);
        const body = buildBody(short, modelID, relayCapabilityTestMessages(kind), {
          relayStream: true,
          relayMaxOutputTokens: RELAY_CAPABILITY_TEST_MAX_OUTPUT_TOKENS,
          // The tool item still carries the web intent chat would carry: when a function tool is passed, built-in tools are never merged in.
          supportsWebSearch: true,
          ...(kind === 'tool' ? { relayFunctionTool: relayCapabilityTestFunctionTool() } : {}),
        });
        expect(isSubset(shape.bodySubset, body)).toBe(true);
        const byKind = shape.bodySubsetByKind[kind];
        if (byKind) expect(isSubset(byKind, body)).toBe(true);
        const raw = JSON.stringify(body);
        const expand = (value: string) => value.split('{{png}}').join(fixture.builtins.imagePNGBase64);
        for (const value of fixture.mustContain[kind].map(expand)) {
          expect(raw.includes(value) || raw.includes(value.split('/').join('\\/'))).toBe(true);
        }
        for (const value of fixture.mustNotContain[kind].map(expand)) {
          expect(raw.includes(value)).toBe(false);
        }
      });
    }
  }
});

describe('without the new parameters the four chat constructors produce byte-identical output to before', () => {
  const messages: RelayMessages = [
    { role: 'system', content: 'S' },
    { role: 'user', content: [
      { type: 'text', text: 'look' },
      { type: 'image_url', image_url: { url: 'data:image/png;base64,QUJD' } },
    ] },
  ];
  const options: StreamOptions = { relayStream: true, supportsWebSearch: true };

  it('RD4-PATH-03 chat', () => {
    expect(JSON.stringify(buildRelayChatCompletionsBody('m', messages, options).body)).toBe(JSON.stringify({
      model: 'm',
      stream: true,
      messages: [
        { role: 'system', content: 'S' },
        { role: 'user', content: [
          { type: 'text', text: 'look' },
          { type: 'image_url', image_url: { url: 'data:image/png;base64,QUJD' } },
        ] },
      ],
      stream_options: { include_usage: true },
    }));
  });

  it('RD4-PATH-03 responses', () => {
    expect(JSON.stringify(buildRelayResponsesBody('m', messages, options, null).body)).toBe(JSON.stringify({
      model: 'm',
      input: [
        { role: 'system', content: [{ type: 'input_text', text: 'S' }] },
        { role: 'user', content: [
          { type: 'input_text', text: 'look' },
          { type: 'input_image', image_url: 'data:image/png;base64,QUJD' },
        ] },
      ],
      stream: true,
      // Web tools are no longer added automatically by supportsWebSearch (relay web search comes only from connection-level snippets).
      tools: [{ type: 'image_generation' }],
      reasoning: { summary: 'auto' },
    }));
  });

  it('RD4-PATH-03 messages', () => {
    expect(JSON.stringify(buildRelayAnthropicMessagesBody('m', messages, options))).toBe(JSON.stringify({
      model: 'm',
      max_tokens: 8192,
      stream: true,
      messages: [
        { role: 'user', content: [
          { type: 'text', text: 'look' },
          { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'QUJD' } },
        ] },
      ],
      system: 'S',
    }));
  });

  it('RD4-PATH-03 gemini', () => {
    expect(JSON.stringify(buildRelayGeminiGenerateContentBody(messages, options))).toBe(JSON.stringify({
      contents: [
        { role: 'user', parts: [{ text: 'look' }, { inlineData: { mimeType: 'image/png', data: 'QUJD' } }] },
      ],
      systemInstruction: { parts: [{ text: 'S' }] },
      // googleSearch is no longer added automatically by supportsWebSearch.
    }));
  });
});
