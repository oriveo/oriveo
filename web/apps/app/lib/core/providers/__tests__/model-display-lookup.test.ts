import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { createModelDisplayLookup } from '../model-display-lookup';

const { mockResolveCatalogModel } = vi.hoisted(() => ({
  mockResolveCatalogModel: vi.fn(),
}));

vi.mock('../../metadata/metadata-client', () => ({
  resolveCatalogModel: mockResolveCatalogModel,
}));

function makeModel(id: string, overrides: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: overrides.name ?? id,
    canonicalModelId: overrides.canonicalModelId,
    capabilities: overrides.capabilities ?? ['text'],
    reasoningModeAvailable: overrides.reasoningModeAvailable ?? false,
    isAvailable: overrides.isAvailable ?? true,
    isDefault: overrides.isDefault ?? false,
    priceTier: overrides.priceTier ?? '$',
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: overrides.id ?? 'provider-1',
    kind: overrides.kind ?? 'openAI',
    status: overrides.status ?? { kind: 'connected' },
    models: overrides.models ?? [],
    catalogModels: overrides.catalogModels ?? [],
    apiKey: overrides.apiKey ?? 'sk-test',
    apiKeyPreview: overrides.apiKeyPreview ?? 'sk-...test',
  };
}

describe('model-display-lookup', () => {
  it('an official provider prefers the metadata display name over the older local name', () => {
    mockResolveCatalogModel.mockReset();
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-4o',
      displayName: 'GPT-4o Latest',
      contextLength: undefined,
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      uiHints: undefined,
      isDefault: false,
    });
    const provider = makeProvider({
      kind: 'openAI',
      models: [makeModel('gpt-4o', { name: 'Local Override', canonicalModelId: 'gpt-4o' })],
    });

    const lookup = createModelDisplayLookup(provider);
    const resolved = lookup.resolve('gpt-4o');

    expect(resolved).toEqual({
      modelId: 'gpt-4o',
      canonicalModelId: 'gpt-4o',
      displayName: 'GPT-4o Latest',
    });
    expect(mockResolveCatalogModel).toHaveBeenCalledWith('gpt-4o', 'openAI');
  });

  it('falls back to the metadata canonical/display name when enabled models do not match', () => {
    mockResolveCatalogModel.mockReset();
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'o4-mini',
      displayName: 'o4-mini',
      contextLength: undefined,
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      uiHints: undefined,
      isDefault: false,
    });
    const provider = makeProvider({ kind: 'openAI', models: [] });

    const lookup = createModelDisplayLookup(provider);
    const resolved = lookup.resolve('o4-mini-2026-04-10');

    expect(resolved).toEqual({
      modelId: 'o4-mini',
      canonicalModelId: 'o4-mini',
      displayName: 'o4-mini',
    });
    expect(mockResolveCatalogModel).toHaveBeenCalledWith('o4-mini-2026-04-10', 'openAI');
  });

  it('a relay provider never queries metadata and returns the raw model id', () => {
    mockResolveCatalogModel.mockReset();
    const provider = makeProvider({ kind: 'relay', models: [] });

    const lookup = createModelDisplayLookup(provider);
    const resolved = lookup.resolve('relay/custom-model');

    expect(resolved).toEqual({
      modelId: 'relay/custom-model',
      canonicalModelId: undefined,
      displayName: undefined,
    });
    expect(mockResolveCatalogModel).not.toHaveBeenCalled();
  });
});
