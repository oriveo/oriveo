/**
 * Producers of the "web search confirmed" evidence: Moonshot built-in search, Moonshot
 * Formula and Gemini Interactions.
 *
 * Only `tool_result` / `citations` events count, and only when the adapter parsed them out of
 * the raw upstream frames and the production parser (createProxyChunkParser) passed them
 * through; an HTTP 200, a text body, or a declared tool do not. So every assertion here runs the
 * whole chain (upstream frames -> adapter -> production parser) and never hand-builds
 * downstream events.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { ProviderKind } from '@oriveo/shared/pure-types';
import type { UpstreamTransport } from '../../../ports';
import { createProxyChunkParser } from '../../proxy-chunk-parser';
import type { ProviderRequest } from '../../request-builders/types';
import type { StreamEvent } from '../../types';
import { adaptGeminiInteractionsResponse } from '../gemini-interactions';
import { adaptMoonshotFormulaFiberResponse } from '../moonshot-formula-fiber-loop';
import { adaptMoonshotToolLoopResponse } from '../moonshot-tool-loop';

const recordedMoonshotWebSearch = readFileSync(resolve(
  process.cwd(),
  '../../../shared/test-fixtures/provider-toolcall/recorded/moonshot_web_search.leg1.sse',
), 'utf8');

function sse(body: string): Response {
  return new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
}
function sseOf(payloads: unknown[]): Response {
  return sse(`${payloads.map((payload) => `data: ${JSON.stringify(payload)}\n\n`).join('')}data: [DONE]\n\n`);
}

/** Adapter output has `data:` lines only, so the production parser always sees a null eventType. */
async function parseAdapted(response: Response, providerKind: ProviderKind): Promise<StreamEvent[]> {
  const parse = createProxyChunkParser(providerKind);
  const events: StreamEvent[] = [];
  for (const line of (await response.text()).split('\n')) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('data: ') || trimmed === 'data: [DONE]') continue;
    const result = parse(null, trimmed.slice(6));
    if (result != null) events.push(...(Array.isArray(result) ? result : [result]));
  }
  return events;
}
const toolResults = (events: StreamEvent[]) => events.filter((event) => event.type === 'tool_result');
const citations = (events: StreamEvent[]) => events.filter((event) => event.type === 'citations');

function moonshotRequest(extra: Partial<ProviderRequest> = {}): ProviderRequest {
  return {
    url: 'https://api.moonshot.ai/v1/chat/completions',
    headers: { Authorization: 'Bearer sk-test' },
    body: {
      model: 'kimi-k2.5', stream: true,
      messages: [{ role: 'user', content: 'what is in the news today' }],
      tools: [{ type: 'builtin_function', function: { name: '$web_search' } }],
    },
    ...extra,
  } as ProviderRequest;
}
const answerLeg = () => sseOf([{ choices: [{ delta: { content: 'based on the search results' } }] }]);
const answerTransport: UpstreamTransport = { fetch: async () => answerLeg() };

function webSearchLeg(argumentsText: string): Response {
  return sseOf([
    { choices: [{ delta: { tool_calls: [{ index: 0, id: 't-1', type: 'builtin_function', function: { name: '$web_search', arguments: '' } }] } }] },
    { choices: [{ delta: { tool_calls: [{ index: 0, function: { arguments: argumentsText } }] } }] },
    { choices: [{ delta: {}, finish_reason: 'tool_calls' }] },
  ]);
}

describe('Moonshot built-in search (moonshot.chat.web.v1)', () => {
  it('replaying the recorded Moonshot sample emits one tool_result, confirming web search', async () => {
    const adapted = await adaptMoonshotToolLoopResponse(sse(recordedMoonshotWebSearch), moonshotRequest(), answerTransport);
    const events = await parseAdapted(adapted, 'moonshot');
    // The summary carries the tool name only: no search content and no search_id.
    expect(toolResults(events)).toEqual([{ type: 'tool_result', tool: '$web_search', summary: '$web_search', step: 1 }]);
    expect(events).toContainEqual({ type: 'delta', content: 'based on the search results' });
  });

  it('emits nothing when `$web_search` arguments are not valid JSON or lack a search_id', async () => {
    for (const argumentsText of [
      '{"search_result":',
      '{}',
      '{"search_result":{}}',
      '{"search_result":{"search_id":""}}',
      '{"search_result":{"search_id":42}}',
      '{"search_id":"top-level-is-not-the-documented-shape"}',
      '"a string"',
    ]) {
      const adapted = await adaptMoonshotToolLoopResponse(webSearchLeg(argumentsText), moonshotRequest(), answerTransport);
      const events = await parseAdapted(adapted, 'moonshot');
      expect(toolResults(events), argumentsText).toEqual([]);
      // A missing piece of evidence does not affect feeding back or answering: the loop completes as usual.
      expect(events, argumentsText).toContainEqual({ type: 'delta', content: 'based on the search results' });
    }
  });

  it('emits nothing for a plain answer that never called search', async () => {
    const adapted = await adaptMoonshotToolLoopResponse(answerLeg(), moonshotRequest(), answerTransport);
    expect(toolResults(await parseAdapted(adapted, 'moonshot'))).toEqual([]);
  });
});

describe('Moonshot Formula (moonshot.formula.web.v1)', () => {
  const formulaRequest = () => moonshotRequest({
    moonshotMaxToolLoops: 2,
    moonshotFormula: {
      uri: 'moonshot/web-search:latest',
      toolsPath: '/v1/formulas/moonshot/web-search:latest/tools',
      fibersPath: '/v1/formulas/moonshot/web-search:latest/fibers',
      argumentsMode: 'verbatim',
      resultPaths: ['context.output', 'context.encrypted_output'],
    },
  });
  const formulaLeg = () => sseOf([
    { choices: [{ delta: { tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: 'web_search', arguments: '{"query":"news"}' } }] } }] },
    { choices: [{ delta: {}, finish_reason: 'tool_calls' }] },
  ]);
  const fiberTransport = (context: Record<string, unknown>): UpstreamTransport => ({
    fetch: async (url) => (url.endsWith('/fibers')
      ? new Response(JSON.stringify({ status: 'succeeded', context }), { status: 200, headers: { 'Content-Type': 'application/json' } })
      : answerLeg()),
  });

  it('emits one tool_result when the Formula tool returns a non-empty result through a fiber', async () => {
    for (const context of [{ output: 'search output' }, { encrypted_output: 'opaque-ciphertext' }]) {
      const adapted = await adaptMoonshotFormulaFiberResponse(formulaLeg(), formulaRequest(), fiberTransport(context));
      const events = await parseAdapted(adapted, 'moonshot');
      expect(toolResults(events)).toEqual([{ type: 'tool_result', tool: 'web_search', summary: 'web_search', step: 1 }]);
      expect(events).toContainEqual({ type: 'delta', content: 'based on the search results' });
    }
  });

  it('emits nothing when the fiber returns an empty result', async () => {
    const adapted = await adaptMoonshotFormulaFiberResponse(formulaLeg(), formulaRequest(), fiberTransport({ output: '  ' }));
    expect(toolResults(await parseAdapted(adapted, 'moonshot'))).toEqual([]);
  });
});

describe('Gemini Interactions (gemini.interactions.web.v1)', () => {
  const frame = (event: Record<string, unknown>) => `event: ${String(event.event_type)}\ndata: ${JSON.stringify(event)}\n\n`;
  const stream = (events: Array<Record<string, unknown>>) => sse(events.map(frame).join(''));

  it('a non-empty google_search_result yields a tool_result, and url_citation entries in text_annotation_delta yield citations', async () => {
    const adapted = adaptGeminiInteractionsResponse(stream([
      { event_type: 'step.delta', index: 0, delta: { type: 'google_search_call', arguments: { queries: ['news'] } } },
      { event_type: 'step.delta', index: 1, delta: { type: 'google_search_result', call_id: 'search_1', result: [{ url: 'https://example.com/a', title: 'A' }] } },
      { event_type: 'step.delta', index: 2, delta: { type: 'text', text: 'answer' } },
      { event_type: 'step.delta', index: 2, delta: { type: 'text_annotation_delta', annotations: [
        { type: 'url_citation', url: 'https://example.com/a', title: 'A', start_index: 0, end_index: 6 },
        { type: 'file_citation', document_uri: 'files/1' },
      ] } },
      { event_type: 'step.delta', index: 2, delta: { type: 'text_annotation_delta', annotations: [
        { type: 'url_citation', url: 'https://example.com/b', title: 'B' },
      ] } },
    ]));
    const events = await parseAdapted(adapted, 'gemini');
    expect(toolResults(events)).toEqual([{ type: 'tool_result', tool: 'google_search', summary: 'google_search', step: 1 }]);
    expect(citations(events).at(-1)).toEqual({ type: 'citations', citations: [
      { url: 'https://example.com/a', title: 'A' },
      { url: 'https://example.com/b', title: 'B' },
    ] });
    expect(events).toContainEqual({ type: 'delta', content: 'answer' });
  });

  it('an empty or is_error search result yields no tool_result, and a missing url_citation yields no citations', async () => {
    const adapted = adaptGeminiInteractionsResponse(stream([
      { event_type: 'step.delta', delta: { type: 'google_search_result', result: [] } },
      { event_type: 'step.delta', delta: { type: 'google_search_result', result: [{ url: 'https://example.com/a' }], is_error: true } },
      { event_type: 'step.delta', delta: { type: 'text_annotation_delta', annotations: [{ type: 'file_citation', document_uri: 'files/1' }] } },
      // Only step.delta carries content frames: a same-named delta on other events does not count.
      { event_type: 'interaction.updated', delta: { type: 'google_search_result', result: [{ url: 'https://example.com/a' }] } },
      { event_type: 'step.delta', delta: { type: 'text', text: 'plain answer' } },
    ]));
    const events = await parseAdapted(adapted, 'gemini');
    expect(toolResults(events)).toEqual([]);
    expect(citations(events)).toEqual([]);
    expect(events).toContainEqual({ type: 'delta', content: 'plain answer' });
  });

  it('url_citation annotations on TextContent in a non-streaming response yield citations', async () => {
    const adapted = adaptGeminiInteractionsResponse(new Response(JSON.stringify({
      id: 'int_1', status: 'completed',
      steps: [{ type: 'model_output', content: [{ type: 'text', text: 'answer', annotations: [
        { type: 'url_citation', url: 'https://example.com/a', title: 'A' },
      ] }] }],
    }), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    const events = await parseAdapted(adapted, 'gemini');
    expect(citations(events)).toEqual([{ type: 'citations', citations: [{ url: 'https://example.com/a', title: 'A' }] }]);
    expect(events).toContainEqual({ type: 'delta', content: 'answer' });
  });
});
