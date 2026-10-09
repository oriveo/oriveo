/**
 * Shared contract "per-item outbound decisions": outboundRules + outboundCases.
 *
 * An invalid item drops only that item, conflicts are resolved in declaration order, a required
 * field cannot be removed by "do not send", and Anthropic gets a linkage guard when thinking is on.
 * Cases are read one by one from the shared file instead of copying the expectations here.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';

import { buildAnthropicRequest } from '../anthropic';
import { guardAnthropicThinking, resolveRelayAnthropicThinking } from '../anthropic-thinking';
import { buildProviderRequest } from '../dispatch';
import {
  mergeDroppedGenerationParameters,
  writeGenerationParameters,
  type DroppedGenerationParameter,
} from '../generation-parameters';
import type { RuntimeMetadataResponse } from '../runtime';
import type {
  GenerationParameterOverrides,
  GenerationParameterProfile,
} from '../types';
import { sendRelayStream, type RelayOrchestratorDeps } from '../../relay-orchestrator';
import type { StreamOptions } from '../../types';

interface OutboundCase {
  caseId: string;
  profile: {
    template: string;
    parameters: Array<Record<string, unknown> & { id: string }>;
    wire: Record<string, string>;
  };
  body: Record<string, unknown>;
  capabilityWrites?: Record<string, unknown>;
  overrides: Record<string, { state: 'value' | 'omit' | 'inherit'; value?: unknown }>;
  expect: { body: Record<string, unknown>; dropped: DroppedGenerationParameter[] };
}

const cases = loadJSON<{ outboundCases: OutboundCase[] }>('generation_parameter_contract.v1.cases.json').outboundCases;

describe('outboundCases (shared contract, case by case)', () => {
  it('the case group size is frozen at 21', () => {
    expect(cases).toHaveLength(21);
  });

  for (const item of cases) {
    it(item.caseId, () => {
      const profile = toProfile(item.profile);
      const body = structuredClone(item.body);
      const builderDefaultMaxTokens = body.max_tokens;
      const result = writeGenerationParameters(body, item.overrides as GenerationParameterOverrides, profile);
      // Contract: the capability writer writes thinking after the generation parameters, and the linkage guard is evaluated once it has finished.
      Object.assign(body, structuredClone(item.capabilityWrites ?? {}));
      const thinkingDropped = profile.template === 'anthropic_messages'
        ? guardAnthropicThinking(body, { profile, written: result.written, builderDefaultMaxTokens })
        : [];
      expect(body).toEqual(item.expect.body);
      expect(mergeDroppedGenerationParameters(result.dropped, thinkingDropped)).toEqual(item.expect.dropped);
    });
  }
});

const anthropicProfile: GenerationParameterProfile = {
  template: 'anthropic_messages',
  wire: { max_output_tokens: 'max_tokens', temperature: 'temperature', top_p: 'top_p', top_k: 'top_k' },
  parameters: [
    { id: 'max_output_tokens', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 1 } },
    { id: 'temperature', support: 'supported', source: 'test', valueSchema: 'number', range: { min: 0, max: 1 } },
    { id: 'top_p', support: 'supported', source: 'test', valueSchema: 'number', range: { min: 0, max: 1 } },
    { id: 'top_k', support: 'supported', source: 'test', valueSchema: 'integer', range: { min: 0 } },
  ],
};

const sampledOverrides: GenerationParameterOverrides = {
  temperature: { state: 'value', value: 0.5 },
  max_output_tokens: { state: 'value', value: 4000 },
};

describe('official Anthropic production builder: thinking linkage', () => {
  it('thinking on: temperature is not sent and max_tokens exceeds the thinking budget', () => {
    const request = buildAnthropicRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-fixture', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { generationProfile: anthropicProfile, generationParameters: sampledOverrides },
    }, { thinking: { type: 'enabled', budget_tokens: 16384 } }, null, 32000);
    expect(request.body.thinking).toEqual({ type: 'enabled', budget_tokens: 16384 });
    expect(request.body).not.toHaveProperty('temperature');
    expect(request.body.max_tokens).toBe(32000);
  });

  it('thinking off: temperature and max tokens are sent as usual', () => {
    const request = buildAnthropicRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-fixture', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { generationProfile: anthropicProfile, generationParameters: sampledOverrides },
    }, null, null, 32000);
    expect(request.body.temperature).toBe(0.5);
    expect(request.body.max_tokens).toBe(4000);
  });
});

describe('dispatch no longer throws on generation parameter validation', () => {
  it('an out-of-range item is left out of the request body and the rest is built as usual', async () => {
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: 'claude-sonnet-4-6', baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        generationProfile: anthropicProfile,
        generationParameters: {
          temperature: { state: 'value', value: 5 },
          top_k: { state: 'value', value: 40 },
        },
      },
    }, async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata);
    expect(request.body).not.toHaveProperty('temperature');
    expect(request.body.top_k).toBe(40);
  });
});

describe('Relay Anthropic production send path: thinking linkage', () => {
  it('the thinking decision has a single source', () => {
    expect(resolveRelayAnthropicThinking('deep')).toEqual({ budgetTokens: 16384, maxTokens: 20480 });
    expect(resolveRelayAnthropicThinking('fast')).toEqual({ budgetTokens: 2048, maxTokens: 8192 });
    expect(resolveRelayAnthropicThinking('automatic')).toBeNull();
    expect(resolveRelayAnthropicThinking(undefined)).toBeNull();
  });

  it('thinking on: temperature is not sent and a small panel max_tokens is raised back to the builder default', async () => {
    const body = await relayAnthropicBody({
      reasoning: 'deep', generationProfile: anthropicProfile, generationParameters: sampledOverrides,
    });
    expect(body.thinking).toEqual({ type: 'enabled', budget_tokens: 16384 });
    expect(body).not.toHaveProperty('temperature');
    expect(body.max_tokens).toBe(20480);
  });

  it('thinking off: sent as usual', async () => {
    const body = await relayAnthropicBody({ generationProfile: anthropicProfile, generationParameters: sampledOverrides });
    expect(body).not.toHaveProperty('thinking');
    expect(body.temperature).toBe(0.5);
    expect(body.max_tokens).toBe(4000);
  });

  it('without a profile or overrides, falls back to the budget + 4096', async () => {
    const body = await relayAnthropicBody({ reasoning: 'max' });
    expect(body.thinking).toEqual({ type: 'enabled', budget_tokens: 24576 });
    expect(body.max_tokens).toBe(28672);
  });

  it('an out-of-range parameter no longer makes the Relay send path throw and the item is not sent', async () => {
    const body = await relayAnthropicBody({
      generationProfile: anthropicProfile,
      generationParameters: { temperature: { state: 'value', value: 5 }, top_k: { state: 'value', value: 40 } },
    });
    expect(body).not.toHaveProperty('temperature');
    expect(body.top_k).toBe(40);
  });

  it('keeps the builder value when the required max_tokens is set to "do not send"', async () => {
    const body = await relayAnthropicBody({
      generationProfile: anthropicProfile,
      generationParameters: { max_output_tokens: { state: 'omit' } },
    });
    expect(body.max_tokens).toBe(8192);
  });
});

/** Runs the production relay send path and captures the body that is actually sent. */
async function relayAnthropicBody(options: Partial<StreamOptions>): Promise<Record<string, unknown>> {
  let captured: Record<string, unknown> | undefined;
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        captured = JSON.parse(String(init.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({ content: [{ type: 'text', text: 'ok' }] }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream(
    'sk-relay',
    'my-private-model',
    [{ role: 'user', content: 'hello' }],
    'https://relay.example/v1',
    { ...options, relayStream: false, relayTransport: 'anthropic_messages' } as StreamOptions,
    deps,
  );
  const reader = handle.stream.getReader();
  while (!(await reader.read()).done) { /* drain the whole stream */ }
  expect(captured, 'the production relay send path did not send a request').toBeDefined();
  return captured!;
}

function toProfile(raw: OutboundCase['profile']): GenerationParameterProfile {
  return {
    template: raw.template,
    wire: raw.wire,
    parameters: raw.parameters.map((parameter) => ({ support: 'supported', source: 'contract', ...parameter })),
  } as GenerationParameterProfile;
}

function loadJSON<T>(fileName: string): T {
  let current = process.cwd();
  while (true) {
    const candidate = path.join(current, 'shared', 'model-contracts', fileName);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${fileName} not found`);
    current = parent;
  }
}

describe('official Anthropic: linkage guard after the capability recipe turns thinking on', () => {
  const MODEL_ID = 'claude-sonnet-4-5';
  /** Metadata from the shared request-shape fixture plus the real recipe registry; the model's reasoning control points at the official Anthropic reasoning recipe. */
  function metadataWithReasoningRecipe(): RuntimeMetadataResponse {
    const metadata = loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata;
    const compiler = loadJSON<{ registryPath: string }>('provider_recipe_request_compiler.v1.json');
    const registry = loadRepoJSON<{ recipes: Record<string, unknown> }>(compiler.registryPath);
    metadata.capabilityRuntime = {
      schemaVersion: 2, revision: 'fixture-revision', generatedAt: '2026-10-08T00:00:00Z',
      recipes: registry.recipes, controlDefinitions: {}, sourceIndex: {},
    } as never;
    (metadata.providers.anthropic.models[MODEL_ID] as Record<string, unknown>).capabilityControls = {
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

  it('recipe turns thinking on with panel temperature / top_k: thinking stays, temperature and top_k are not sent and land in the dropped list', async () => {
    const metadata = metadataWithReasoningRecipe();
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: MODEL_ID, baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: {
        reasoning: 'max',
        capabilityPreferences: { web: 'off', reasoningIntent: 'max' },
        generationProfile: profile,
        generationParameters: { temperature: { state: 'value', value: 0.5 }, top_k: { state: 'value', value: 20 } },
      },
    }, async () => metadata);
    expect(request.body.thinking).toEqual({ type: 'adaptive' });
    expect(request.body).not.toHaveProperty('temperature');
    expect(request.body).not.toHaveProperty('top_k');
    expect(request.droppedGenerationParameters).toEqual([
      { parameterId: 'temperature', reason: 'thinking_incompatible' },
      { parameterId: 'top_k', reason: 'thinking_incompatible' },
    ]);
  });
});

function loadRepoJSON<T>(relative: string): T {
  let current = process.cwd();
  while (!existsSync(path.join(current, relative))) {
    const parent = path.dirname(current);
    if (parent === current) throw new Error(`${relative} not found`);
    current = parent;
  }
  return JSON.parse(readFileSync(path.join(current, relative), 'utf8')) as T;
}
