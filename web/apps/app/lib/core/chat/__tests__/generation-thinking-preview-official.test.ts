import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Extra proof for the official Anthropic thinking preview: by default the preview reads the browser-side metadata (the same /api/metadata payload as the route builder),
 * and still flags rows without officialMetadata; the dropped set on the rows == the dropped set of the real production builder body, and it is non-empty.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import type { GenerationParameterOverrides, GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { activeThinkingForPreview } from '../generation-thinking-preview';
import { generationParameterRows } from '../generation-parameter-rows';
import type { SourcedGenerationParameterOverrides } from '../generation-parameter-settings';

function fromRoot(relative: string): string {
  let dir = process.cwd();
  while (!existsSync(path.join(dir, relative))) dir = path.dirname(dir);
  return path.join(dir, relative);
}
const readJSON = <T>(relative: string): T => JSON.parse(readFileSync(fromRoot(relative), 'utf8')) as T;

const MODEL_ID = 'claude-sonnet-4-5';
/** Metadata from the shared request-shape fixture + the server's real recipe registry; this model's reasoning control points at the official Anthropic reasoning recipe. */
function metadataWithReasoningRecipe(): RuntimeMetadataResponse {
  const metadata = readJSON<{ metadata: RuntimeMetadataResponse }>('shared/model-contracts/request_shape_contract.v1.json').metadata;
  const compiler = readJSON<{ registryPath: string }>('shared/model-contracts/provider_recipe_request_compiler.v1.json');
  const recipes = readJSON<{ recipes: Record<string, unknown> }>(compiler.registryPath).recipes;
  metadata.capabilityRuntime = {
    schemaVersion: 2, revision: 'fixture-revision', generatedAt: '2026-10-08T00:00:00Z',
    recipes, controlDefinitions: {}, sourceIndex: {},
  } as never;
  const model = metadata.providers.anthropic.models[MODEL_ID] as Record<string, unknown>;
  model.capabilityControls = {
    reasoning: { state: 'auto_available', recipeRef: 'anthropic.messages.reasoning.v2', availableIntents: ['max'] },
  };
  return metadata;
}

const profile: GenerationParameterProfile = {
  template: 'anthropic_messages',
  wire: { max_output_tokens: 'max_tokens', temperature: 'temperature', top_p: 'top_p', top_k: 'top_k' },
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 1 } },
    { id: 'temperature', support: 'supported', source: 'test', valueSchema: 'number', range: { min: 0, max: 1 } },
    { id: 'top_p', support: 'supported', source: 'test', valueSchema: 'number', range: { min: 0, max: 1 } },
    { id: 'top_k', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 0 } },
  ],
};
const values: GenerationParameterOverrides = {
  temperature: { state: 'value', value: 0.5 },
  top_k: { state: 'value', value: 20 },
  max_output_tokens: { state: 'value', value: 40000 },
};
const resolved: SourcedGenerationParameterOverrides = Object.fromEntries(
  Object.entries(values).map(([id, override]) => [id, { override: override!, layer: 'conversation' as const }]),
);
const model = { id: MODEL_ID, name: 'M', capabilities: ['text', 'reasoning'], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: '' } as unknown as AIModel;
const provider = { id: 'conn-a', kind: 'anthropic', models: [model], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;

afterEach(() => __resetMetadataClientForTest());

describe('official Anthropic thinking preview', () => {
  async function previewAndRequest() {
    const metadata = metadataWithReasoningRecipe();
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({ data: structuredClone(metadata) as never, timestamp: Date.now() });
    await initMetadata();
    const capabilityPreferences = { web: 'off', reasoningIntent: 'max' } as const;
    const thinking = await activeThinkingForPreview({ provider, model, profile, reasoningMode: 'max', capabilityPreferences });
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: MODEL_ID, baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { reasoning: 'max', capabilityPreferences, generationProfile: profile, generationParameters: values },
    }, async () => metadata);
    const rows = generationParameterRows({ parameterIds: Object.keys(values), profile, resolved, editingLayers: ['conversation'], thinking });
    const rowDrops = rows.flatMap((row) => row.dropReason ? [row.id] : []).sort();
    const bodyDrops = Object.entries(values)
      .filter(([id, item]) => item?.state === 'value' && request.body[profile.wire[id]] !== item.value)
      .map(([id]) => id).sort();
    return { thinking, body: request.body, rowDrops, bodyDrops };
  }

  it('without officialMetadata: the preview reads browser metadata, turns thinking on just like the production builder, and flags the thinking-incompatible rows', async () => {
    const { thinking, body, rowDrops } = await previewAndRequest();
    expect(body.thinking).toEqual({ type: 'adaptive' });
    expect(thinking).toEqual({});
    expect(rowDrops).toEqual(['temperature', 'top_k']);
  });

  // Official Anthropic thinking is written by the capability recipe; dispatch evaluates the linked protection once more after the recipe.
  it('preview dropped set == dropped set of the production builder\'s real body, and it is non-empty', async () => {
    const { rowDrops, bodyDrops } = await previewAndRequest();
    expect(bodyDrops.length).toBeGreaterThan(0);
    expect(rowDrops).toEqual(bodyDrops);
  });

  it('browser metadata not loaded yet -> null, no guessing', async () => {
    __resetMetadataClientForTest();
    expect(await activeThinkingForPreview({ provider, model, profile, reasoningMode: 'max' })).toBeNull();
  });
});
