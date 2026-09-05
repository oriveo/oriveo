import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
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

function parseProductionEvents(coverage: Coverage): StreamEvent[] {
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
      return emit(null, { citations: [{ url: 'https://source.example/openrouter', title: 'Source' }] });
    default:
      return emit(null, { choices: [{ delta: { reasoning_content: 'production parser evidence' } }] });
  }
}

describe('shared result-fact matrix', () => {
  it('consumes every one of 15 category-7 fixtures through the production proxy parser', () => {
    expect(facts.providerResultCoverage).toHaveLength(15);
    for (const coverage of facts.providerResultCoverage) {
      expect(existsSync(resolve(repositoryRoot, coverage.producerFixture)), coverage.providerKind).toBe(true);
      const context = contextFor(coverage);
      const result = collectCapabilityResults(context, parseProductionEvents(coverage));
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
