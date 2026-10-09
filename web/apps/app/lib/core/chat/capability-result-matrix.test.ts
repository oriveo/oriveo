import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { adaptGeminiInteractionsResponse } from '@oriveo/core/providers/response-adapters/gemini-interactions';
import { adaptMoonshotFormulaFiberResponse } from '@oriveo/core/providers/response-adapters/moonshot-formula-fiber-loop';
import { adaptMoonshotToolLoopResponse } from '@oriveo/core/providers/response-adapters/moonshot-tool-loop';
import type { StreamEvent } from '../providers/types';
import { buildCapabilityResultContext, collectCapabilityResults, type CapabilityResultContext } from './capability-result-runtime';
import { decideCapabilityRecovery } from './capability-recovery-runtime';

type Coverage = {
  providerKind: Parameters<typeof createProxyChunkParser>[0];
  recipeRef: string;
  transport: string;
  expected: 'observed' | 'unconfirmed' | 'no_execution_fact';
  producerFixture: string;
  producerEvents: string[];
};
type RecoveryCase = {
  providerKind: Parameters<typeof createProxyChunkParser>[0];
  recipeRef: string;
  providerCoverage: boolean;
  automaticRetryCount: number;
  expected: 'surface_error' | 'user_confirmed_resend_without_located_setting';
  status: number; preToken: boolean; streamStarted: boolean; sideEffects: boolean; source: 'provider_recipe' | 'custom';
  customOwners?: Array<'web' | 'reasoning' | 'generation'>;
  structuredError?: unknown;
  customAppliedPointers?: Partial<Record<'web' | 'reasoning' | 'generation', string[]>>;
};
type Definition = NonNullable<CapabilityResultContext['entries'][number]['definition']>;

const repositoryRoot = resolve(process.cwd(), '../../..');
const facts = JSON.parse(readFileSync(resolve(repositoryRoot, 'shared/model-contracts/provider_recipe_result_facts.v1.json'), 'utf8')) as {
  providerResultCoverage: Coverage[];
  recoveryCases: RecoveryCase[];
};
const definitions = JSON.parse(readFileSync(resolve(repositoryRoot, 'shared/capabilityrecipe/capability_result_definitions.v1.json'), 'utf8')) as {
  recipeBindings: Record<string, { responseEvidenceRef: string; errorRecoveryRef: string }>;
  responseEvidenceDefinitions: Record<string, Definition>;
  errorRecoveryDefinitions: { locatorRules: Record<string, unknown> };
};
const registry = JSON.parse(readFileSync(resolve(repositoryRoot, 'shared/capabilityrecipe/capability_runtime.v1.json'), 'utf8')) as {
  recipes: Record<string, Record<string, unknown>>;
};

/**
 * Rebuilds the wire envelope exactly as the result definitions publish it - the pre-load registry
 * has no `responseEvidenceRef` and the bindings inject it - and then runs the
 * real proxy-route entry builder over it. The context is therefore production output, not a
 * hand-written expectation of what the route "should" emit.
 */
const runtimeEnvelope = {
  revision: 'fixture-runtime-r3',
  recipes: Object.fromEntries(Object.entries(registry.recipes)
    .map(([ref, recipe]) => [ref, { ...recipe, ...definitions.recipeBindings[ref] }])),
  responseEvidenceDefinitions: definitions.responseEvidenceDefinitions,
};

function contextFor(coverage: Pick<Coverage, 'recipeRef'>): CapabilityResultContext | null {
  return buildCapabilityResultContext({
    recipeRefs: [coverage.recipeRef],
    // Deliberately claims every owner reached the wire: production must still drop generation.
    wireAppliedOwners: { web: true, reasoning: true, generation: true },
  }, runtimeEnvelope);
}

const sseResponse = (body: string) => new Response(body, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
const answerLeg = () => sseResponse('data: {"choices":[{"delta":{"content":"answer"}}]}\n\ndata: [DONE]\n\n');
const moonshotRequest = {
  url: 'https://api.moonshot.ai/v1/chat/completions',
  headers: { Authorization: 'Bearer sk-test' },
  body: { model: 'kimi-k2.6', stream: true, messages: [{ role: 'user', content: 'news' }] },
};

/** Feeds adapter-produced SSE to the production parser, the same path the browser takes after receiving the route response (`data:` lines only). */
async function parseAdapted(response: Response, providerKind: Coverage['providerKind']): Promise<StreamEvent[]> {
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

async function parseProductionEvents(coverage: Coverage): Promise<StreamEvent[]> {
  const parse = createProxyChunkParser(coverage.providerKind);
  const emit = (eventType: string | null, payload: unknown) => {
    const result = parse(eventType, JSON.stringify(payload));
    return result == null ? [] : Array.isArray(result) ? result : [result];
  };
  if (coverage.expected === 'unconfirmed') {
    return emit(null, { choices: [{ delta: { content: 'ordinary answer' } }] });
  }
  switch (coverage.providerKind) {
    case 'openAI':
    case 'grok':
      return emit('response.output_text.annotation.added', { annotation: { type: 'url_citation', url: 'https://source.example/openai', title: 'Source' } });
    case 'anthropic':
      return emit('content_block_start', { type: 'content_block_start', content_block: { type: 'web_search_tool_result', content: [{ url: 'https://source.example/anthropic', title: 'Source', cited_text: 'evidence' }] } });
    case 'gemini':
      return emit(null, { candidates: [{ groundingMetadata: { groundingChunks: [{ web: { uri: 'https://source.example/gemini', title: 'Source' } }] } }] });
    case 'openRouter':
      // The shape the OpenRouter web plugin really sends: sources in delta.annotations (url_citation), arriving before the answer.
      // This used to feed a top-level `citations`, which the upstream never sends, so this cell could never reach "confirmed" in production.
      return [
        ...emit(null, { choices: [{ delta: { content: '', annotations: [{ type: 'url_citation', url_citation: { url: 'https://source.example/openrouter', title: 'Source', content: 'evidence' } }] } }] }),
        ...emit(null, { choices: [{ delta: { content: 'answer' } }] }),
      ];
    case 'zhipu':
      // Shape from the official API reference: search results sit in a top-level `web_search` array and the link field is `link`.
      return emit(null, { choices: [{ delta: { content: 'answer' }, finish_reason: 'stop' }], web_search: [{ title: 'Source', link: 'https://source.example/zhipu', content: 'evidence' }] });
    case 'moonshot': {
      // The recorded first leg (`$web_search` + search_result.search_id) is replayed through the production tool-loop adapter;
      // the adapter produces the evidence event and the parser passes it through, so nothing is hand-built here.
      const recorded = readFileSync(resolve(repositoryRoot, 'shared/test-fixtures/provider-toolcall/recorded/moonshot_web_search.leg1.sse'), 'utf8');
      const adapted = await adaptMoonshotToolLoopResponse(sseResponse(recorded), moonshotRequest, { fetch: async () => answerLeg() });
      return parseAdapted(adapted, 'moonshot');
    }
    default:
      return emit(null, { choices: [{ delta: { reasoning_content: 'production parser evidence' } }] });
  }
}

describe('shared result-fact matrix', () => {
  it('consumes every one of 15 category-7 fixtures through the production proxy parser', async () => {
    expect(facts.providerResultCoverage).toHaveLength(15);
    for (const coverage of facts.providerResultCoverage) {
      expect(existsSync(resolve(repositoryRoot, coverage.producerFixture)), coverage.providerKind).toBe(true);
      const context = contextFor(coverage);
      const result = collectCapabilityResults(context, await parseProductionEvents(coverage));
      if (coverage.expected === 'no_execution_fact') {
        // A generation recipe produces no execution fact at all, not even not_requested.
        expect(context, coverage.providerKind).toBeNull();
        expect(result, coverage.providerKind).toEqual([]);
        continue;
      }
      expect(result).toHaveLength(1);
      expect(result[0]?.state, coverage.providerKind).toBe(coverage.expected);
    }
  });

  it('confirms web for the adapter-produced recipes that have no row of their own in the shared facts', async () => {
    const stateOf = (recipeRef: string, events: StreamEvent[]) => collectCapabilityResults(contextFor({ recipeRef }), events).map((item) => item.state);
    const interactions = (deltas: unknown[]) => adaptGeminiInteractionsResponse(sseResponse(deltas
      .map((delta) => `event: step.delta\ndata: ${JSON.stringify({ event_type: 'step.delta', delta })}\n\n`).join('')));

    expect(stateOf('gemini.interactions.web.v1', await parseAdapted(interactions([
      { type: 'google_search_result', result: [{ url: 'https://source.example/gemini', title: 'Source' }] },
    ]), 'gemini'))).toEqual(['observed']);
    expect(stateOf('gemini.interactions.web.v1', await parseAdapted(interactions([
      { type: 'text_annotation_delta', annotations: [{ type: 'url_citation', url: 'https://source.example/gemini', title: 'Source' }] },
    ]), 'gemini'))).toEqual(['observed']);
    expect(stateOf('gemini.interactions.web.v1', await parseAdapted(interactions([
      { type: 'text', text: 'ordinary answer' },
    ]), 'gemini'))).toEqual(['unconfirmed']);

    const formulaLeg = sseResponse('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{}"}}]}}]}\n\ndata: [DONE]\n\n');
    const formula = await adaptMoonshotFormulaFiberResponse(formulaLeg, {
      ...moonshotRequest,
      moonshotFormula: {
        uri: 'moonshot/web-search:latest', toolsPath: '/v1/formulas/moonshot/web-search:latest/tools',
        fibersPath: '/v1/formulas/moonshot/web-search:latest/fibers', argumentsMode: 'verbatim', resultPaths: ['context.output'],
      },
    }, { fetch: async (url) => (url.endsWith('/fibers')
      ? new Response(JSON.stringify({ status: 'succeeded', context: { output: 'search output' } }))
      : answerLeg()) });
    expect(stateOf('moonshot.formula.web.v1', await parseAdapted(formula, 'moonshot'))).toEqual(['observed']);
  });

  it('never emits an owner=generation execution fact for any recipe in the Server registry', () => {
    const generationRefs = Object.entries(registry.recipes)
      .filter(([, recipe]) => recipe.capability === 'generation')
      .map(([ref]) => ref);
    expect(generationRefs.length).toBe(17);
    for (const recipeRef of generationRefs) {
      expect(contextFor({ recipeRef }), recipeRef).toBeNull();
    }
    // A recipe list mixing owners keeps the non-generation entries and drops only generation.
    const mixed = buildCapabilityResultContext({
      recipeRefs: ['openai.responses.web.v1', 'openai.responses.generation.v1'],
      wireAppliedOwners: { web: true, generation: true },
    }, runtimeEnvelope);
    expect(mixed?.entries.map((entry) => entry.owner)).toEqual(['web']);
  });

  it('consumes every category-8 case as surface-error only while locatorRules are empty', () => {
    expect(Object.keys(definitions.errorRecoveryDefinitions.locatorRules)).toEqual([]);
    const providerCoverage = facts.recoveryCases.filter((item) => item.providerCoverage).map((item) => item.providerKind).sort();
    expect(providerCoverage).toEqual(facts.providerResultCoverage.map((item) => item.providerKind).sort());
    for (const recovery of facts.recoveryCases) {
      const context = contextFor({ recipeRef: recovery.recipeRef });
      const result = collectCapabilityResults(context, []);
      expect(result.map((item) => item.state), recovery.recipeRef).not.toContain('rejected');
      expect(result.map((item) => item.state), recovery.recipeRef).not.toContain('recovered');
      // A prior attempt may be represented by the fixture, but the empty
      // locator map permits no further automatic recovery or state upgrade.
      expect(recovery.automaticRetryCount, recovery.recipeRef).toBeLessThanOrEqual(1);
      expect(decideCapabilityRecovery(recovery, definitions.errorRecoveryDefinitions), recovery.recipeRef).toBe(recovery.expected);
    }
  });

  it('fails closed for dangling, cross-recipe, wrong-field and foreign-pointer locator maps', () => {
    const input = { status: 400, preToken: true, streamStarted: false, sideEffects: false, automaticRetryCount: 0, source: 'provider_recipe' as const, recipeRefs: ['openai.responses.web.v1'], recipes: runtimeEnvelope.recipes, structuredError: { error: { code: 'unsupported_parameter' } } };
    for (const locatorRules of [
      { dangling: { recipeRef: 'missing', pointer: '/tools/0' } },
      { crossRecipe: { recipeRef: 'anthropic.messages.web.v1', pointer: '/tools/0' } },
      { wrongFields: { status: 401, error: { code: 'unsupported' }, pointer: '/tools/0' } },
      { foreignPointer: { pointer: '/messages/0/content' } },
    ]) {
      expect(decideCapabilityRecovery(input, { locatorRules })).toBe('surface_error');
    }
  });

  it('admits a same-recipe exact structured locator only as explicit resend', () => {
    const input = {
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'provider_recipe' as const,
      recipeRefs: ['openai.responses.web.v1'],
      recipes: { 'openai.responses.web.v1': {
        capability: 'web', errorRecoveryRef: 'openai.responses.web', responseParserKind: 'openai_responses_web_v1',
        transport: { protocol: 'openai_responses' }, requestOps: [{ op: 'set', pointer: '/tools' }],
      } },
      structuredError: { error: { code: 'unsupported_parameter' } },
    };
    expect(decideCapabilityRecovery(input, { 'openai.responses.web': {
      capability: 'web', protocol: 'openai_responses', responseParserKind: 'openai_responses_web_v1',
      locatorRules: [{ owner: 'web', status: 400, pointers: ['/tools'], errorFields: { '/error/code': 'unsupported_parameter' } }],
    } })).toBe('user_confirmed_resend_without_located_setting');
  });
});
