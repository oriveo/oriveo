import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { ProviderKind } from '@oriveo/shared/pure-types';
import { describe, expect, it } from 'vitest';
import {
  finalizeToolCalls,
  mergeToolCallDeltas,
  type ToolCallAccumulator,
} from '../tool-call-accumulator';
import { createProxyChunkParser } from '../proxy-chunk-parser';
import { parseSSELines } from '../sse-parser';
import type { StreamEvent } from '../types';

interface RecordedManifest {
  fixtures: Array<{
    file: string;
    provider: string;
    transport: string;
    expected: {
      text: string;
      tool_calls: Array<{ id: string | null; name: string; arguments: string }>;
    };
  }>;
}

interface ContractManifest {
  fixtures: Array<{
    file: string;
    transport: string;
    expected: {
      text: string;
      tool_calls: Array<{ id: string | null; name: string; arguments: string }>;
    };
  }>;
}

const fixtureDirectory = resolve(
  process.cwd(),
  '../../../shared/test-fixtures/provider-toolcall/recorded',
);
const manifest = JSON.parse(
  readFileSync(resolve(fixtureDirectory, 'expected.json'), 'utf8'),
) as RecordedManifest;
const contractDirectory = resolve(fixtureDirectory, '..');
const contractManifest = JSON.parse(
  readFileSync(resolve(contractDirectory, 'expected.json'), 'utf8'),
) as ContractManifest;

describe('recorded provider tool calls — Web production proxy parser', () => {
  for (const fixture of manifest.fixtures) {
    it(`${fixture.provider}: preserves the structured tool proposal`, () => {
      const parser = createProxyChunkParser(providerKind(fixture.provider));
      const accumulator: ToolCallAccumulator = new Map();
      let text = '';

      for (const entry of parseSSELines(
        readFileSync(resolve(fixtureDirectory, fixture.file), 'utf8'),
      )) {
        if (entry.data === '[DONE]') continue;
        const parsed = parser(entry.event, entry.data);
        const events: StreamEvent[] = parsed == null
          ? []
          : Array.isArray(parsed)
            ? parsed
            : [parsed];
        for (const event of events) {
          if (event.type === 'delta') text += event.content;
          if (event.type === 'tool_calls') mergeToolCallDeltas(accumulator, event.toolCalls);
        }
      }

      const actual = finalizeToolCalls(accumulator, `${fixture.provider}_tool_call`);
      expect(text).toBe(fixture.expected.text);
      expect(actual).toHaveLength(fixture.expected.tool_calls.length);
      fixture.expected.tool_calls.forEach((expected, index) => {
        expect(actual[index]?.name).toBe(expected.name);
        if (expected.id != null) expect(actual[index]?.id).toBe(expected.id);
        expect(JSON.parse(actual[index]?.arguments ?? '{}')).toEqual(JSON.parse(expected.arguments));
      });
    });
  }
});

describe('provider tool-call contract fixtures — structured fields only', () => {
  for (const fixture of contractManifest.fixtures) {
    it(`${fixture.file}: never promotes prose to a tool call`, () => {
      const provider = fixture.file.startsWith('grok_proxy') ? 'grok' : 'openAI';
      const parser = createProxyChunkParser(provider);
      const accumulator: ToolCallAccumulator = new Map();
      let text = '';
      for (const entry of parseSSELines(readFileSync(resolve(contractDirectory, fixture.file), 'utf8'))) {
        if (entry.data === '[DONE]') continue;
        const parsed = parser(entry.event, entry.data);
        const events = parsed == null ? [] : Array.isArray(parsed) ? parsed : [parsed];
        for (const event of events) {
          if (event.type === 'delta') text += event.content;
          if (event.type === 'tool_calls') mergeToolCallDeltas(accumulator, event.toolCalls);
        }
      }
      expect(text).toBe(fixture.expected.text);
      expect(finalizeToolCalls(accumulator, 'contract_tool_call')).toHaveLength(
        fixture.expected.tool_calls.length,
      );
    });
  }
});

function providerKind(provider: string): ProviderKind {
  const aliases: Record<string, ProviderKind> = {
    openai: 'openAI',
    moonshot_web_search: 'moonshot',
  };
  return aliases[provider] ?? provider as ProviderKind;
}
