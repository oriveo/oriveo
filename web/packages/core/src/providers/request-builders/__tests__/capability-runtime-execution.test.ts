import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { resolveRuntimeRecipe } from '../capability-execution';
import { buildProviderRequest } from '../dispatch';
import type { RuntimeMetadataResponse } from '../runtime';
import type { RequestParams } from '../types';

interface CompilerCase {
  caseId: string;
  providerKind: RequestParams['providerKind'];
  transport: string;
  recipeRef: string;
  capability: 'web' | 'reasoning' | 'generation';
  selectedIntent?: 'off' | 'low' | 'balanced' | 'deep' | 'max';
  baseOwnedArrays: { tools?: unknown[] };
  expectedDelta: Record<string, unknown>;
}

interface NegativeCase {
  caseId: string;
  providerKind: string;
  transport: string;
  recipeRef: string;
  capability: 'web' | 'reasoning' | 'generation';
  expectReason: string;
}

/** Intent merge rules for requestOps: last-specific-wins, plus deduplicated append. */
interface MergeCase {
  caseId: string;
  providerKind: RequestParams['providerKind'];
  transport: string;
  recipeRef: string;
  capability: 'web' | 'reasoning' | 'generation';
  selectedIntent: string | null;
  recipeSnapshot: { requestOps: unknown[] };
  baseOwnedArrays: { tools?: unknown[] };
  expectedBody: Record<string, unknown>;
}

interface Fixture {
  registryPath: string;
  cases: CompilerCase[];
  negativeCases: NegativeCase[];
  mergeCases: MergeCase[];
}

describe('provider_recipe_request_compiler.v1 through the production request builder', () => {
  const fixture = loadFixture();
  const recipes = loadRecipes(fixture.registryPath);

  for (const item of fixture.cases) {
    it(item.caseId, async () => {
      const request = await buildProviderRequest(requestParams(item), async () => metadataFor(item, recipes));

      // capabilityExecution is written by dispatch after the real provider builder has produced the
      // body, not assembled as JSON by the test, so the fixture pins both the request delta and the
      // builder-owned arrays.
      expect(request.capabilityExecution?.recipeRefs).toEqual([item.recipeRef]);
      expect(request.capabilityExecution?.delta).toEqual(item.expectedDelta);
      expect(request.capabilityExecution?.redactedPreview).toEqual(item.expectedDelta);
      expect(request.body).toMatchObject(item.expectedDelta);
      expect(JSON.stringify(request.capabilityExecution?.redactedPreview)).not.toContain('fixture-api-key');
      if (item.caseId === 'openai.chat.exact_model_route_has_no_body_patch') {
        expect(request.body.model).toBe('fixture-model');
      }
    });
  }

  for (const item of fixture.negativeCases) {
    it(item.caseId, () => {
      const result = resolveRuntimeRecipe(recipes, item.recipeRef, item.providerKind, item.transport, item.capability);
      expect(result).toEqual({ accepted: false, reason: item.expectReason });
    });
  }

  // When a base op with no intent and a specialized op matching the current intent share a pointer,
  // the specialized one wins and the base one is dropped (last-specific-wins, independent of
  // written order). Appends to `/tools/-` are deduplicated by stableJson, including against
  // elements the builder already owns. The requestOps in the fixture are a verbatim snapshot
  // captured from the production /api/metadata, not a shape invented by the test.
  for (const item of fixture.mergeCases) {
    it(item.caseId, async () => {
      const request = await buildProviderRequest(
        mergeRequestParams(item),
        async () => mergeMetadataFor(item),
      );
      for (const [key, value] of Object.entries(item.expectedBody)) {
        expect(request.body[key], `${item.caseId} - body.${key}`).toEqual(value);
      }
    });
  }

  it('does not let a transport-mismatched v2 recipe fall back to the legacy web profile', async () => {
    const item = fixture.cases[0];
    const metadata = metadataFor({ ...item, transport: 'openai_chat' }, recipes);
    metadata.providers.openAI.models['fixture-model'].profiles = { webSearch: 'legacy_web' };
    metadata.profiles.webSearch.legacy_web = {
      mergeParams: { tools: [{ type: 'web_search_preview' }] },
    };

    const request = await buildProviderRequest(requestParams({ ...item, transport: 'openai_chat' }), async () => metadata);
    expect(request.capabilityExecution).toBeUndefined();
    expect(request.body.tools).toEqual(item.baseOwnedArrays.tools);
  });

  it('does not compile an intent omitted by the model control allowlist', async () => {
    const item = fixture.cases.find((candidate) => candidate.selectedIntent);
    expect(item).toBeDefined();
    const metadata = metadataFor(item!, recipes);
    metadata.providers[item!.providerKind].models['fixture-model'].capabilityControls![item!.capability] = {
      state: 'auto_available',
      recipeRef: item!.recipeRef,
      availableIntents: ['different-intent'],
    };

    const request = await buildProviderRequest(requestParams(item!), async () => metadata);

    expect(request.capabilityExecution).toBeUndefined();
    expect(request.body).not.toMatchObject(item!.expectedDelta);
  });
});

function requestParams(item: CompilerCase): RequestParams {
  return {
    providerKind: item.providerKind,
    apiKey: 'fixture-api-key',
    modelID: 'fixture-model',
    messages: [{ role: 'user', content: 'hello' }],
    // baseOwnedArrays in the fixture is an input to the builder, not a test-only body patch.
    ...(item.baseOwnedArrays.tools ? { tools: item.baseOwnedArrays.tools as RequestParams['tools'] } : {}),
    options: {
      ...(item.capability === 'web' ? { supportsWebSearch: true } : {}),
      ...(item.selectedIntent ? { reasoning: modeForIntent(item.selectedIntent) } : {}),
    },
  };
}

function mergeRequestParams(item: MergeCase): RequestParams {
  return {
    providerKind: item.providerKind,
    apiKey: 'fixture-api-key',
    modelID: 'fixture-model',
    messages: [{ role: 'user', content: 'hello' }],
    ...(item.baseOwnedArrays.tools ? { tools: item.baseOwnedArrays.tools as RequestParams['tools'] } : {}),
    options: {
      supportsWebSearch: true,
      // force is a typed intent and can only arrive through capabilityPreferences, the same path production uses.
      capabilityPreferences: { web: item.selectedIntent === 'force' ? 'force' : 'automatic' },
    },
  };
}

/** The recipes for mergeCases come from the production snapshot and synthetic ops in the fixture, not from the registry. */
function mergeMetadataFor(item: MergeCase): RuntimeMetadataResponse {
  const metadata = metadataFor({
    caseId: item.caseId,
    providerKind: item.providerKind,
    transport: item.transport,
    recipeRef: item.recipeRef,
    capability: item.capability,
    baseOwnedArrays: item.baseOwnedArrays,
    expectedDelta: {},
  }, {
    [item.recipeRef]: {
      id: item.recipeRef,
      providerKind: item.providerKind,
      transport: { protocol: item.transport },
      capability: item.capability,
      executionKind: 'server_tool',
      requestOps: item.recipeSnapshot.requestOps,
    },
  });
  if (item.selectedIntent) {
    metadata.providers[item.providerKind].models['fixture-model'].capabilityControls![item.capability]!.availableIntents = [item.selectedIntent];
  }
  return metadata;
}

function metadataFor(item: CompilerCase, recipes: Record<string, unknown>): RuntimeMetadataResponse {
  return {
    version: 2,
    updatedAt: '2026-08-11T00:00:00Z',
    profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
    capabilityRuntime: {
      schemaVersion: 2,
      revision: 'fixture-revision',
      generatedAt: '2026-08-11T00:00:00Z',
      recipes,
      controlDefinitions: {},
      sourceIndex: {},
    },
    providers: {
      [item.providerKind]: {
        resolveMap: { 'fixture-model': 'fixture-model' },
        models: {
          'fixture-model': {
            transport: item.transport,
            capabilityControls: {
              [item.capability]: {
                state: 'auto_available',
                recipeRef: item.recipeRef,
                ...(item.selectedIntent ? { availableIntents: [item.selectedIntent] } : {}),
              },
            },
          },
        },
      },
    },
  };
}

function modeForIntent(intent: NonNullable<CompilerCase['selectedIntent']>): 'fast' | 'balanced' | 'deep' | 'max' {
  if (intent === 'low') return 'fast';
  if (intent === 'balanced' || intent === 'deep' || intent === 'max') return intent;
  throw new Error(`fixture intent ${intent} has no current P3b UI bridge`);
}

function loadFixture(): Fixture {
  return JSON.parse(readFileSync(findFromRoot('shared/model-contracts/provider_recipe_request_compiler.v1.json'), 'utf8')) as Fixture;
}

function loadRecipes(relativeRegistryPath: string): Record<string, unknown> {
  const registry = JSON.parse(readFileSync(findFromRoot(relativeRegistryPath), 'utf8')) as { recipes: Record<string, unknown> };
  return registry.recipes;
}

function findFromRoot(relativePath: string): string {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, relativePath);
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${relativePath} not found`);
    current = parent;
  }
}
