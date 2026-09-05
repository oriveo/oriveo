import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { resolveLayers } from '@oriveo/core/providers/request-preference/preference-resolution';
import type { ScopeId } from '@oriveo/core/providers/request-preference/types';
import type { StreamEvent } from '../providers/types';
import { capabilityRecoveryHeaders } from '../../../app/api/chat/stream/capability-recovery-response';
import {
  CAPABILITY_RECOVERY_HEADER,
  decodeCapabilityRecoveryDescriptor,
} from './capability-recovery-runtime';
import { buildCapabilityResultContext, collectCapabilityResults, requestedCapabilityResults } from './capability-result-runtime';

type Owner = 'web' | 'reasoning' | 'generation';
type RuntimeIdentity = {
  connectionId: string;
  canonicalModelId: string;
  finalTransport: string;
  runtimeRevision: string;
};
type LayerValue = string | Record<string, unknown> | null;
type RuntimeFixture = {
  scopePriority: ScopeId[];
  resolutionCases: Array<{
    caseId: string;
    layers: Record<ScopeId, Partial<Record<Owner, LayerValue>> | null>;
    expected: Record<Owner, unknown>;
  }>;
  finalBodyCases: Array<{
    caseId: string;
    identity: RuntimeIdentity;
    expectedFinalBody: Record<string, unknown>;
    expectedDispatch: {
      requestedOwners?: string[];
      generationExecutionFact?: boolean;
      chatContinues?: boolean;
      legacyFallbackUsed?: boolean;
    };
  }>;
  rejectionCases: Array<Record<string, unknown>>;
  resultFactCases: Array<{ caseId: string; expected: string }>;
};

const fixture = JSON.parse(readFileSync(repoFile('shared/model-contracts/model_control_runtime.v1.json'), 'utf8')) as RuntimeFixture;
const officialRecipes = (JSON.parse(readFileSync(repoFile('shared/capabilityrecipe/capability_runtime.v1.json'), 'utf8')) as {
  recipes: Record<string, unknown>;
}).recipes;

describe('shared model-control runtime fixture through web production paths', () => {
  it('resolves the shared seven-scope case owner-by-owner through the production resolver', () => {
    const runtimeCase = fixture.resolutionCases.find((item) => item.caseId === 'seven_scopes_resolve_each_owner_independently')!;
    expect(fixture.scopePriority).toEqual([
      'single_send', 'conversation_connection_model', 'skill_agent', 'connection_model',
      'connection', 'provider_recipe', 'provider_default',
    ]);

    expect(resolveOwner(runtimeCase, 'web')).toBe(runtimeCase.expected.web);
    expect(resolveOwner(runtimeCase, 'reasoning')).toBe(runtimeCase.expected.reasoning);

    const generationExpected = runtimeCase.expected.generation as Record<string, unknown>;
    const generation = Object.fromEntries(Object.keys(generationExpected).map((key) => [
      key,
      resolveGenerationKey(runtimeCase, key),
    ]));
    expect(generation).toEqual(generationExpected);
  });

  it('keeps the shared unknown/kill case as a valid plain body through the real production builder', async () => {
    const runtimeCase = fixture.finalBodyCases.find((item) => item.caseId === 'unknown_or_killed_runtime_plain_chat_remains_valid')!;
    const request = await buildProviderRequest({
      providerKind: 'openAI',
      apiKey: 'fixture-key',
      modelID: runtimeCase.identity.canonicalModelId,
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        supportsWebSearch: true,
        reasoning: 'deep',
        capabilityPreferences: { web: 'force', reasoningIntent: 'deep' },
        generationParameters: { temperature: { state: 'value', value: 0.2 } },
      },
    }, async () => unknownRuntimeMetadata(runtimeCase.identity));

    expect(request.body).toEqual(runtimeCase.expectedFinalBody);
    expect(request.capabilityExecution).toBeUndefined();
    expect(request.url).toMatch(/\/responses$/);
    expect(runtimeCase.expectedDispatch).toMatchObject({ chatContinues: true, legacyFallbackUsed: false });
  });

  it('matches the shared exact-all-owners final body and dispatch latch through the real production builder', async () => {
    const runtimeCase = fixture.finalBodyCases.find((item) => item.caseId === 'exact_recipe_all_owners')!;
    const request = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'fixture-key', modelID: runtimeCase.identity.canonicalModelId,
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        supportsWebSearch: true,
        capabilityPreferences: { web: 'automatic', reasoningIntent: 'deep' },
        generationParameters: { temperature: { state: 'value', value: 0.2 } },
      },
    }, async () => exactAllOwnerMetadata(runtimeCase.identity));

    expect(request.body).toEqual(runtimeCase.expectedFinalBody);
    const context = buildCapabilityResultContext(request.capabilityExecution, request.capabilityExecution?.resultEnvelope);
    expect(requestedCapabilityResults(context).map((result) => result.owner)).toEqual(
      runtimeCase.expectedDispatch.requestedOwners,
    );
    expect(context?.entries.some((entry) => entry.owner === 'generation')).toBe(
      runtimeCase.expectedDispatch.generationExecutionFact,
    );
  });

  it('derives an explicit recipe resend header from the real builder object and observes only a production parser signal', async () => {
    const rejection = fixture.rejectionCases.find((item) => item.caseId === 'structured_exact_recipe_locator_offers_explicit_resend') as {
      recipe: Record<string, unknown>;
      errorRecoveryDefinition: Record<string, unknown>;
      error: unknown;
      expected: Record<string, unknown>;
    };
    const resultFact = fixture.resultFactCases.find((item) => item.caseId === 'nonempty_citation_from_production_parser_is_observed')!;
    const recipeRef = rejection.recipe.recipeRef as string;
    const recoveryRef = rejection.recipe.errorRecoveryRef as string;
    const recipe = {
      id: recipeRef,
      providerKind: 'openAI',
      executionKind: 'request_overlay',
      transport: { protocol: rejection.recipe.protocol },
      capability: rejection.recipe.capability,
      responseParserKind: rejection.recipe.responseParserKind,
      responseEvidenceRef: 'fixture.exact.web.evidence',
      errorRecoveryRef: recoveryRef,
      requestOps: rejection.recipe.requestOps,
    };
    const runtime = exactRuntimeMetadata(recipe, recoveryRef, rejection.errorRecoveryDefinition);
    const request = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'fixture-key', modelID: 'fixture-exact-model',
      messages: [{ role: 'user', content: 'hello' }],
      options: { supportsWebSearch: true, capabilityPreferences: { web: 'automatic' } },
    }, async () => runtime);

    expect(request.body.web_search_options).toEqual({ enabled: true });
    expect(request.body.include).toEqual(['web_search_call.action.sources']);
    const headers = capabilityRecoveryHeaders(request, 400, JSON.stringify(rejection.error));
    const descriptor = decodeCapabilityRecoveryDescriptor(headers[CAPABILITY_RECOVERY_HEADER] ?? null);
    expect(descriptor).toMatchObject({
      action: rejection.expected.action,
      source: 'provider_recipe',
      owners: ['web'],
      recipeRef,
    });

    const resend = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'fixture-key', modelID: 'fixture-exact-model',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        supportsWebSearch: true,
        capabilityPreferences: { web: 'automatic' },
        capabilityRecipeOmissions: [{ recipeRef, locatedPointers: descriptor!.locatedPointers }],
      },
    }, async () => runtime);
    expect(resend.body.web_search_options).toBeUndefined();
    expect(resend.body.include).toEqual(['web_search_call.action.sources']);
    expect(rejection.expected).toMatchObject({
      normalSendAutomaticFields: {},
      explicitResend: {
        oneRequestResendLatch: true,
        omittedPointers: ['/web_search_options'],
        preservedPointers: ['/include'],
      },
    });

    const parser = createProxyChunkParser('openAI');
    const parsed = parser('response.output_text.annotation.added', JSON.stringify({
      annotation: { type: 'url_citation', url: 'https://source.example', title: 'Source' },
    }));
    const events: StreamEvent[] = parsed == null ? [] : Array.isArray(parsed) ? parsed : [parsed];
    const context = buildCapabilityResultContext(request.capabilityExecution, request.capabilityExecution?.resultEnvelope);
    expect(collectCapabilityResults(context, events)[0]?.state).toBe(resultFact.expected);
  });

  it('locates one custom raw blob only from production compiler ownership plus structured param', async () => {
    const rejection = fixture.rejectionCases.find((item) => item.caseId === 'custom_exact_400_offers_explicit_resend') as {
      error: unknown;
      locatedPointers: string[];
      expected: Record<string, unknown>;
    };
    const request = await buildProviderRequest({
      providerKind: 'openAI', apiKey: 'fixture-key', modelID: 'fixture-custom-model',
      messages: [{ role: 'user', content: 'hello' }],
      options: { customFragments: { generation: { raw: '{"temperature":0.2}' } } },
    }, async () => customRuntimeMetadata());

    expect(request.capabilityExecution?.customAppliedPointers).toEqual({ generation: rejection.locatedPointers });
    const headers = capabilityRecoveryHeaders(request, 400, JSON.stringify(rejection.error));
    expect(decodeCapabilityRecoveryDescriptor(headers[CAPABILITY_RECOVERY_HEADER] ?? null)).toMatchObject({
      source: 'custom', owners: ['generation'], locatedPointers: rejection.locatedPointers,
      action: rejection.expected.action,
    });
    expect(capabilityRecoveryHeaders(request, 400, JSON.stringify({ error: { param: 'model' } }))).toEqual({});
    expect(capabilityRecoveryHeaders(request, 400, 'not structured')).toEqual({});
  });
});

function resolveOwner(runtimeCase: RuntimeFixture['resolutionCases'][number], owner: Exclude<Owner, 'generation'>): unknown {
  const result = resolveLayers(fixture.scopePriority.map((scope) => ({
    scope,
    override: layerOverride(runtimeCase.layers[scope]?.[owner]),
  })));
  return result.state === 'value' ? result.value : undefined;
}

function resolveGenerationKey(runtimeCase: RuntimeFixture['resolutionCases'][number], key: string): unknown {
  const result = resolveLayers(fixture.scopePriority.map((scope) => {
    const generation = runtimeCase.layers[scope]?.generation;
    const value = generation && typeof generation === 'object' && !Array.isArray(generation)
      ? generation[key]
      : undefined;
    return { scope, override: value === undefined ? { state: 'inherit' as const } : { state: 'value' as const, value } };
  }));
  return result.state === 'value' ? result.value : undefined;
}

function layerOverride(value: LayerValue | undefined) {
  if (value == null || value === 'inherit') return { state: 'inherit' as const };
  return { state: 'value' as const, value };
}

function unknownRuntimeMetadata(identity: RuntimeIdentity) {
  return {
    version: 2,
    updatedAt: '2026-08-14T00:00:00Z',
    profiles: {
      reasoning: {
        legacy_reasoning: {
          levels: ['deep'],
          params: { deep: { reasoning: { effort: 'high' } } },
        },
      },
      webSearch: { legacy_web: { mergeParams: { tools: [{ type: 'web_search' }] } } },
      imageGen: {},
      generation: { templates: { legacy_generation: { wire: { temperature: 'temperature' } } }, parameters: { temperature: {} } },
    },
    capabilityRuntime: {
      schemaVersion: 2, revision: identity.runtimeRevision, generatedAt: '2026-08-14T00:00:00Z',
      recipes: {}, controlDefinitions: {}, sourceIndex: {},
    },
    providers: {
      openAI: {
        resolveMap: { [identity.canonicalModelId]: identity.canonicalModelId },
        models: {
          [identity.canonicalModelId]: {
            transport: identity.finalTransport,
            profiles: {
              reasoning: 'legacy_reasoning',
              webSearch: 'legacy_web',
              generation: {
                template: 'legacy_generation',
                parameters: [{ id: 'temperature', support: 'supported', source: 'provider' }],
              },
            },
            capabilityControls: {},
          },
        },
      },
    },
  };
}

function exactRuntimeMetadata(recipe: Record<string, unknown>, recoveryRef: string, recoveryDefinition: Record<string, unknown>) {
  const recipeRef = recipe.id as string;
  return {
    version: 2,
    updatedAt: '2026-08-14T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
    capabilityRuntime: {
      schemaVersion: 2, revision: 'runtime-r7', generatedAt: '2026-08-14T00:00:00Z',
      recipes: { [recipeRef]: recipe },
      controlDefinitions: {}, sourceIndex: {},
      errorRecoveryDefinitions: { [recoveryRef]: recoveryDefinition },
      responseEvidenceDefinitions: {
        'fixture.exact.web.evidence': {
          capability: 'web', protocol: 'openai_responses', responseParserKind: 'fixture_web_v1',
          signals: [{ kind: 'citation', producerEvent: 'citations', pointer: '/citations', nonEmpty: true }],
        },
      },
    },
    providers: {
      openAI: {
        resolveMap: { 'fixture-exact-model': 'fixture-exact-model' },
        models: {
          'fixture-exact-model': {
            transport: 'openai_responses',
            capabilityControls: { web: { state: 'auto_available', recipeRef } },
          },
        },
      },
    },
  };
}

function exactAllOwnerMetadata(identity: RuntimeIdentity) {
  const recipeRefs = ['openai.responses.web.v1', 'openai.responses.reasoning.v1', 'openai.responses.generation.v1'];
  const recipes = Object.fromEntries(recipeRefs.map((recipeRef) => [recipeRef, officialRecipes[recipeRef]]));
  return {
    version: 2,
    updatedAt: '2026-08-14T00:00:00Z',
    profiles: {
      reasoning: {}, webSearch: {}, imageGen: {},
      generation: {
        templates: { openai_responses: { wire: { temperature: 'temperature' } } },
        parameters: { temperature: {} },
      },
    },
    capabilityRuntime: {
      schemaVersion: 2, revision: identity.runtimeRevision, generatedAt: '2026-08-14T00:00:00Z',
      recipes, controlDefinitions: {}, sourceIndex: {}, responseEvidenceDefinitions: {},
    },
    providers: {
      openAI: {
        resolveMap: { [identity.canonicalModelId]: identity.canonicalModelId },
        models: {
          [identity.canonicalModelId]: {
            transport: identity.finalTransport,
            profiles: { generation: { template: 'openai_responses', parameters: [{ id: 'temperature', support: 'supported', source: 'provider' }] } },
            capabilityControls: {
              web: { state: 'auto_available', recipeRef: recipeRefs[0] },
              reasoning: { state: 'auto_available', recipeRef: recipeRefs[1], availableIntents: ['deep'] },
              generation: { state: 'auto_available', recipeRef: recipeRefs[2] },
            },
          },
        },
      },
    },
  };
}

function customRuntimeMetadata() {
  const recipeRef = 'openai.responses.generation.v1';
  return {
    version: 2,
    updatedAt: '2026-08-14T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
    capabilityRuntime: {
      schemaVersion: 2, revision: 'runtime-r7', generatedAt: '2026-08-14T00:00:00Z',
      recipes: { [recipeRef]: officialRecipes[recipeRef] },
      controlDefinitions: {
        'fixture.generation.temperature': {
          id: 'fixture.generation.temperature', owner: 'generation', targetPointer: '/temperature',
          sourceRefs: ['fixture.official'],
        },
      },
      sourceIndex: { 'fixture.official': { kind: 'official_doc', url: 'https://example.invalid', reviewedAt: '2026-08-14' } },
    },
    providers: {
      openAI: {
        resolveMap: { 'fixture-custom-model': 'fixture-custom-model' },
        models: {
          'fixture-custom-model': {
            transport: 'openai_responses',
            capabilityControls: {
              generation: { state: 'auto_available', recipeRef, customControlRefs: ['fixture.generation.temperature'] },
            },
          },
        },
      },
    },
  };
}

function repoFile(relative: string): string {
  let current = process.cwd();
  for (;;) {
    const candidate = path.join(current, relative);
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`missing fixture: ${relative}`);
    current = parent;
  }
}
