import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { createModelDisplayLookup, findModelByIdentifier } from '../model-display-lookup';

const { mockResolveCatalogModel, mockGetProviderRetiredModels } = vi.hoisted(() => ({
  mockResolveCatalogModel: vi.fn(),
  mockGetProviderRetiredModels: vi.fn(() => [] as Array<{ id: string; displayName?: string }>),
}));

vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  resolveCatalogModel: mockResolveCatalogModel,
  getProviderRetiredModels: mockGetProviderRetiredModels,
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

  it('catalog has no such id but the tombstone does: falls back to the tombstone displayName', () => {
    mockResolveCatalogModel.mockReset();
    mockResolveCatalogModel.mockReturnValue(null);
    mockGetProviderRetiredModels.mockReset();
    mockGetProviderRetiredModels.mockReturnValue([
      { id: 'deepseek-chat', displayName: 'DeepSeek Chat', retiredAt: '2026-07-24T00:00:00Z', routedTo: 'deepseek-flash' },
    ]);
    const provider = makeProvider({ kind: 'deepseek', models: [] });

    const resolved = createModelDisplayLookup(provider).resolve('deepseek-chat');

    expect(resolved).toEqual({
      modelId: 'deepseek-chat',
      canonicalModelId: undefined,
      displayName: 'DeepSeek Chat',
    });
    expect(mockGetProviderRetiredModels).toHaveBeenCalledWith('deepseek');
  });

  it('neither catalog nor tombstone has it: falls back to the bare id', () => {
    mockResolveCatalogModel.mockReset();
    mockResolveCatalogModel.mockReturnValue(null);
    mockGetProviderRetiredModels.mockReset();
    mockGetProviderRetiredModels.mockReturnValue([
      { id: 'deepseek-chat', displayName: 'DeepSeek Chat' },
    ]);
    const provider = makeProvider({ kind: 'deepseek', models: [] });

    const resolved = createModelDisplayLookup(provider).resolve('glm-4-air');

    expect(resolved).toEqual({
      modelId: 'glm-4-air',
      canonicalModelId: undefined,
      displayName: undefined,
    });
  });

  describe('findModelByIdentifier', () => {
    it('exact tier follows candidate order: the original id wins over the date-stripped one', () => {
      const models = [makeModel('gpt-4o'), makeModel('gpt-4o-2024-11-20')];

      expect(findModelByIdentifier(models, 'gpt-4o-2024-11-20')?.id).toBe('gpt-4o-2024-11-20');
    });

    it('alias tier: a date-stripped canonical hits', () => {
      const models = [
        makeModel('gpt-4o-mini'),
        makeModel('my-sonnet', { canonicalModelId: 'claude-sonnet-4-5-20250929' }),
      ];

      expect(findModelByIdentifier(models, 'claude-sonnet-4-5')?.id).toBe('my-sonnet');
    });

    it('-MMDD is not a date suffix: no hit', () => {
      const models = [makeModel('deepseek-v4p1-flash'), makeModel('deepseek-v4-pro')];

      expect(findModelByIdentifier(models, 'deepseek-v4p1-flash-1017')).toBeUndefined();
    });
  });
});
