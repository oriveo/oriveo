import { describe, expect, it } from 'vitest';
import type { StreamEvent } from '../providers/types';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { collectCapabilityResults, decodeCapabilityResultContext, encodeCapabilityResultContext, requestedCapabilityResults, type CapabilityResultContext } from './capability-result-runtime';

const context: CapabilityResultContext = {
  version: 1,
  revision: 'runtime-r3',
  entries: [{
    owner: 'web', source: 'provider_recipe', wireApplied: true,
    protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1',
    definition: { capability: 'web', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1', signals: [{ kind: 'citation', producerEvent: 'citations', pointer: '/citations', nonEmpty: true }] },
  }],
};

describe('production capability results', () => {
  it('keeps HTTP success with no parser signal unconfirmed', () => {
    expect(collectCapabilityResults(context, [])).toEqual([{ owner: 'web', state: 'unconfirmed', source: 'provider_recipe', revision: 'runtime-r3' }]);
  });

  it('reports requested only from a final wire-applied context', () => {
    expect(requestedCapabilityResults(context)).toEqual([{ owner: 'web', state: 'requested', source: 'provider_recipe', revision: 'runtime-r3' }]);
    expect(requestedCapabilityResults({ ...context, entries: [{ ...context.entries[0], wireApplied: false }] })).toEqual([]);
  });

  it('marks observed only when the exact bound parser emits its declared signal', () => {
    const parser = createProxyChunkParser('openAI');
    const parsed = parser('response.output_text.annotation.added', JSON.stringify({ annotation: {
      type: 'url_citation', url: 'https://example.com', title: 'Source',
    }}));
    const events: StreamEvent[] = parsed ? (Array.isArray(parsed) ? parsed : [parsed]) : [];
    expect(collectCapabilityResults(context, events)[0]?.state).toBe('observed');
  });

  it('does not let a mismatched definition claim observed', () => {
    const mismatched: CapabilityResultContext = { ...context, entries: [{ ...context.entries[0], definition: { ...context.entries[0].definition!, responseParserKind: 'another_parser' } }] };
    const events: StreamEvent[] = [{ type: 'citations', citations: [{ title: 'Source', url: 'https://example.com' }] }];
    expect(collectCapabilityResults(mismatched, events)[0]?.state).toBe('unconfirmed');
  });

  it('keeps a recipe unconfirmed for every unstructured upstream failure', () => {
    for (const failure of ['401', '403', '429', '500', 'network', 'timeout', 'stream']) {
      expect(collectCapabilityResults(context, [])[0]?.state, failure).toBe('unconfirmed');
    }
  });

  it('keeps a custom fragment unconfirmed even when the production parser emits a matching signal', () => {
    const custom: CapabilityResultContext = { ...context, entries: [{ ...context.entries[0], source: 'custom' }] };
    const parser = createProxyChunkParser('openAI');
    const parsed = parser('response.output_text.annotation.added', JSON.stringify({ annotation: {
      type: 'url_citation', url: 'https://example.com', title: 'Source',
    }}));
    const events: StreamEvent[] = parsed ? (Array.isArray(parsed) ? parsed : [parsed]) : [];
    expect(collectCapabilityResults(custom, events)).toEqual([{ owner: 'web', state: 'unconfirmed', source: 'custom', revision: 'runtime-r3' }]);
  });

  it.each([
    ['citation', 'openAI', 'citations', 'response.output_text.annotation.added', { annotation: { type: 'url_citation', url: 'https://example.com', title: 'Source' } }],
    ['reasoning', 'deepseek', 'reasoning', undefined, { choices: [{ delta: { reasoning_content: 'thought' } }] }],
    ['tool result', 'moonshot', 'tool_result', undefined, { type: 'tool_result', tool: 'web_search', summary: 'Source found', step: 1 }],
  ] as const)('requires a non-empty production %s signal', (_name, provider, producerEvent, eventType, payload) => {
    const evidenceContext: CapabilityResultContext = {
      ...context,
      entries: [{
        ...context.entries[0],
        responseParserKind: `${producerEvent}_v1`,
        definition: {
          ...context.entries[0].definition!,
          responseParserKind: `${producerEvent}_v1`,
          signals: [{ kind: producerEvent === 'reasoning' ? 'thinking_block' : producerEvent === 'tool_result' ? 'provider_tool_result' : 'citation', producerEvent, pointer: '/evidence', nonEmpty: true }],
        },
      }],
    };
    const parser = createProxyChunkParser(provider);
    const parsed = parser(eventType ?? null, JSON.stringify(payload));
    const events: StreamEvent[] = parsed ? (Array.isArray(parsed) ? parsed : [parsed]) : [];
    expect(events.some((event) => event.type === producerEvent), _name).toBe(true);
    expect(collectCapabilityResults(evidenceContext, events)[0]?.state, _name).toBe('observed');

    const emptyPayload = producerEvent === 'citations'
      ? { annotation: { type: 'url_citation' } }
      : producerEvent === 'reasoning'
        ? { choices: [{ delta: { reasoning_content: '' } }] }
        : { type: 'tool_result', tool: 'web_search', summary: '', step: 1 };
    const emptyParsed = parser(eventType ?? null, JSON.stringify(emptyPayload));
    const emptyEvents: StreamEvent[] = emptyParsed ? (Array.isArray(emptyParsed) ? emptyParsed : [emptyParsed]) : [];
    expect(collectCapabilityResults(evidenceContext, emptyEvents)[0]?.state, `${_name} empty`).toBe('unconfirmed');
  });

  it('round-trips only a bounded header-safe context', () => {
    expect(decodeCapabilityResultContext(encodeCapabilityResultContext(context))).toEqual(context);
    expect(decodeCapabilityResultContext('not-json')).toBeNull();
  });
});
