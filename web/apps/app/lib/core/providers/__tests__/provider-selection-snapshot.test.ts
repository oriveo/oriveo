import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { createProviderSelectionSnapshot } from '../provider-selection-snapshot';

const { mockGetProviderDefaultModelId, mockResolveCatalogModel } = vi.hoisted(() => ({
  mockGetProviderDefaultModelId: vi.fn(),
  mockResolveCatalogModel: vi.fn(),
}));

const { mockEnrichRelayCatalog } = vi.hoisted(() => ({
  mockEnrichRelayCatalog: vi.fn((models: AIModel[]) => models),
}));

vi.mock('../../metadata/metadata-client', () => ({
  getProviderDefaultModelId: mockGetProviderDefaultModelId,
  getRelayRuntimeConfig: () => ({ version: 'test' }),
  resolveCatalogModel: mockResolveCatalogModel,
}));

vi.mock('../relay-official-catalog-match', () => ({
  enrichRelayCatalog: mockEnrichRelayCatalog,
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
    relayRequested: overrides.relayRequested,
    relayResolvedTransport: overrides.relayResolvedTransport,
  };
}

describe('provider-selection-snapshot', () => {
  beforeEach(() => {
    mockEnrichRelayCatalog.mockClear();
  });

  it('selects current by requested model id (canonical and dated snapshot are aligned)', () => {
    mockGetProviderDefaultModelId.mockReset();
    const provider = makeProvider({
      models: [
        makeModel('gpt-5.4-nano-2026-03-01', {
          name: 'GPT-5.4 Nano',
          canonicalModelId: 'gpt-5.4-nano',
        }),
        makeModel('o4-mini', { name: 'o4-mini', isDefault: true }),
      ],
    });

    const snapshot = createProviderSelectionSnapshot(provider, {
      requestedModelId: 'gpt-5.4-nano',
    });

    expect(snapshot?.currentModel?.id).toBe('gpt-5.4-nano-2026-03-01');
    expect(snapshot?.defaultModel?.id).toBe('o4-mini');
    expect(snapshot?.enabledModels.map((model) => model.id)).toEqual([
      'gpt-5.4-nano-2026-03-01',
      'o4-mini',
    ]);
  });

  it('with no user default, uses the metadata defaultModelId (only when it matches an enabled model)', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockGetProviderDefaultModelId.mockReturnValue('o4-mini');
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel('gpt-4o', { canonicalModelId: 'gpt-4o' }),
        makeModel('o4-mini-2026-04-10', { canonicalModelId: 'o4-mini' }),
      ],
    });

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(snapshot?.defaultModel?.id).toBe('o4-mini-2026-04-10');
    expect(snapshot?.currentModel?.id).toBe('o4-mini-2026-04-10');
  });

  it('does not fall back to catalogModels when there are no enabled models', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockGetProviderDefaultModelId.mockReturnValue('catalog-only');
    const provider = makeProvider({
      kind: 'openRouter',
      models: [],
      catalogModels: [makeModel('catalog-only')],
    });

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(snapshot?.enabledModels).toEqual([]);
    expect(snapshot?.defaultModel).toBeNull();
    expect(snapshot?.currentModel).toBeNull();
  });

  it('a relay provider does not go through the metadata default lookup', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockResolveCatalogModel.mockReset();
    const provider = makeProvider({
      kind: 'relay',
      models: [makeModel('relay/custom')],
    });

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(snapshot?.defaultModel?.id).toBe('relay/custom');
    expect(snapshot?.currentModel?.id).toBe('relay/custom');
    expect(mockGetProviderDefaultModelId).not.toHaveBeenCalled();
  });

  it('a relay provider runs official catalog enrichment before entering chat selection', () => {
    const provider = makeProvider({
      kind: 'relay',
      relayResolvedTransport: 'openai_chat_completions',
      models: [
        makeModel('gpt-5.4', { capabilities: ['text', 'web', 'imageGeneration'] }),
      ],
    });
    mockEnrichRelayCatalog.mockReturnValueOnce([
      makeModel('gpt-5.4', { capabilities: ['text'] }),
    ]);

    const snapshot = createProviderSelectionSnapshot(provider);

    expect(mockEnrichRelayCatalog).toHaveBeenCalledWith(
      provider.models,
      'openai_chat_completions',
      { version: 'test' },
    );
    expect(snapshot?.currentModel?.capabilities).toEqual(['text']);
    expect(snapshot?.enabledModels[0].capabilities).toEqual(['text']);
  });


  it('when a past conversation references a disabled model, currentModel keeps the metadata resolution instead of falling back to the default', () => {
    mockGetProviderDefaultModelId.mockReset();
    mockResolveCatalogModel.mockReset();
    mockGetProviderDefaultModelId.mockReturnValue('gpt-4o');
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'o4-mini',
      displayName: 'o4-mini',
      contextLength: undefined,
      capabilities: ['text', 'reasoning'],
      pricing: {
        promptPerToken: 0.000002,
        completionPerToken: 0.000008,
        cachedInputPerMToken: null,
      },
      profiles: {
        reasoning: 'openai.responses.reasoning.deep',
      },
      uiHints: undefined,
      isDefault: false,
    });
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel('gpt-4o', {
          name: 'GPT-4o',
          canonicalModelId: 'gpt-4o',
          isDefault: true,
        }),
      ],
    });

    const snapshot = createProviderSelectionSnapshot(provider, {
      requestedModelId: 'o4-mini-2026-04-10',
    });

    expect(snapshot?.currentModel).toMatchObject({
      id: 'o4-mini',
      canonicalModelId: 'o4-mini',
      name: 'o4-mini',
    });
    expect(snapshot?.defaultModel?.id).toBe('gpt-4o');
  });
});
