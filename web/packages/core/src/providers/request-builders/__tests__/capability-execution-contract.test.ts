import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { mapContinuationForRecipe } from '../continuation-replay';
import { compileSafeCustomFragment } from '../safe-custom-fragment';
import { attachCapabilityExecution, canonicalRecipeTransport, resolveRuntimeRecipe } from '../capability-execution';
import { buildGeminiInteractionsRequest } from '../gemini-interactions';
import { buildProviderRequest, previewSafeCustomFragment } from '../dispatch';
import { prepareMoonshotFormulaRequest, adaptMoonshotFormulaFiberResponse } from '../../response-adapters/moonshot-formula-fiber-loop';
import { adaptGeminiInteractionsResponse } from '../../response-adapters/gemini-interactions';
import { createProxyChunkParser } from '../../proxy-chunk-parser';
import type { ProviderRequest } from '../types';
import type { UpstreamTransport } from '../../../ports';

interface Fixture { registryPath: string; providerCoverage: Array<any>; continuationRecipeCoverage: Array<any>; executionCases: Array<any>; continuationCases: Array<any>; safeCustomCases: Array<any> }
const fixture = JSON.parse(readFileSync(root('shared/model-contracts/provider_recipe_execution.v1.json'), 'utf8')) as Fixture;
const recipes = (JSON.parse(readFileSync(root(fixture.registryPath), 'utf8')) as { recipes: Record<string, unknown> }).recipes;
const customControlDefinitions = (JSON.parse(readFileSync(root('shared/model-contracts/request_shape_contract.v2.json'), 'utf8')) as any).fixtures.sharedControlDefinitions as Record<string, any>;

describe('shared capability execution fixture', () => {
  for (const coverage of fixture.providerCoverage) {
    it(`coverage.${coverage.providerKind}.default_omits_all_auto_recipe_deltas`, async () => {
      const request = await buildProviderRequest({ providerKind: coverage.providerKind, apiKey: 'key', modelID: coverage.modelId, messages: [{ role: 'user', content: 'plain chat' }] }, async () => metadata(coverage.providerKind, coverage.modelId, coverage.selectorTransport ?? coverage.transport, coverage.recipeRef));
      expect(request.capabilityExecution).toBeUndefined();
    });
    for (const stream of [true, false]) {
      it(`coverage.${coverage.providerKind}.stream_${stream}_uses_the_real_builder`, async () => {
        const request = await buildProviderRequest({
          providerKind: coverage.providerKind, apiKey: 'key', modelID: coverage.modelId,
          messages: [{ role: 'user', content: 'plain chat' }], stream,
          options: { generationParameters: { temperature: { state: 'value', value: 0.2 } } },
        }, async () => metadata(coverage.providerKind, coverage.modelId, coverage.selectorTransport ?? coverage.transport, coverage.recipeRef));
        expect(request.capabilityExecution?.recipeRefs).toEqual([coverage.recipeRef]);
        // generation does not enter the execution fact layer, and all 17 rows here are
        // generation recipes, so wireAppliedOwners must be left empty. The other half of
        // the same assertion is the "parameters still sent" check below: what is switched
        // off is the after-the-fact badge, not the parameter injection.
        expect(request.capabilityExecution?.wireAppliedOwners, coverage.providerKind).toEqual({});
        const generationWire = coverage.transport === 'gemini_generate_content'
          ? (request.body.generationConfig as { temperature?: unknown } | undefined)?.temperature
          : request.body.temperature;
        expect(generationWire, `${coverage.providerKind} typed generation parameter must still reach the wire`).toBe(0.2);
        // Every builder must carry the requested mode to its production transport shape; the
        // exact nesting varies by protocol, so assert on the actual serialized request rather
        // than duplicating 15 provider wire schemas here.
        if (coverage.transport === 'gemini_generate_content') {
          expect(request.url).toContain(stream ? ':streamGenerateContent?alt=sse' : ':generateContent');
        } else if (coverage.transport === 'openai_responses') {
          expect(request.url).toMatch(/\/responses(?:\?|$)/);
          expect(JSON.stringify(request.body)).toContain(`"stream":${stream}`);
        } else if (coverage.transport === 'anthropic_messages') {
          expect(request.url).toMatch(/\/messages(?:\?|$)/);
          expect(JSON.stringify(request.body)).toContain(`"stream":${stream}`);
        } else {
          expect(request.url).toMatch(/\/chat\/completions(?:\?|$)/);
          expect(JSON.stringify(request.body)).toContain(`"stream":${stream}`);
        }
        const sample = providerResponseSample(coverage.transport, stream);
        const parsed = createProxyChunkParser(coverage.providerKind)(sample.eventType, JSON.stringify(sample.payload));
        expect(parsed == null ? [] : Array.isArray(parsed) ? parsed : [parsed]).toContainEqual({ type: 'delta', content: 'fixture response' });
      });
    }
    it(`coverage.${coverage.providerKind}.safe_custom_requires_authoritative_control_refs`, async () => {
      const metadataForCoverage = async () => metadata(coverage.providerKind, coverage.modelId, coverage.selectorTransport ?? coverage.transport, coverage.recipeRef);
      await expect(buildProviderRequest({
        providerKind: coverage.providerKind, apiKey: 'key', modelID: coverage.modelId,
        messages: [{ role: 'user', content: 'plain chat' }],
        options: { customFragment: { raw: customTemperatureRaw(coverage.recipeRef) } },
      }, metadataForCoverage)).rejects.toThrow('Safe custom fragment rejected: unknown_owned_path');
      await expect(buildProviderRequest({
        providerKind: coverage.providerKind, apiKey: 'key', modelID: coverage.modelId,
        messages: [{ role: 'user', content: 'plain chat' }],
        options: { generationParameters: { temperature: { state: 'value', value: 0.1 } }, customFragment: { raw: '{"model":"forbidden"}' } },
      }, metadataForCoverage)).rejects.toThrow('Safe custom fragment rejected: forbidden_root');
    });
    // An owner that reaches this boundary was explicitly set to custom by the user. An
    // empty draft does not mean "nothing to apply" - silently skipping it would send a
    // degraded request, while the editor says in red that messages using that control will
    // fail to send. Fail closed, so that statement stays true.
    it(`coverage.${coverage.providerKind}.empty_custom_draft_fails_closed`, async () => {
      const metadataForCoverage = async () => metadata(coverage.providerKind, coverage.modelId, coverage.selectorTransport ?? coverage.transport, coverage.recipeRef);
      await expect(buildProviderRequest({
        providerKind: coverage.providerKind, apiKey: 'key', modelID: coverage.modelId,
        messages: [{ role: 'user', content: 'plain chat' }],
        options: { customFragments: { generation: { raw: '   ' } } },
      }, metadataForCoverage)).rejects.toThrow(/Safe custom fragment rejected/);
    });
  }

  it('binds all 19 server selector continuation rows to an exact shared coverage row', () => {
    expect(fixture.continuationRecipeCoverage).toHaveLength(19);
    expect(new Set(fixture.continuationRecipeCoverage.map((row) => row.recipeRef)).size).toBe(19);
    expect(fixture.continuationRecipeCoverage).toContainEqual(expect.objectContaining({
      providerKind: 'miniMax', transport: 'openai_chat', modelId: 'MiniMax-M3',
      recipeRef: 'minimax.messages.web.v1', responseParserKind: 'minimax_anthropic_web_v1',
      continuationKind: 'replay_blocks', selectorExpected: true,
    }));
    for (const row of fixture.continuationRecipeCoverage) {
      expect(recipes[row.recipeRef], row.recipeRef).toBeDefined();
    }
  });

  for (const coverage of fixture.continuationRecipeCoverage) {
    it(`continuation.${coverage.recipeRef}.exact_control_reaches_the_real_builder`, async () => {
      const recipe = recipes[coverage.recipeRef] as any;
      const request = await buildProviderRequest(
        requestForRecipe(recipe, coverage.modelId),
        async () => metadata(
          coverage.providerKind,
          coverage.modelId,
          coverage.selectorTransport ?? coverage.transport,
          coverage.recipeRef,
        ),
      );
      expect(request.capabilityExecution?.recipeRefs).toEqual([coverage.recipeRef]);
      expect(request.continuationCapture).toEqual({
        kind: coverage.continuationKind,
        protocol: recipe.route?.sourceProtocol === recipe.transport?.protocol
          ? recipe.route.protocol
          : coverage.transport,
        responseParserKind: coverage.responseParserKind,
      });
    });
  }

  for (const [recipeRef, recipe] of Object.entries(recipes)) {
    const entry = recipe as any;
    if (!['web', 'reasoning', 'generation'].includes(entry.capability) || !entry.transport?.protocol) continue;
    it(`recipe.${recipeRef}.transport_miss_keeps_plain_chat`, async () => {
      const modelId = `fixture-${recipeRef}`;
      const request = await buildProviderRequest(requestForRecipe(entry, modelId), async () => metadata(entry.providerKind, modelId, 'mismatched_transport', recipeRef));
      expect(request.capabilityExecution).toBeUndefined();
    });
    it(`recipe.${recipeRef}.active_control_compiles_through_real_builder`, async () => {
      const modelId = `fixture-active-${recipeRef}`;
      const request = await buildProviderRequest(requestForRecipe(entry, modelId), async () => metadata(entry.providerKind, modelId, entry.transport.protocol, recipeRef));
      expect(request.capabilityExecution?.recipeRefs).toEqual([recipeRef]);
      if (entry.continuationKind !== 'none') {
        expect(request.continuationCapture).toEqual({
          kind: entry.continuationKind,
          protocol: entry.route?.sourceProtocol === entry.transport.protocol
            ? entry.route.protocol
            : entry.transport.protocol,
          responseParserKind: entry.responseParserKind,
        });
      }
      if (entry.executionKind === 'endpoint_route') {
        // Empty model/Fiber deltas and endpoint tools are assertions over actual builder output,
        // not a parallel hand-written expected JSON body.
        expect(request.capabilityExecution?.delta).toEqual({ tools: request.body.tools });
      } else if (entry.executionKind === 'model_route' || entry.requestOps.length === 0) {
        expect(request.capabilityExecution?.delta).toEqual({});
      } else {
        expect(Object.keys(request.capabilityExecution?.delta ?? {}).length).toBeGreaterThan(0);
      }
    });
  }
  it('accepts Formula/Fiber and the explicitly routed Gemini recipe, without model-name inference', () => {
    expect(resolveRuntimeRecipe(recipes, 'moonshot.formula.web.v1', 'moonshot', 'openai_chat', 'web').accepted).toBe(true);
    expect(resolveRuntimeRecipe(recipes, 'gemini.interactions.web.v1', 'gemini', 'gemini_interactions', 'web').accepted).toBe(true);
    // Current generateContent models cannot accidentally hop endpoints merely because web is requested.
    expect(resolveRuntimeRecipe(recipes, 'gemini.interactions.web.v1', 'gemini', 'gemini_generate_content', 'web')).toEqual({ accepted: false, reason: 'transport_mismatch' });
    expect(canonicalRecipeTransport('gemini_generate')).toBe('gemini_generate_content');
  });

  it('marks external connectors as a no-execute boundary instead of falling back to provider fetch', () => {
    expect(() => attachCapabilityExecution({ url: 'https://example.invalid', headers: {}, body: {} }, { overridesLegacy: new Set(), recipes: [{ id: 'external.web.v1', providerKind: 'external', capability: 'web', executionKind: 'external_connector', requestOps: [] }], noExecute: true })).toThrow('forbids client-side execution');
  });

  for (const execution of fixture.executionCases) {
    it(`execution.${execution.caseId}.uses_the_real_dispatch_boundary`, async () => {
      if (execution.executionKind === 'external_connector') {
        const externalRecipes = { ...recipes, 'fixture.external.v1': { id: 'fixture.external.v1', providerKind: 'openAI', capability: 'web', executionKind: 'external_connector', transport: { protocol: 'openai_chat' }, requestOps: [] } };
        await expect(buildProviderRequest({ providerKind: 'openAI', apiKey: 'key', modelID: 'external-fixture', messages: execution.input.messages, options: { supportsWebSearch: true } }, async () => metadataWithRecipes('openAI', 'external-fixture', 'openai_chat', 'fixture.external.v1', externalRecipes))).rejects.toThrow('forbids client-side execution');
        return;
      }
      const targetTransport = execution.expected.targetTransport ?? execution.transport;
      const request = await buildProviderRequest({
        providerKind: execution.providerKind, apiKey: 'key', modelID: execution.input.modelId,
        messages: execution.input.messages, stream: execution.input.stream, options: { supportsWebSearch: true },
      }, async () => metadata(execution.providerKind, execution.input.modelId, targetTransport, execution.recipeRef));
      expect(request.capabilityExecution?.recipeRefs).toEqual([execution.recipeRef]);
      expect(request.moonshotMaxToolLoops).toBe(execution.expected.maxToolLoops ?? undefined);
      if (execution.expected.responseAdapter) expect(request.responseAdapter).toBe(execution.expected.responseAdapter);
      if (execution.expected.endpointPath) expect(new URL(request.url).pathname).toBe(execution.expected.endpointPath);
      if (execution.expected.method) expect(execution.expected.method).toBe('POST');
      if (execution.expected.authHeader) expect(request.headers[execution.expected.authHeader]).toBe('key');
      if (execution.expected.headers) expect(request.headers).toMatchObject(execution.expected.headers);
      if (execution.expected.bodyDelta) expect(request.body).toMatchObject(execution.expected.bodyDelta);
    });
  }

  it('executes the shared MiniMax M3 alternate-route case through request, parser and continuation producers', async () => {
    const execution = fixture.executionCases.find((item) => item.caseId === 'minimax_m3_anthropic_server_web_alternate_route');
    expect(execution).toBeDefined();
    const continuationCase = fixture.continuationCases.find((item) => item.caseId === 'continuation.replay_minimax_m3_server_web_blocks');
    expect(continuationCase).toBeDefined();
    const request = await buildProviderRequest({
      providerKind: 'miniMax', apiKey: 'key', modelID: execution.input.modelId,
      messages: execution.input.messages, stream: true, options: { supportsWebSearch: true },
      continuation: {
        kind: continuationCase.kind, step: continuationCase.step, state: continuationCase.state,
      },
    }, async () => metadata('miniMax', execution.input.modelId, execution.transport, execution.recipeRef));

    expect(request).toMatchObject({
      url: 'https://api.minimax.io/anthropic/v1/messages',
      headers: {
        'Content-Type': 'application/json', 'anthropic-version': '2023-06-01', 'x-api-key': 'key',
      },
      body: {
        model: 'MiniMax-M3', stream: true,
        tools: [{ type: 'web_search_20250305', name: 'web_search' }],
      },
      continuationCapture: {
        kind: 'replay_blocks', protocol: 'anthropic_messages', responseParserKind: 'minimax_anthropic_web_v1',
      },
    });
    expect(request.headers).not.toHaveProperty('Authorization');
    expect(request.body).not.toHaveProperty('reasoning_split');
    expect((request.body.messages as Array<{ role: string; content: unknown }>)[0]).toEqual({
      role: 'assistant', content: continuationCase.state.blocks,
    });
    expect((request.body.messages as Array<{ role: string }>).at(-1)?.role).toBe('user');

    const parser = createProxyChunkParser('miniMax', request.continuationCapture);
    const blocks = continuationCase.state.blocks as Array<Record<string, unknown>>;
    const frames = [
      ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '', signature: '' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'opaque reasoning' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'signature_delta', signature: 'opaque-signature' } }],
      ['content_block_start', { type: 'content_block_start', index: 1, content_block: { type: 'text', text: '' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: 'Searching.' } }],
      ['content_block_start', { type: 'content_block_start', index: 2, content_block: { type: 'server_tool_use', id: 'call_web_1', name: 'web_search', input: {} } }],
      ['content_block_delta', { type: 'content_block_delta', index: 2, delta: { type: 'input_json_delta', partial_json: '{"query":"latest news"}' } }],
      ['content_block_start', { type: 'content_block_start', index: 3, content_block: blocks[3] }],
      ['content_block_start', { type: 'content_block_start', index: 4, content_block: { type: 'text', text: '' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 4, delta: { type: 'text_delta', text: 'Answer.' } }],
    ] as const;
    const events = frames.flatMap(([eventType, payload]) => normalizedEvents(parser(eventType, JSON.stringify(payload))));
    events.push(...normalizedEvents(parser('message_stop', JSON.stringify({ type: 'message_stop' }))));
    expect(events).toContainEqual({ type: 'reasoning', content: 'opaque reasoning' });
    expect(events).toContainEqual({
      type: 'citations', citations: [{ url: 'https://example.com/news', title: 'Example', snippet: 'opaque result' }],
    });
    expect(events).toContainEqual({ type: 'tool_result', tool: 'web_search', summary: 'Example', step: 3 });
    expect(events).toContainEqual({
      type: 'continuation', continuation: { kind: 'replay_blocks', step: 1, state: { blocks } },
    });
  });

  it('keeps MiniMax OpenAI fallback for web-off, non-exact models, missing recipes and malformed routes', async () => {
    const exactRecipe = recipes['minimax.messages.web.v1'] as any;
    const cases: Array<{ modelID: string; web: boolean; metadata: () => any }> = [
      { modelID: 'MiniMax-M3', web: false, metadata: () => metadata('miniMax', 'MiniMax-M3', 'openai_chat', 'minimax.messages.web.v1') },
      { modelID: 'MiniMax-M2.7', web: true, metadata: () => plainMetadata('miniMax', 'MiniMax-M2.7', 'openai_chat') },
      { modelID: 'MiniMax-M3', web: true, metadata: () => metadataWithRecipes('miniMax', 'MiniMax-M3', 'openai_chat', 'minimax.messages.web.v1', {}) },
      { modelID: 'MiniMax-M3', web: true, metadata: () => metadataWithRecipes('miniMax', 'MiniMax-M3', 'openai_chat', 'minimax.messages.web.v1', {
        ...recipes,
        'minimax.messages.web.v1': { ...exactRecipe, route: { ...exactRecipe.route, path: '/v1/chat/completions' } },
      }) },
    ];
    for (const item of cases) {
      const request = await buildProviderRequest({
        providerKind: 'miniMax', apiKey: 'key', modelID: item.modelID,
        messages: [{ role: 'user', content: 'plain chat' }],
        options: { supportsWebSearch: item.web },
      }, async () => item.metadata());
      expect(request.url, item.modelID).toBe('https://api.minimax.io/v1/chat/completions');
      expect(request.body.reasoning_split, item.modelID).toBe(true);
      expect(request.body).not.toHaveProperty('tools');
      expect(request.headers).toHaveProperty('Authorization', 'Bearer key');
    }
  });

  it('builds the official Gemini GA /v1/interactions streaming and non-streaming paths', () => {
    const route = (recipes['gemini.interactions.web.v1'] as any).route;
    const base = { providerKind: 'gemini' as const, apiKey: 'key', modelID: 'gemini-3-flash', messages: [{ role: 'user' as const, content: 'news' }] };
    expect(buildGeminiInteractionsRequest(base, route)).toMatchObject({ url: 'https://generativelanguage.googleapis.com/v1/interactions', body: { model: 'gemini-3-flash', input: [{ role: 'user', parts: [{ text: 'news' }] }], stream: true } });
    expect(buildGeminiInteractionsRequest({ ...base, stream: false }, route).body.stream).toBe(false);
  });

  it('adapts the current Gemini steps SSE and retains its nested interaction id and usage', async () => {
    const upstream = new Response([
      'event: interaction.created\ndata: {"interaction":{"id":"int_1","status":"in_progress"},"event_type":"interaction.created"}\n\n',
      'event: interaction.updated\ndata: {"event_type":"interaction.updated","delta":{"type":"text","text":"must-not-surface"}}\n\n',
      'event: step.delta\ndata: {"event_type":"step.delta","delta":{"type":"text","text":"hello"}}\n\n',
      'event: interaction.completed\ndata: {"interaction":{"id":"int_1","usage":{"total_input_tokens":2,"total_output_tokens":3,"total_tokens":5}},"event_type":"interaction.completed"}\n\n',
    ].join(''), { headers: { 'Content-Type': 'text/event-stream' } });
    const body = await adaptGeminiInteractionsResponse(upstream).text();
    expect(body).toContain('"previousResponseId":"int_1"');
    expect(body.match(/"previousResponseId":"int_1"/g)).toHaveLength(1);
    expect(body).toContain('"content":"hello"');
    expect(body).not.toContain('must-not-surface');
    expect(body).toContain('"prompt_tokens":2');
    expect(body).toContain('"completion_tokens":3');
  });

  it('selects Formula and endpoint routes through the real production dispatcher only when metadata activates them', async () => {
    const formula = await buildProviderRequest({ providerKind: 'moonshot', apiKey: 'key', modelID: 'kimi-k3', messages: [{ role: 'user', content: 'news' }], options: { supportsWebSearch: true } }, async () => metadata('moonshot', 'kimi-k3', 'openai_chat', 'moonshot.formula.web.v1'));
    expect(formula).toMatchObject({ responseAdapter: 'moonshot_formula_fiber_loop', moonshotFormula: (recipes['moonshot.formula.web.v1'] as any).formula });
    expect(formula.body.tools).toBeUndefined();

    const interactions = await buildProviderRequest({ providerKind: 'gemini', apiKey: 'key', modelID: 'gemini-3-flash', messages: [{ role: 'user', content: 'news' }], options: { supportsWebSearch: true }, continuation: { kind: 'previous_id', step: 1, state: { previousResponseId: 'interaction_1' } } }, async () => metadata('gemini', 'gemini-3-flash', 'gemini_interactions', 'gemini.interactions.web.v1'));
    expect(interactions).toMatchObject({ responseAdapter: 'gemini_interactions', url: 'https://generativelanguage.googleapis.com/v1/interactions', body: { tools: [{ type: 'google_search' }], previous_interaction_id: 'interaction_1' } });
  });

  it('uses the builtin Moonshot loop bound authored by the selected runtime recipe', async () => {
    const boundedRecipes = {
      ...recipes,
      'moonshot.chat.web.v1': { ...(recipes['moonshot.chat.web.v1'] as any), maxToolLoops: 2 },
    };
    const request = await buildProviderRequest({ providerKind: 'moonshot', apiKey: 'key', modelID: 'kimi-bounded', messages: [{ role: 'user', content: 'news' }], options: { supportsWebSearch: true } }, async () => metadataWithRecipes('moonshot', 'kimi-bounded', 'openai_chat', 'moonshot.chat.web.v1', boundedRecipes));
    expect(request).toMatchObject({ responseAdapter: 'moonshot_tool_loop', moonshotMaxToolLoops: 2 });
  });

  it('applies an accepted lossless custom fragment through the production builder with a redacted preview', async () => {
    const request = await buildProviderRequest({ providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-any', messages: [{ role: 'user', content: 'news' }], options: { customFragment: { raw: '{"max_output_tokens":256}' } } }, async () => metadataWithCustomControls('openAI', 'gpt-any', 'openai_chat', { generation: { recipeRef: 'openai.chat.generation.v1', refs: ['openai.generation.max_output_tokens'] } }, { 'openai.generation.max_output_tokens': customControlDefinitions['openai.generation.max_output_tokens'] }));
    expect(request.body.max_output_tokens).toBe(256);
    expect(request.capabilityExecution).toMatchObject({ recipeRefs: [], delta: { max_output_tokens: 256 }, redactedPreview: { max_output_tokens: 256 } });
  });

  it('does not accept caller-declared owners and rejects a custom path that overlaps a recipe-owned parent', async () => {
    await expect(buildProviderRequest({
      providerKind: 'gemini', apiKey: 'key', modelID: 'gemini-conflict', messages: [{ role: 'user', content: 'news' }],
      options: { reasoning: 'balanced', generationParameters: { temperature: { state: 'value', value: 0.1 } }, customFragment: { raw: '{"generationConfig":{"thinkingConfig":{"thinkingLevel":"attacker"}}}', owner: 'reasoning', declaredOwners: { '/generationConfig/thinkingConfig/thinkingLevel': 'reasoning' } } as any },
    }, async () => metadataWithControls('gemini', 'gemini-conflict', 'gemini_generate_content', {
      generation: 'gemini.generate_content.generation.v1', reasoning: 'gemini.generate_content.reasoning.v2',
    }))).rejects.toThrow('Safe custom fragment rejected: conflict');
  });

  it('selects Custom instead of typed/recipe for the same owner and keeps a sibling owner automatic', async () => {
    const shared = metadataWithCustomControls('openAI', 'gpt-custom', 'openai_responses', { generation: { recipeRef: 'openai.responses.generation.v1', refs: ['openai.generation.max_output_tokens'] }, reasoning: { recipeRef: 'openai.responses.reasoning.v1', refs: ['openai.reasoning.effort'] } }, customControlDefinitions);
    const generationCustom = await buildProviderRequest({ providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-custom', messages: [{ role: 'user', content: 'news' }], options: { reasoning: 'balanced', generationParameters: { temperature: { state: 'value', value: 0.1 } }, customFragments: { generation: { raw: '{"max_output_tokens":256}' } } } }, async () => shared);
    expect(generationCustom.body).toMatchObject({ max_output_tokens: 256, reasoning: { effort: 'medium' } });
    expect(generationCustom.capabilityExecution?.recipeRefs).toEqual(['openai.responses.reasoning.v1']);
  });

  it('allows multiple owners to select Custom together without deriving writable paths from recipes', async () => {
    const shared = metadataWithCustomControls('openAI', 'gpt-multi-custom', 'openai_responses', {
      reasoning: { recipeRef: 'openai.responses.reasoning.v1', refs: ['openai.reasoning.effort'] },
      generation: { recipeRef: 'openai.responses.generation.v1', refs: ['openai.generation.max_output_tokens'] },
    }, customControlDefinitions);
    const request = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-multi-custom', messages: [{ role: 'user', content: 'why' }],
      options: {
        reasoning: 'deep',
        generationParameters: { temperature: { state: 'value', value: 0.8 } },
        customFragments: {
          reasoning: { raw: '{"reasoning":{"effort":"low"}}' },
          generation: { raw: '{"max_output_tokens":384}' },
        },
      },
    }, async () => shared);
    expect(request.body).toMatchObject({ reasoning: { effort: 'low' }, max_output_tokens: 384 });
    expect(request.body.temperature).toBeUndefined();
    expect(request.capabilityExecution?.recipeRefs).toEqual([]);
  });

  it('enforces Auto/Custom mutual exclusion independently for web, reasoning and generation production bodies', async () => {
    const webCustom = await buildProviderRequest({
      providerKind: 'qwen', apiKey: 'key', modelID: 'qwen-custom-web', messages: [{ role: 'user', content: 'news' }],
      options: { capabilityPreferences: { web: 'automatic' }, customFragments: { web: { raw: '{"enable_search":false}' } } },
    }, async () => metadataWithCustomControls('qwen', 'qwen-custom-web', 'openai_chat', { web: { recipeRef: 'qwen.chat.web.v1', refs: ['qwen.web.enable_search'] } }, { 'qwen.web.enable_search': customControlDefinitions['qwen.web.enable_search'] }));
    expect(webCustom.body.enable_search).toBe(false);
    expect(webCustom.capabilityExecution?.recipeRefs).toEqual([]);

    const reasoningCustom = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-custom-reasoning', messages: [{ role: 'user', content: 'why' }],
      options: { capabilityPreferences: { web: 'off', reasoningIntent: 'deep' }, customFragments: { reasoning: { raw: '{"reasoning":{"effort":"low"}}' } } },
    }, async () => metadataWithCustomControls('openAI', 'gpt-custom-reasoning', 'openai_responses', { reasoning: { recipeRef: 'openai.responses.reasoning.v1', refs: ['openai.reasoning.effort'] } }, { 'openai.reasoning.effort': customControlDefinitions['openai.reasoning.effort'] }));
    expect(reasoningCustom.body).toMatchObject({ reasoning: { effort: 'low' } });
    expect(reasoningCustom.capabilityExecution?.recipeRefs).toEqual([]);

    const generationCustom = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-custom-generation', messages: [{ role: 'user', content: 'write' }],
      options: { generationParameters: { temperature: { state: 'value', value: 0.9 } }, customFragments: { generation: { raw: '{"max_output_tokens":256}' } } },
    }, async () => metadataWithCustomControls('openAI', 'gpt-custom-generation', 'openai_chat', { generation: { recipeRef: 'openai.chat.generation.v1', refs: ['openai.generation.max_output_tokens'] } }, { 'openai.generation.max_output_tokens': customControlDefinitions['openai.generation.max_output_tokens'] }));
    expect(generationCustom.body.max_output_tokens).toBe(256);
    expect(generationCustom.body.temperature).toBeUndefined();
    expect(generationCustom.capabilityExecution?.recipeRefs).toEqual([]);
  });

  it('a valid generation control suppresses a mismatched legacy template rather than emitting it', async () => {
    const runtime = metadata('openAI', 'mismatch', 'openai_chat', 'openai.chat.generation.v1');
    runtime.providers.openAI.models.mismatch.profiles.generation.template = 'wrong_template';
    runtime.profiles.generation.templates.wrong_template = { wire: { temperature: 'temperature' } };
    const request = await buildProviderRequest({ providerKind: 'openAI', apiKey: 'key', modelID: 'mismatch', messages: [{ role: 'user', content: 'plain' }], options: { generationParameters: { temperature: { state: 'value', value: 0.7 } } } }, async () => runtime);
    expect(request.capabilityExecution?.recipeRefs).toEqual(['openai.chat.generation.v1']);
    expect(request.body.temperature).toBeUndefined();
    expect(request.capabilityExecution?.delta).toEqual({});
  });

  it('keeps opaque continuation replay on the production wire but out of the delta preview', async () => {
    const opaque = '----MOONSHOT ENCRYPTED BEGIN----opaque----MOONSHOT ENCRYPTED END----';
    const request = await buildProviderRequest({
      providerKind: 'moonshot', apiKey: 'key', modelID: 'kimi-k3',
      messages: [{ role: 'user', content: 'news' }], options: { supportsWebSearch: true },
      continuation: { kind: 'tool_loop', variant: 'fiber', step: 1, state: { completedMessages: [{ role: 'assistant', content: '', tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'web_search', arguments: '{"q":"news"}' } }] }, { role: 'tool', tool_call_id: 'call_1', name: 'web_search', content: opaque }] } },
    }, async () => metadata('moonshot', 'kimi-k3', 'openai_chat', 'moonshot.formula.web.v1'));
    expect(JSON.stringify(request.body)).toContain(opaque);
    expect(request.capabilityExecution?.redactedPreview).toEqual({ messages: '<redacted continuation>' });
    expect(JSON.stringify(request.capabilityExecution?.redactedPreview)).not.toContain(opaque);
  });

  it('inserts protocol replay before the final explicit-continue user input', async () => {
    const anthropic = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'key', modelID: 'claude-fixture',
      messages: [{ role: 'user', content: '[Continue from where you left off]' }],
      options: { reasoning: 'balanced' },
      continuation: { kind: 'replay_blocks', step: 1, state: { blocks: [{ type: 'thinking', thinking: 'opaque', signature: 'sig' }] } },
    }, async () => metadata('anthropic', 'claude-fixture', 'anthropic_messages', 'anthropic.messages.reasoning.v1'));
    expect((anthropic.body.messages as Array<{ role: string }>).map((message) => message.role)).toEqual(['assistant', 'user']);

    const gemini = await buildProviderRequest({
      providerKind: 'gemini', apiKey: 'key', modelID: 'gemini-fixture',
      messages: [{ role: 'user', content: '[Continue from where you left off]' }],
      options: { reasoning: 'balanced' },
      continuation: { kind: 'replay_blocks', step: 1, state: { blocks: [{ role: 'model', parts: [{ thoughtSignature: 'opaque', text: 'thought' }] }] } },
    }, async () => metadata('gemini', 'gemini-fixture', 'gemini_generate_content', 'gemini.generate_content.reasoning.v2'));
    expect((gemini.body.contents as Array<{ role: string }>).map((content) => content.role)).toEqual(['model', 'user']);
  });

  for (const item of fixture.continuationCases) {
    it(item.caseId, () => {
      if (!('expectedWire' in item)) {
        expect(item.resumeAutomatically).toBe(false);
        expect(item.expectedPersisted.interrupted).toBe(true);
        return;
      }
      const intent = item.state == null || typeof item.state !== 'object' ? null : { kind: item.kind, variant: item.variant, step: item.step, state: item.state };
      const mapped = mapContinuationForRecipe({ id: 'fixture', providerKind: 'fixture', capability: 'web', executionKind: 'request_overlay', requestOps: [], continuationKind: item.kind, ...(item.variant ? { continuationVariant: item.variant } : {}), ...(item.targetResponseParserKind ? { responseParserKind: item.targetResponseParserKind } : {}), transport: { protocol: item.targetProtocol } }, intent);
      if (item.state == null || typeof item.state !== 'object') {
        expect(mapped).toEqual({ accepted: false, reason: 'invalid_continuation' });
      } else if (Object.hasOwn(item.expectedWire, 'bodyDelta')) {
        expect(mapped).toEqual({ accepted: true, target: 'body', delta: item.expectedWire.bodyDelta });
      } else if (Object.hasOwn(item.expectedWire, 'messageAppend')) {
        expect(mapped).toEqual({ accepted: true, target: 'message_append', messages: item.expectedWire.messageAppend });
      } else if (Object.hasOwn(item.expectedWire, 'contentsAppend')) {
        expect(mapped).toEqual({ accepted: true, target: 'contents_append', contents: item.expectedWire.contentsAppend });
      } else expect(mapped).toEqual({ accepted: true, target: 'body', delta: {} });
    });
  }

  for (const item of fixture.safeCustomCases) {
    it(item.caseId, () => {
      const raw = item.raw ?? (item.generatedDepth ? `${'{"nested":'.repeat(item.generatedDepth)}0${'}'.repeat(item.generatedDepth)}` : item.generatedNodes ? `{${Array.from({ length: item.generatedNodes }, (_, index) => `"k${index}":${index}`).join(',')}}` : `{"payload":"${'x'.repeat(item.generatedUtf8Bytes ?? 1)}"}`);
      const owners = item.controlRefs ? Object.fromEntries(item.controlRefs.map((ref: string) => {
        const control = customControlDefinitions[ref];
        return [control?.targetPointer ?? '', control?.owner ?? 'generation'];
      })) : item.declaredOwners ?? {};
      const result = compileSafeCustomFragment(raw, item.owner ?? 'generation', owners, {});
      if (item.expectedDelta) expect(result).toMatchObject({ accepted: true, delta: item.expectedDelta, preview: item.expectedDelta });
      else expect(result).toMatchObject({ accepted: false, reason: item.expectReason === 'unknown_path' ? 'unknown_owned_path' : item.expectReason });
    });
  }

  it('enforces the safe-fragment depth boundary before recursion overflows and rejects nested dangerous keys', () => {
    expect(compileSafeCustomFragment(nested(32), 'generation', { [nestedPointer(32)]: 'generation' }, {})).toMatchObject({ accepted: true });
    expect(compileSafeCustomFragment(nested(33), 'generation', { '/a': 'generation' }, {})).toEqual({ accepted: false, reason: 'depth_exceeded' });
    expect(compileSafeCustomFragment('{"temperature":{"__proto__":{"x":1}}}', 'generation', { '/temperature': 'generation' }, {})).toEqual({ accepted: false, reason: 'forbidden_key' });
    expect(compileSafeCustomFragment('{"temperature":0.2}', 'generation', {}, {})).toEqual({ accepted: false, reason: 'unknown_owned_path' });
  });

  /**
   * The compiler's rejection reason must be forwarded as-is rather than collapsed into a
   * single `invalid_fragment`.
   *
   * These two cases run the real `compileSafeCustomFragment` production path instead of
   * feeding a hand-written reason string to the classifier. Collapsed into one name, the
   * editor reports both "this pointer is not writable" and "operand limit exceeded" as a
   * syntax error, and the user keeps re-checking perfectly valid JSON.
   */
  it('forwards the compiler rejection reason instead of collapsing it into invalid_fragment', () => {
    // Pointer segments must match `^[A-Za-z_][A-Za-z0-9_]*$`: a hyphenated key fails rfc6901 hardening.
    expect(compileSafeCustomFragment('{"my-key":1}', 'generation', { '/my-key': 'generation' }, {}))
      .toEqual({ accepted: false, reason: 'invalid_pointer' });

    // The operand limit is 128, so 129 leaf nodes is a quota problem, not a syntax problem.
    const wide = `{${Array.from({ length: 129 }, (_, index) => `"k${index}":${index}`).join(',')}}`;
    const owners = Object.fromEntries(Array.from({ length: 129 }, (_, index) => [`/k${index}`, 'generation' as const]));
    expect(compileSafeCustomFragment(wide, 'generation', owners, {}))
      .toEqual({ accepted: false, reason: 'operation_limit_exceeded' });

    // `invalid_fragment` stays reserved for a genuinely wrong shape: a root that is not an object.
    expect(compileSafeCustomFragment('[1,2,3]', 'generation', {}, {}))
      .toEqual({ accepted: false, reason: 'invalid_fragment' });
  });

  it('fetches declared Formula tools and sends Fiber arguments verbatim', async () => {
    const formula = (recipes['moonshot.formula.web.v1'] as any).formula;
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const toolCall = fixture.executionCases.find((item) => item.caseId === 'moonshot_formula_fiber_verbatim').formula.toolCalls[0];
    const transport: UpstreamTransport = { fetch: async (url, init) => {
      calls.push({ url, init });
      if (url.endsWith('/tools')) return json({ tools: fixture.executionCases.find((item) => item.caseId === 'moonshot_formula_fiber_verbatim').formula.toolsResponse.tools });
      if (url.endsWith('/fibers')) return json(fixture.executionCases.find((item) => item.caseId === 'moonshot_formula_fiber_verbatim').formula.fiberResponses[0]);
      return sse([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]);
    } };
    const request: ProviderRequest = { url: 'https://api.moonshot.cn/v1/chat/completions', headers: { Authorization: 'Bearer key' }, body: { model: 'kimi-k3', messages: [{ role: 'user', content: 'news' }] }, moonshotFormula: formula, moonshotMaxToolLoops: 1 };
    const prepared = await prepareMoonshotFormulaRequest(request, transport);
    expect(prepared.body.tools).toEqual(fixture.executionCases.find((item) => item.caseId === 'moonshot_formula_fiber_verbatim').formula.toolsResponse.tools);
    const response = await adaptMoonshotFormulaFiberResponse(await sse([{ choices: [{ delta: { tool_calls: [toolCall] } }] }]), prepared, transport);
    const replay = await response.text();
    expect(replay).toContain('Moonshot Formula tool loop limit reached before completion');
    expect(replay).toContain('"type":"continuation"');
    expect(replay).toContain('"completedMessages"');
    expect(replay).toContain('"tool_calls"');
    expect(replay).toContain('"content":"----MOONSHOT ENCRYPTED BEGIN----opaque----MOONSHOT ENCRYPTED END----"');
    const continuation = replay.split('\n').flatMap((line) => {
      if (!line.startsWith('data: ')) return [];
      try { const payload = JSON.parse(line.slice(6)); return payload.type === 'continuation' ? [payload.continuation] : []; } catch { return []; }
    })[0];
    expect(continuation).toEqual({
      kind: 'tool_loop', variant: 'fiber', step: 1,
      state: { completedMessages: [
        { role: 'assistant', content: '', tool_calls: [toolCall] },
        { role: 'tool', tool_call_id: 'web_search:0', name: 'web_search', content: '----MOONSHOT ENCRYPTED BEGIN----opaque----MOONSHOT ENCRYPTED END----' },
      ] },
    });
    const fiber = calls.find((call) => call.url.endsWith('/fibers'))!;
    expect(fiber.url).toBe('https://api.moonshot.cn/v1/formulas/moonshot/web-search:latest/fibers');
    expect(fiber.init.body).toBe(JSON.stringify({ name: 'web_search', arguments: '{"query":"latest"}' }));
  });

  it('appends Formula declarations after builder-owned library tools and rejects duplicate names', async () => {
    const formula = (recipes['moonshot.formula.web.v1'] as any).formula;
    const libraryTool = { type: 'function', function: { name: 'library_lookup', parameters: { type: 'object' } } };
    const transport: UpstreamTransport = { fetch: async () => json({ tools: [{ type: 'function', function: { name: 'web_search', parameters: { type: 'object' } } }] }) };
    const request: ProviderRequest = {
      url: 'https://api.moonshot.cn/v1/chat/completions', headers: { Authorization: 'Bearer key' },
      body: { model: 'kimi-k3', messages: [{ role: 'user', content: 'news' }], tools: [libraryTool] }, moonshotFormula: formula,
    };
    await expect(prepareMoonshotFormulaRequest(request, transport)).resolves.toMatchObject({ body: { tools: [libraryTool, { type: 'function', function: { name: 'web_search' } }] } });
    const duplicate: UpstreamTransport = { fetch: async () => json({ tools: [libraryTool] }) };
    await expect(prepareMoonshotFormulaRequest(request, duplicate)).rejects.toThrow('duplicate tool name: library_lookup');
  });

  it('keeps a compatible custom Moonshot API-root prefix for Formula requests', async () => {
    const formula = (recipes['moonshot.formula.web.v1'] as any).formula;
    const calls: string[] = [];
    const transport: UpstreamTransport = { fetch: async (url) => {
      calls.push(url);
      return json({ tools: [{ type: 'function', function: { name: 'web_search', parameters: { type: 'object' } } }] });
    } };
    await prepareMoonshotFormulaRequest({
      url: 'https://proxy.example/moonshot/v1/chat/completions', headers: { Authorization: 'Bearer key' },
      body: { model: 'kimi-k3', messages: [] }, moonshotFormula: formula,
    }, transport);
    expect(calls).toEqual(['https://proxy.example/moonshot/v1/formulas/moonshot/web-search:latest/tools']);
  });
});

describe('typed capability intent reaches production builders', () => {
  it('compiles force web and explicit reasoning off from typed preferences', async () => {
    const activeRecipes = {
      force_web: { id: 'force_web', providerKind: 'openAI', transport: { protocol: 'openai_chat_completions' }, capability: 'web', executionKind: 'request_overlay', requestOps: [{ op: 'set', pointer: '/web_mode', value: 'force', intent: 'force' }] },
      off_reasoning: { id: 'off_reasoning', providerKind: 'openAI', transport: { protocol: 'openai_chat_completions' }, capability: 'reasoning', executionKind: 'request_overlay', requestOps: [{ op: 'set', pointer: '/reasoning_effort', value: 'off', intent: 'off' }] },
    };
    const runtime = metadataWithControls('openAI', 'gpt-test', 'openai_chat_completions', { web: 'force_web', reasoning: 'off_reasoning' });
    runtime.capabilityRuntime.recipes = activeRecipes;
    // These two recipes are built by this case and are not in the registry, so
    // metadataWithControls has no intent surface for them and it is supplied explicitly
    // here: the reverse gate requires selectedIntent to appear in the availableIntents
    // sent by the server.
    runtime.providers.openAI.models['gpt-test'].capabilityControls.web.availableIntents = ['force'];
    runtime.providers.openAI.models['gpt-test'].capabilityControls.reasoning.availableIntents = ['off'];
    const request = await buildProviderRequest({ providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-test', messages: [{ role: 'user', content: 'hi' }], options: { capabilityPreferences: { web: 'force', reasoningIntent: 'off' } } }, async () => runtime);
    expect(request.body).toMatchObject({ web_mode: 'force', reasoning_effort: 'off' });
    expect(request.capabilityExecution?.recipeRefs).toEqual(['force_web', 'off_reasoning']);
  });

  it('does not invent a runtime delta when runtime metadata misses', async () => {
    const request = await buildProviderRequest({ providerKind: 'openAI', apiKey: 'key', modelID: 'gpt-test', messages: [{ role: 'user', content: 'hi' }], options: { capabilityPreferences: { web: 'force', reasoningIntent: 'off' } } }, async () => plainMetadata('openAI', 'gpt-test', 'openai_chat_completions'));
    expect(request.capabilityExecution).toBeUndefined();
    expect(JSON.stringify(request.body)).not.toMatch(/web_mode|reasoning_effort/);
  });
});

describe('developer custom preview', () => {
  it('uses the same recipe-owned schema as the production compiler', () => {
    const result = previewSafeCustomFragment({
      raw: '{"temperature":0.2}',
      generationProfile: { template: 'openai_chat_completions', wire: { temperature: 'temperature' }, parameters: [] },
      recipes: [{ id: 'generation_owner', providerKind: 'openAI', capability: 'generation', executionKind: 'request_overlay', requestOps: [{ op: 'set', pointer: '/temperature', value: 1 }] }],
      intents: {},
    });
    expect(result).toEqual({ accepted: false, reason: 'conflict' });
  });
});

function json(value: unknown) { return new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } }); }
async function sse(chunks: unknown[]) { return new Response(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\ndata: [DONE]\n\n`).join(''), { headers: { 'Content-Type': 'text/event-stream' } }); }
function root(relative: string) { let current = process.cwd(); while (true) { const candidate = path.join(current, relative); if (existsSync(candidate)) return candidate; const next = path.dirname(current); if (next === current) throw new Error(relative); current = next; } }
// The compiler has a reverse gate: selectedIntent must also appear in the availableIntents
// sent by the server, otherwise nothing goes out (a hidden step carried over by a
// cross-model preference produces a request that is guaranteed to 400). This fixture only
// carried state and recipeRef, so once the gate landed every reasoning recipe case lost its
// capabilityExecution - not a production break, but a fixture that had not caught up with
// the tightened contract.
// The set is filled in from the intents each recipe declares, matching the shape the server
// sends: if there is a ladder, availableIntents comes with it. Recipes with no intent ops
// stay unset, since a single-value model has no ladder.
// The order must be canonical (off < low < balanced < deep < max) rather than the order
// requestOps happens to be written in: validateIntents on the server requires
// availableIntents to increase monotonically, and at least moonshot.chat.reasoning.v1
// orders its ops off, balanced, low in the registry. Copying that order is rejected and
// shows up as "this recipe never compiles".
const CANONICAL_INTENTS = ['off', 'low', 'balanced', 'deep', 'max'] as const;

function availableIntentsFor(recipe: any): string[] {
  const intents = new Set<string>((recipe?.requestOps ?? [])
    .map((op: any) => op?.intent)
    .filter((intent: unknown): intent is string => typeof intent === 'string' && intent !== 'force'));
  return CANONICAL_INTENTS.filter((intent) => intents.has(intent));
}

function metadata(providerKind: string, modelID: string, transport: string, recipeRef: string): any {
  const recipe = recipes[recipeRef] as any;
  const capability = recipe?.capability ?? 'web';
  const template = recipe?.requestOps?.[0]?.op === 'legacy_generation_template' ? recipe.requestOps[0].template : undefined;
  const wire = template === 'gemini_generate_content' ? 'generationConfig.temperature' : 'temperature';
  const intents = availableIntentsFor(recipe);
  const control: Record<string, unknown> = { state: 'auto_available', recipeRef };
  if (intents.length > 0) control.availableIntents = intents;
  return {
    version: 2, updatedAt: '2026-08-11T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: template ? { templates: { [template]: { wire: { temperature: wire } } }, parameters: { temperature: {} } } : undefined },
    capabilityRuntime: { schemaVersion: 2, revision: 'fixture', generatedAt: '2026-08-11T00:00:00Z', recipes, controlDefinitions: {}, sourceIndex: {} },
    providers: { [providerKind]: { resolveMap: { [modelID]: modelID }, models: { [modelID]: { transport, capabilityControls: { [capability]: control }, ...(template ? { profiles: { generation: { template, parameters: [{ id: 'temperature', support: 'supported', source: 'provider' }] } } } : {}) } } } },
  };
}
function metadataWithRecipes(providerKind: string, modelID: string, transport: string, recipeRef: string, activeRecipes: Record<string, unknown>): any {
  const out = metadata(providerKind, modelID, transport, recipeRef);
  out.capabilityRuntime.recipes = activeRecipes;
  return out;
}
function metadataWithControls(providerKind: string, modelID: string, transport: string, controls: Record<string, string>): any {
  const first = Object.values(controls)[0]!;
  const out = metadata(providerKind, modelID, transport, first);
  out.providers[providerKind].models[modelID].capabilityControls = Object.fromEntries(Object.entries(controls).map(([capability, recipeRef]) => {
    const intents = availableIntentsFor(recipes[recipeRef]);
    return [capability, { state: 'auto_available', recipeRef, ...(intents.length > 0 ? { availableIntents: intents } : {}) }];
  }));
  return out;
}
function metadataWithCustomControls(
  providerKind: string,
  modelID: string,
  transport: string,
  controls: Record<string, { recipeRef: string; refs: string[] }>,
  definitions: Record<string, any>,
): any {
  const first = Object.values(controls)[0]!.recipeRef;
  const out = metadata(providerKind, modelID, transport, first);
  out.capabilityRuntime.controlDefinitions = definitions;
  out.capabilityRuntime.sourceIndex = Object.fromEntries(Object.values(definitions)
    .flatMap((definition: any) => definition?.sourceRefs ?? [])
    .map((ref: string) => [ref, { kind: 'official_doc', url: 'https://example.invalid/fixture', reviewedAt: '2026-08-11', officialUpdatedAt: null }]));
  out.providers[providerKind].models[modelID].capabilityControls = Object.fromEntries(Object.entries(controls)
    .map(([capability, control]) => {
      const intents = availableIntentsFor(recipes[control.recipeRef]);
      return [capability, {
        state: 'auto_available', recipeRef: control.recipeRef, customControlRefs: control.refs,
        ...(intents.length > 0 ? { availableIntents: intents } : {}),
      }];
    }));
  return out;
}
function nested(depth: number) { return `${'{"a":'.repeat(depth)}0${'}'.repeat(depth)}`; }
function nestedPointer(depth: number) { return `/${Array.from({ length: depth }, () => 'a').join('/')}`; }
function normalizedEvents(value: unknown): any[] { return value == null ? [] : Array.isArray(value) ? value : [value]; }
function plainMetadata(providerKind: string, modelID: string, transport: string): any { return { version: 2, updatedAt: '2026-08-11T00:00:00Z', profiles: { reasoning: {}, webSearch: {}, imageGen: {} }, providers: { [providerKind]: { resolveMap: { [modelID]: modelID }, models: { [modelID]: { transport } } } } }; }
function requestForRecipe(recipe: any, modelID: string): any { const intents = new Set((recipe.requestOps ?? []).map((op: any) => op.intent)); const reasoning = intents.has('deep') ? 'deep' : intents.has('balanced') ? 'balanced' : intents.has('low') ? 'fast' : 'off'; return { providerKind: recipe.providerKind, apiKey: 'key', modelID, messages: [{ role: 'user', content: 'plain chat' }], options: recipe.capability === 'web' ? { supportsWebSearch: true } : recipe.capability === 'generation' ? { generationParameters: { temperature: { state: 'value', value: 0.2 } } } : { reasoning } }; }
function customTemperatureRaw(recipeRef: string): string { return (recipes[recipeRef] as any)?.requestOps?.[0]?.template === 'gemini_generate_content' ? '{"generationConfig":{"temperature":0.2}}' : '{"temperature":0.2}'; }
function providerResponseSample(transport: string, stream: boolean): { eventType: string | null; payload: unknown } {
  if (transport === 'openai_responses') return stream
    ? { eventType: 'response.output_text.delta', payload: { delta: 'fixture response' } }
    : { eventType: null, payload: { id: 'resp_fixture', status: 'completed', output: [{ type: 'message', content: [{ type: 'output_text', text: 'fixture response' }] }] } };
  if (transport === 'anthropic_messages') return stream
    ? { eventType: 'content_block_delta', payload: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'fixture response' } } }
    : { eventType: null, payload: { type: 'message', content: [{ type: 'text', text: 'fixture response' }] } };
  if (transport === 'gemini_generate_content') return { eventType: null, payload: { candidates: [{ content: { role: 'model', parts: [{ text: 'fixture response' }] }, finishReason: 'STOP' }] } };
  return stream
    ? { eventType: null, payload: { choices: [{ delta: { content: 'fixture response' } }] } }
    : { eventType: null, payload: { choices: [{ message: { content: 'fixture response' }, finish_reason: 'stop' }] } };
}
