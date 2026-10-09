/**
 * Thinking linkage preview: whether it is on and the budget come from the same decision function as outbound; the drop set on the rows equals the drop set of the production builder's real request body.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import type { GenerationParameterOverrides, GenerationParameterProfile } from '@oriveo/core/providers/request-builders/types';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import { activeThinkingForPreview } from '../generation-thinking-preview';
import { generationParameterRows } from '../generation-parameter-rows';
import type { SourcedGenerationParameterOverrides } from '../generation-parameter-settings';

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
const values: GenerationParameterOverrides = {
  temperature: { state: 'value', value: 0.5 },
  top_p: { state: 'value', value: 0.9 },
  max_output_tokens: { state: 'value', value: 4000 },
};
const resolved: SourcedGenerationParameterOverrides = Object.fromEntries(
  Object.entries(values).map(([id, override]) => [id, { override: override!, layer: 'conversation' as const }]),
);
const model = { id: 'claude-sonnet-4-5', name: 'M', capabilities: ['text', 'reasoning'], reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: '' } as unknown as AIModel;
const metadata = async () => loadJSON<{ metadata: RuntimeMetadataResponse }>('request_shape_contract.v1.json').metadata;

function relayProvider(transport: string): Provider {
  return {
    id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'k', apiKeyPreview: '',
    baseURLText: 'https://relay.example/v1', relayResolvedTransport: transport, relayRequested: { transport },
  } as unknown as Provider;
}

function rowDrops(thinking: { budgetTokens?: number } | null, profile = anthropicProfile): Record<string, string> {
  const rows = generationParameterRows({ parameterIds: Object.keys(values), profile, resolved, editingLayers: ['conversation'], thinking });
  return Object.fromEntries(rows.flatMap((row) => row.dropReason ? [[row.id, row.dropReason]] : []));
}

/** Parameters whose value in the real request body differs from the panel value (removed or rewritten). */
function bodyDrops(body: Record<string, unknown>): string[] {
  return Object.entries(values)
    .filter(([id, item]) => item?.state === 'value' && body[anthropicProfile.wire[id]] !== item.value)
    .map(([id]) => id).sort();
}

describe('thinking linkage preview', () => {
  it('official Anthropic: with the same metadata as the production builder, predicted drops equal the real request body drops', async () => {
    // This contract metadata has no capabilityRuntime, so official thinking fails closed with zero injection; the preview and outbound must both leave it off.
    const provider = { id: 'conn-a', kind: 'anthropic', models: [model], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
    const capabilityPreferences = { web: 'off', reasoningIntent: 'deep' } as const;
    const thinking = await activeThinkingForPreview({ provider, model, profile: anthropicProfile, reasoningMode: 'deep', capabilityPreferences, officialMetadata: metadata });
    const request = await buildProviderRequest({
      providerKind: 'anthropic', apiKey: 'k', modelID: model.id, baseURL: 'https://contract.invalid/v1',
      messages: [{ role: 'user', content: 'hello' }],
      options: { reasoning: 'deep', capabilityPreferences, generationProfile: anthropicProfile, generationParameters: values },
    }, metadata);
    expect([thinking, request.body.thinking]).toEqual([null, undefined]);
    expect(Object.keys(rowDrops(thinking)).sort()).toEqual(bodyDrops(request.body));
    expect(bodyDrops(request.body)).toEqual([]);
  });

  it('official Anthropic: without the same metadata as outbound -> null, no mark', async () => {
    const provider = { id: 'conn-a', kind: 'anthropic', models: [model], catalogModels: [], status: { kind: 'connected' }, apiKey: '', apiKeyPreview: '' } as unknown as Provider;
    expect(await activeThinkingForPreview({ provider, model, profile: anthropicProfile, reasoningMode: 'deep' })).toBeNull();
  });

  it('Relay Anthropic protocol: predicted drops equal the real request body drops of the Relay send path', async () => {
    const thinking = await activeThinkingForPreview({ provider: relayProvider('anthropic_messages'), model, profile: anthropicProfile, reasoningMode: 'deep' });
    expect(thinking).toEqual({ budgetTokens: 16384 });
    let body: Record<string, unknown> | undefined;
    const deps: RelayOrchestratorDeps = {
      transport: { fetch: async (_url, init) => { body = JSON.parse(String(init.body)); return new Response('{}', { status: 200 }); } },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    };
    const handle = sendRelayStream('k', model.id, [{ role: 'user', content: 'hello' }], 'https://relay.example', {
      relayTransport: 'anthropic_messages', relayAuthMode: 'bearer', relayStream: false, reasoning: 'deep',
      generationProfile: anthropicProfile, generationParameters: values,
    }, deps);
    await handle.stream.getReader().read();
    expect(Object.keys(rowDrops(thinking)).sort()).toEqual(bodyDrops(body!));
    expect(Object.keys(rowDrops(thinking)).length).toBe(3);
  });

  it('Relay automatic tier does not send thinking -> null', async () => {
    expect(await activeThinkingForPreview({ provider: relayProvider('anthropic_messages'), model, profile: anthropicProfile, reasoningMode: 'automatic' })).toBeNull();
  });

  it('counter-example: the Chat Completions protocol is not marked', async () => {
    const chatProfile = { ...anthropicProfile, template: 'openai_chat_completions' };
    const chat = await activeThinkingForPreview({ provider: relayProvider('openai_chat_completions'), model, profile: chatProfile, reasoningMode: 'deep' });
    expect(chat).toBeNull();
    expect(rowDrops({ budgetTokens: 16384 }, chatProfile)).toEqual({});
  });
});

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
