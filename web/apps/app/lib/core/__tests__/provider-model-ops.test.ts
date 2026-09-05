import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';

const { mockSelectResolvedCatalog, mockEnrichRelayCatalog } = vi.hoisted(() => ({
  mockSelectResolvedCatalog: vi.fn(() => ({
    catalog: [],
    enabledModels: [],
    recommendedModels: [],
    defaultModel: null,
    availableModelCount: 0,
    hasManualModels: false,
  })),
  // Passthrough by default: on a catalog miss enrichRelayCatalog returns the models unchanged,
  // matching production (`enrichRelayLocalModel` does `return { ...localModel }` when the sweep
  // across providers misses everywhere). Cases that need "catalog hit writes priceTier back"
  // override this mock individually.
  mockEnrichRelayCatalog: vi.fn((models: unknown[]) => models),
}));

vi.mock('../store/selectors', () => ({
  selectResolvedCatalog: mockSelectResolvedCatalog,
}));

vi.mock('../providers/relay-official-catalog-match', () => ({
  enrichRelayCatalog: mockEnrichRelayCatalog,
}));

vi.mock('../metadata/metadata-client', () => ({
  getRelayRuntimeConfig: vi.fn(() => ({ transportEnvelopes: {}, officialProviderWhitelist: [] })),
}));

vi.mock('../providers/provider-selection-snapshot', () => ({
  resolveRelaySelectionTransport: vi.fn(() => undefined),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUIDSync: () => 'account-a',
}));

import {
  addManualProviderModels,
  createManualModel,
  disableProviderModel,
  enableProviderModel,
  findModelInProvider,
  providerHasCatalogModels,
  replaceProviderModels,
} from '../provider-model-ops';
import {
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
} from '../chat/capability-recovery-runtime';

function makeModel(id: string, overrides: Partial<AIModel> = {}): AIModel {
  return {
    id,
    name: overrides.name ?? id,
    capabilities: overrides.capabilities ?? ['text'],
    reasoningModeAvailable: overrides.reasoningModeAvailable ?? false,
    isAvailable: overrides.isAvailable ?? true,
    isDefault: overrides.isDefault ?? false,
    priceTier: overrides.priceTier ?? '$',
    summary: overrides.summary,
    groupKey: overrides.groupKey,
    groupName: overrides.groupName,
    createdAt: overrides.createdAt,
    promptPrice: overrides.promptPrice,
    completionPrice: overrides.completionPrice,
    contextLength: overrides.contextLength,
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: overrides.id ?? 'p1',
    kind: overrides.kind ?? 'openRouter',
    status: overrides.status ?? { kind: 'connected' },
    models: overrides.models ?? [],
    catalogModels: overrides.catalogModels ?? [],
    apiKey: overrides.apiKey ?? 'sk-test',
    apiKeyPreview: overrides.apiKeyPreview ?? 'sk-...test',
    lastCheckedAt: overrides.lastCheckedAt,
    lastError: overrides.lastError,
    baseURLText: overrides.baseURLText,
    customName: overrides.customName,
    updatedAt: overrides.updatedAt,
    firestoreUpdatedAt: overrides.firestoreUpdatedAt,
  };
}

describe('provider-model-ops', () => {
  let store: ReturnType<typeof createAppStore>;

  beforeEach(() => {
    store = createAppStore();
    localStorage.clear();
  });

  it('createManualModel - derives base metadata from the model id and leaves priceTier as an empty placeholder', () => {
    expect(createManualModel('openai/gpt-5.4-mini', true)).toEqual(expect.objectContaining({
      id: 'openai/gpt-5.4-mini',
      name: 'gpt-5.4-mini',
      groupKey: 'openai',
      groupName: 'openai',
      isDefault: true,
      priceTier: '',
    }));
  });

  it('enableProviderModel - adds a model that was not enabled', () => {
    const provider = makeProvider({ models: [makeModel('m1')] });
    store.getState().addProvider(provider);

    enableProviderModel(store, provider, makeModel('m2'));

    expect(store.getState().providers[0].models.map((model) => model.id)).toEqual(['m1', 'm2']);
  });

  it('disableProviderModel - removes an enabled model', () => {
    const provider = makeProvider({ models: [makeModel('m1'), makeModel('m2')] });
    store.getState().addProvider(provider);

    disableProviderModel(store, provider, 'm1');

    expect(store.getState().providers[0].models.map((model) => model.id)).toEqual(['m2']);
  });

  it('replaceProviderModels - replaces with a deduplicated model list', () => {
    const provider = makeProvider({ models: [makeModel('m1')] });
    store.getState().addProvider(provider);

    replaceProviderModels(store, provider, [makeModel('m2'), makeModel('m2'), makeModel('m3')]);

    expect(store.getState().providers[0].models.map((model) => model.id)).toEqual(['m2', 'm3']);
  });

  it('addManualProviderModels - appends only new models and marks the first one as default', () => {
    const provider = makeProvider({ kind: 'relay' });
    store.getState().addProvider(provider);

    const added = addManualProviderModels(store, provider, ['openai/gpt-5.4-mini', 'openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4']);

    expect(added.map((model) => model.id)).toEqual(['openai/gpt-5.4-mini', 'anthropic/claude-sonnet-4']);
    expect(added[0]?.isDefault).toBe(true);
    expect(added[1]?.isDefault).toBe(false);
    // A manually entered Relay model must not assume upstream supports images, files, web search or reasoning; enrichment injects those after a catalog hit.
    expect(added[0]?.capabilities).toEqual(['text']);
    expect(added[0]?.capabilities).not.toContain('imageGeneration');
    expect(added[0]?.imageGenProfile).toBeUndefined();
    expect(store.getState().providers[0].models).toHaveLength(2);
  });

  it('manual model mutations clear the connection tool-call observation', () => {
    const provider = makeProvider({ models: [makeModel('m1')] });
    store.getState().addProvider(provider);
    const identity = {
      accountId: 'account-a', connectionId: 'p1', authMode: 'apiKey' as const,
      canonicalModelId: 'm1', finalTransport: 'openai_chat',
    };
    recordToolCallSupportFalse(identity);
    addManualProviderModels(store, provider, ['manual-model']);
    expect(toolCallSupportIsRememberedFalse(identity)).toBe(false);
  });

  it('addManualProviderModels - runs enrichRelayCatalog on a Relay write and merges the catalog priceTier / promptPrice back into the store', () => {
    // Simulate an enrichment hit: inject priceTier / promptPrice / completionPrice into the enriched models.
    mockEnrichRelayCatalog.mockImplementationOnce((models: AIModel[]) =>
      models.map((m) => ({
        ...m,
        priceTier: '$$',
        promptPrice: 0.000003,
        completionPrice: 0.000015,
        canonicalModelId: 'gpt-5.5',
      })),
    );

    const provider = makeProvider({ kind: 'relay' });
    store.getState().addProvider(provider);

    addManualProviderModels(store, provider, ['gpt-5.5']);

    expect(mockEnrichRelayCatalog).toHaveBeenCalled();
    const stored = store.getState().providers[0].models[0];
    expect(stored.priceTier).toBe('$$');
    expect(stored.promptPrice).toBe(0.000003);
    expect(stored.completionPrice).toBe(0.000015);
    expect(stored.canonicalModelId).toBe('gpt-5.5');
  });

  it('addManualProviderModels - keeps priceTier as an empty string on a Relay catalog miss (passthrough)', () => {
    // The default mock is passthrough and does not touch the models, so priceTier keeps the initial '' from createRelayManualModel.
    const provider = makeProvider({ kind: 'relay' });
    store.getState().addProvider(provider);

    addManualProviderModels(store, provider, ['totally-unknown-model']);

    const stored = store.getState().providers[0].models[0];
    expect(stored.priceTier).toBe('');
    expect(stored.promptPrice).toBeUndefined();
    expect(stored.completionPrice).toBeUndefined();
  });

  it('addManualProviderModels - skips Relay enrichment for an official provider, whose kind is not relay', () => {
    mockEnrichRelayCatalog.mockClear();
    const provider = makeProvider({ kind: 'openai' });
    store.getState().addProvider(provider);

    addManualProviderModels(store, provider, ['gpt-image-1']);

    expect(mockEnrichRelayCatalog).not.toHaveBeenCalled();
  });

  it('addManualProviderModels - gives a manually entered model on an official provider the text capability only', () => {
    const provider = makeProvider({ kind: 'openai' });
    store.getState().addProvider(provider);

    const added = addManualProviderModels(store, provider, ['gpt-image-1']);

    expect(added).toHaveLength(1);
    expect(added[0]?.capabilities).toEqual(['text']);
    expect(added[0]?.imageGenProfile).toBeUndefined();
  });

  it('findModelInProvider - looks through enabled models and then catalogModels', () => {
    const provider = makeProvider({
      models: [makeModel('m-enabled')],
      catalogModels: [makeModel('m-catalog')],
    });

    expect(findModelInProvider(provider, 'm-enabled')?.id).toBe('m-enabled');
    expect(findModelInProvider(provider, 'm-catalog')?.id).toBe('m-catalog');
    expect(findModelInProvider(provider, 'm-not-found')).toBeUndefined();
  });

  it('findModelInProvider - does not trigger the full catalog resolver on a miss', () => {
    mockSelectResolvedCatalog.mockClear();
    const provider = makeProvider({
      models: [makeModel('m-enabled')],
      catalogModels: [makeModel('m-catalog')],
    });

    expect(findModelInProvider(provider, 'm-not-found')).toBeUndefined();
    expect(mockSelectResolvedCatalog).not.toHaveBeenCalled();
  });

  it('providerHasCatalogModels - is always false for relay and depends on metadata for an official provider, which is false while unloaded', () => {
    expect(providerHasCatalogModels(makeProvider({
      kind: 'relay',
      models: [makeModel('m1')],
      catalogModels: [makeModel('m1'), makeModel('m2')],
    }))).toBe(false);

    // Without metadata the resolved catalog of an official provider is empty, so this returns false.
    expect(providerHasCatalogModels(makeProvider({
      kind: 'openRouter',
      models: [makeModel('m1')],
      catalogModels: [],
    }))).toBe(false);
  });
});
