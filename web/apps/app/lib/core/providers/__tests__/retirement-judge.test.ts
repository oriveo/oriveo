// createRetirementJudge: judges retirement / new-chat selectability model by model for one connection; the catalog base table is built only once, and the verdicts match calling the single-model entries one by one.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  createRetirementJudge,
  isModelSelectableForNewChat,
  resolveProviderModelRetirement,
} from '../provider-selection-snapshot';

const {
  mockGetProviderCatalogStatus,
  mockGetProviderRetiredModels,
  mockListProviderModelIds,
  mockResolveCatalogModel,
} = vi.hoisted(() => ({
  mockGetProviderCatalogStatus: vi.fn((): 'loaded' | 'pending' | 'absent' => 'loaded'),
  mockGetProviderRetiredModels: vi.fn((): unknown[] => []),
  mockListProviderModelIds: vi.fn((): string[] => []),
  mockResolveCatalogModel: vi.fn(),
}));

vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  getProviderCatalogStatus: mockGetProviderCatalogStatus,
  getProviderDefaultModelId: () => 'live',
  getProviderRetiredModels: mockGetProviderRetiredModels,
  listProviderModelIds: mockListProviderModelIds,
  resolveCatalogModel: mockResolveCatalogModel,
}));

function makeModel(id: string, canonicalModelId?: string): AIModel {
  return {
    id,
    name: id,
    canonicalModelId,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '$',
  };
}

function makeProvider(models: AIModel[], kind: Provider['kind'] = 'openAI'): Provider {
  return {
    id: 'provider-1',
    kind,
    status: { kind: 'connected' },
    models,
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
  };
}

// Catalog: live is usable; sunset is past its shutdown date (succeeded by live); retired-canonical is in the tombstones; tomb is only in the tombstones;
// the enabled models also include ghost (not in the catalog), alias (canonical points to live) and alias-dead (canonical points to a tombstone).
const CATALOG: Record<string, { lifecycle?: { state: string; shutdownAt: string; routedTo?: string } }> = {
  live: {},
  sunset: { lifecycle: { state: 'deprecated', shutdownAt: '2020-01-01T00:00:00Z', routedTo: 'live' } },
  'retired-canonical': {},
};
const MODELS = [
  makeModel('live'),
  makeModel('sunset'),
  makeModel('tomb'),
  makeModel('ghost'),
  makeModel('alias', 'live'),
  makeModel('alias-dead', 'retired-canonical'),
];

describe('createRetirementJudge', () => {
  beforeEach(() => {
    mockGetProviderCatalogStatus.mockReset();
    mockGetProviderCatalogStatus.mockReturnValue('loaded');
    mockGetProviderRetiredModels.mockReset();
    mockGetProviderRetiredModels.mockReturnValue([
      { id: 'tomb', displayName: 'Tomb', retiredAt: '2026-01-01T00:00:00Z', routedTo: 'live' },
      { id: 'retired-canonical', displayName: 'Retired', retiredAt: '2026-01-01T00:00:00Z' },
    ]);
    mockListProviderModelIds.mockReset();
    mockListProviderModelIds.mockReturnValue(Object.keys(CATALOG));
    mockResolveCatalogModel.mockReset();
    mockResolveCatalogModel.mockImplementation((id: string) => (
      id in CATALOG ? { canonicalModelId: id, displayName: id, lifecycle: CATALOG[id]!.lifecycle } : undefined
    ));
  });

  it('judging N models of one connection takes the catalog base table only once', () => {
    const provider = makeProvider(MODELS);
    const judge = createRetirementJudge(provider);
    for (const model of MODELS) {
      judge.isSelectableForNewChat(model);
      judge.retirementOf(model.id, [model]);
    }
    expect(mockListProviderModelIds).toHaveBeenCalledTimes(1);
    expect(mockGetProviderRetiredModels).toHaveBeenCalledTimes(1);
    expect(mockGetProviderCatalogStatus).toHaveBeenCalledTimes(1);
  });

  it('verdicts match isModelSelectableForNewChat / resolveProviderModelRetirement called one by one', () => {
    const provider = makeProvider(MODELS);
    const judge = createRetirementJudge(provider);
    const viaJudge = MODELS.map((model) => ({
      id: model.id,
      selectable: judge.isSelectableForNewChat(model),
      retirement: judge.retirementOf(model.id, [model]),
    }));
    const oneByOne = MODELS.map((model) => ({
      id: model.id,
      selectable: isModelSelectableForNewChat(provider, model),
      retirement: resolveProviderModelRetirement(provider, model.id, [model]),
    }));
    expect(viaJudge).toEqual(oneByOne);
    expect(viaJudge.map(({ id, selectable }) => [id, selectable])).toEqual([
      ['live', true],
      ['sunset', false],
      ['tomb', false],
      ['ghost', false],
      ['alias', true],
      ['alias-dead', false],
    ]);
    expect(viaJudge.find((entry) => entry.id === 'sunset')?.retirement).toMatchObject({ status: 'retired', successorId: 'live' });
    expect(viaJudge.find((entry) => entry.id === 'tomb')?.retirement).toMatchObject({ status: 'retired', displayName: 'Tomb' });
  });

  it('catalog not loaded is judged usable; a relay is always usable and never reads the catalog', () => {
    mockGetProviderCatalogStatus.mockReturnValue('pending');
    const pending = createRetirementJudge(makeProvider(MODELS));
    expect(MODELS.every((model) => pending.isSelectableForNewChat(model))).toBe(true);
    expect(mockListProviderModelIds).not.toHaveBeenCalled();

    mockGetProviderCatalogStatus.mockClear();
    const relay = createRetirementJudge(makeProvider(MODELS, 'relay'));
    expect(MODELS.every((model) => relay.isSelectableForNewChat(model))).toBe(true);
    expect(relay.retirementOf('tomb', MODELS)).toBeNull();
    expect(mockGetProviderCatalogStatus).not.toHaveBeenCalled();
  });
});
