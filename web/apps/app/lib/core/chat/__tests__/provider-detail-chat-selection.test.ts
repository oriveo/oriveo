// Receiving-end guard for provider details -> "added models" -> Chat -> the model name at the top
// of the new conversation.
// Complements active-selection.test.ts: that file mocks the snapshot factory so that any existing
// provider yields a model and only tests the four-level priority, which happens to mask the
// silent fallback inside createProviderSelectionSnapshot
// (`findModelByIdentifier(...) ?? resolveHistoricalModel(...) ?? defaultModel`).
// This one uses the real snapshot and pins that the model.id clicked on the detail page resolves
// back to the same model through lastUsedModelRef, rather than being replaced by that provider's
// default model.

import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

// A new conversation does not depend on metadata: if the clicked model still resolves with it emptied, the match came from provider.models itself.
vi.mock('../../metadata/metadata-client', () => ({
  getProviderDefaultModelId: () => undefined,
  getRelayRuntimeConfig: () => undefined,
  resolveCatalogModel: () => null,
  resolveCatalogModelAcrossProvidersWithProvider: () => null,
  DEFAULT_RELAY_RUNTIME_CONFIG: { transports: {} },
}));

import { resolveActiveSelection } from '../active-selection';

function makeModel(id: string, name: string, isDefault = false): AIModel {
  return {
    id,
    name,
    capabilities: [],
    isAvailable: true,
    isDefault,
    priceTier: '',
  } as unknown as AIModel;
}

function makeProvider(id: string, models: AIModel[]): Provider {
  return {
    id,
    kind: 'openAI',
    status: { kind: 'connected' },
    models,
    catalogModels: [],
    apiKey: 'k',
    apiKeyPreview: '',
  } as unknown as Provider;
}

const PROVIDER_A = makeProvider('provider-a', [makeModel('gpt-4o', 'GPT-4o', true)]);
const PROVIDER_B = makeProvider('provider-b', [
  makeModel('claude-haiku', 'Claude Haiku', true),
  makeModel('claude-opus', 'Claude Opus'),
]);

describe(' ', () => {
  it('switching to a non-default model of another provider changes both the provider and the model', () => {
    const result = resolveActiveSelection(
      [PROVIDER_A, PROVIDER_B],
      undefined, //   conversation
      null, //   selected
      null,
      { providerID: 'provider-b', modelID: 'claude-opus' },
    );

    expect(result.provider?.id).toBe('provider-b');
    expect(result.currentModel?.id).toBe('claude-opus');
    expect(result.currentModel?.name).toBe('Claude Opus');
  });

  it('picking a non-default model within one provider does not fall back to that provider default', () => {
    const result = resolveActiveSelection(
      [PROVIDER_B],
      undefined,
      null,
      null,
      { providerID: 'provider-b', modelID: 'claude-opus' },
    );

    expect(result.currentModel?.id).toBe('claude-opus');
  });

  it(' ', () => {
    const provider = makeProvider('provider-c', [
      makeModel('gpt-5.4', 'GPT-5.4', true),
      makeModel('o4-mini-2026-04-10', 'o4-mini'),
    ]);

    const result = resolveActiveSelection(
      [provider],
      undefined,
      null,
      null,
      { providerID: 'provider-c', modelID: 'o4-mini-2026-04-10' },
    );

    expect(result.currentModel?.id).toBe('o4-mini-2026-04-10');
  });
});
