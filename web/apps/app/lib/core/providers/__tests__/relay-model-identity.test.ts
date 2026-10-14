// Unit 6-7 relay literal-ID identity: RL2-IDENT-01 to 08.
// Contract source: shared model-contracts/model_identity_contract.v1.json relayCases (primitives are covered by model-identity-contract.test.ts);
// this file locks the production-path behavior (load enrich / selection / enable-disable / catalog refresh / read compatibility / parameter keys).
import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Conversation, Provider } from '@oriveo/shared';

// The relay selection snapshot first does official catalog enrichment; here only the identity rule is tested, so enrichment passes through unchanged.
vi.mock('../relay-official-catalog-match', () => ({
  enrichRelayCatalog: (models: AIModel[]) => models,
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  initMetadata: vi.fn(async () => {}),
}));

import { createAppStore } from '../../store/app-store';
import { refreshProviderMetadata } from '../../store/persistence';
import {
  addManualProviderModels,
  disableProviderModel,
  enableProviderModel,
  findModelInProvider,
} from '../../provider-model-ops';
import { deduplicateModels } from '../catalog-model';
import { mergeRelayEnabledModels } from '../provider-sync';
import { createProviderSelectionSnapshot, resolveRelayFallbackModel } from '../provider-selection-snapshot';
import { resolveActiveSelection } from '../../chat/active-selection';
import { resolveConversationModelRemoval } from '../../chat/conversation-model-status';
import { createUserMessage } from '../../chat/message-factory';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent } from '../../chat/stream-options';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import {
  generationParameterFallbackModelId,
  loadGenerationParameterOverrides,
  removeGenerationParameterScopes,
  saveGenerationParameterOverrides,
} from '../../chat/generation-parameter-settings';
import {
  relayParameterKeysToRemoveOnDisable,
  relayStoredModelId,
} from '../relay-model-identity';

const BASE = 'gpt-4o';
const DATED = 'gpt-4o-2024-08-06';
const DATED_2 = 'gpt-4o-2024-11-20';

function makeModel(id: string, canonicalModelId: string | undefined = BASE): AIModel {
  return {
    id,
    name: 'GPT-4o',
    canonicalModelId,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
  };
}

function makeRelay(models: AIModel[], catalogModels: AIModel[] = models): Provider {
  return {
    id: 'A0000000-0000-0000-0000-0000000000A1',
    kind: 'relay',
    customName: 'My Relay',
    status: { kind: 'connected' },
    models,
    catalogModels,
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
    baseURLText: 'https://relay.example.com/v1',
    relayKind: 'openai_compatible',
    relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer' },
  };
}

function conversationFor(provider: Provider, modelID: string): Conversation {
  return {
    id: 'conversation-1',
    title: '',
    hasCustomTitle: false,
    providerID: provider.id,
    providerKind: provider.kind,
    modelID,
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-10-12T00:00:00.000Z',
    createdAt: '2026-10-12T00:00:00.000Z',
  };
}

function storeWith(provider: Provider) {
  const store = createAppStore();
  store.setState({ providers: [provider] });
  return store;
}

const ids = (models: readonly AIModel[]) => models.map((model) => model.id);

describe('RL2-IDENT relay literal identity', () => {
  beforeEach(() => {
    localStorage.clear();
  });

  it('RL2-IDENT-01 load enrich does not delete dated rows (both catalog and enabled list keep them)', async () => {
    const rows = [makeModel(DATED), makeModel(BASE), makeModel(DATED_2)];
    const store = storeWith(makeRelay(rows, rows));

    await refreshProviderMetadata(store);

    const loaded = store.getState().providers[0]!;
    expect(ids(loaded.models)).toEqual([DATED, BASE, DATED_2]);
    expect(ids(loaded.catalogModels)).toEqual([DATED, BASE, DATED_2]);
  });

  it('RL2-IDENT-01 load de-dup folds only rows differing by case / whitespace (first one wins)', async () => {
    const rows = [makeModel('GPT-4o'), makeModel(' gpt-4o '), makeModel(DATED)];
    const store = storeWith(makeRelay(rows, rows));

    await refreshProviderMetadata(store);

    expect(ids(store.getState().providers[0]!.models)).toEqual(['GPT-4o', DATED]);
  });

  it('RL2-IDENT-02 selecting the dated one: current model, stored value and the sent model are all the dated ID', async () => {
    const rows = [makeModel(BASE), makeModel(DATED)];
    const store = storeWith(makeRelay(rows, rows));
    await refreshProviderMetadata(store);
    const provider = store.getState().providers[0]!;

    const selection = resolveActiveSelection([provider], undefined, provider.id, DATED, null);
    expect(selection.currentModel?.id).toBe(DATED);
    expect(relayStoredModelId(selection.currentModel!)).toBe(DATED);
    expect(createUserMessage({ text: 'hi', provider, model: selection.currentModel! }).modelID).toBe(DATED);

    const fromConversation = resolveActiveSelection([provider], conversationFor(provider, DATED), null, null, null);
    expect(fromConversation.modelRemoval).toBeUndefined();
    expect(fromConversation.currentModel?.id).toBe(DATED);

    // Production StreamOptions → production relay send path: the upstream body.model is the dated literal ID.
    const model = selection.currentModel!;
    const options = buildProviderStreamOptions(provider, buildStreamOptionsFromIntent(model, 'automatic', false, undefined), model);
    let body: Record<string, unknown> | undefined;
    const deps: RelayOrchestratorDeps = {
      transport: {
        fetch: async (_url, init) => {
          body = JSON.parse(String(init.body)) as Record<string, unknown>;
          return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    };
    const handle = sendRelayStream('sk-test', model.id, [{ role: 'user', content: 'hi' }], provider.baseURLText, { ...options, relayStream: false }, deps);
    await handle.stream.getReader().read();
    expect(body?.model).toBe(DATED);

    // Last-used points at the dated one: the fallback is not merged into base.
    expect(resolveRelayFallbackModel(provider.id, provider.models, { providerID: provider.id, modelID: DATED })?.id).toBe(DATED);
  });

  it('RL2-IDENT-03 disabling one does not take the other with it; enabling the dated one is not swallowed by base', () => {
    const provider = makeRelay([makeModel(BASE)], [makeModel(BASE), makeModel(DATED)]);
    const store = storeWith(provider);

    const enabled = enableProviderModel(store, provider, makeModel(DATED));
    expect(enabled.id).toBe(DATED);
    expect(ids(store.getState().providers[0]!.models)).toEqual([BASE, DATED]);

    expect(disableProviderModel(store, provider, DATED)).toBe(true);
    expect(ids(store.getState().providers[0]!.models)).toEqual([BASE]);
  });

  it('RL2-IDENT-03 disable / manual duplicate check by key (trim + lowercase)', () => {
    const provider = makeRelay([makeModel(BASE), makeModel(DATED)]);
    const store = storeWith(provider);

    expect(addManualProviderModels(store, provider, ['GPT-4O', ` ${DATED_2} `]).map((model) => model.id)).toEqual([DATED_2]);
    expect(disableProviderModel(store, provider, 'GPT-4o-2024-08-06')).toBe(true);
    expect(ids(store.getState().providers[0]!.models)).toEqual([BASE, DATED_2]);
  });

  it('RL2-IDENT-04 catalog refresh: enabled dated is not merged into base; when the catalog has only base, dated is still kept', () => {
    const catalog = [makeModel(BASE), makeModel(DATED)];
    const enabled = [{ ...makeModel(DATED), relayKeyID: 'key-1' }];
    const merged = mergeRelayEnabledModels(enabled, catalog);
    expect(ids(merged)).toEqual([DATED]);
    expect(merged[0]!.relayKeyID).toBe('key-1');

    expect(ids(mergeRelayEnabledModels([makeModel(DATED), makeModel(BASE)], [makeModel(BASE)]))).toEqual([DATED, BASE]);

    // The criterion is key: a catalog row differing only by case refreshes onto the enabled row.
    const refreshed = mergeRelayEnabledModels([makeModel('GPT-4o')], [{ ...makeModel(BASE), contextLength: 128000 }]);
    expect(refreshed).toHaveLength(1);
    expect(refreshed[0]!.contextLength).toBe(128000);
  });

  it('RL2-IDENT-05 read compatibility: a historical canonical stored value is used when it matches uniquely', () => {
    const provider = makeRelay([makeModel(DATED), makeModel('claude-sonnet-4-5', 'anthropic/claude-sonnet-4.5')]);

    expect(resolveConversationModelRemoval(provider, BASE)).toBeNull();
    expect(createProviderSelectionSnapshot(provider, { requestedModelId: BASE })?.currentModel?.id).toBe(DATED);
    expect(resolveActiveSelection([provider], conversationFor(provider, BASE), null, null, null).currentModel?.id).toBe(DATED);
    expect(resolveRelayFallbackModel(provider.id, provider.models, { providerID: provider.id, modelID: BASE })?.id).toBe(DATED);
  });

  it('RL2-IDENT-05 read compatibility: canonical matches several / dated stored value left with only base → removed', () => {
    const ambiguous = makeRelay([makeModel(DATED), makeModel(DATED_2)]);
    expect(resolveConversationModelRemoval(ambiguous, BASE)).toMatchObject({ modelID: BASE, connectionName: 'My Relay' });
    expect(resolveActiveSelection([ambiguous], conversationFor(ambiguous, BASE), null, null, null)).toMatchObject({
      currentModel: undefined,
      modelRemoval: { modelID: BASE },
    });

    const baseOnly = makeRelay([makeModel(BASE)]);
    expect(resolveConversationModelRemoval(baseOnly, DATED)).toMatchObject({ modelID: DATED });
    // When the selected value cannot be resolved, fall back (first enabled), rather than merging dated into base.
    expect(createProviderSelectionSnapshot(ambiguous, { requestedModelId: BASE })?.currentModel?.id).toBe(DATED);
  });

  it('RL2-IDENT-06 parameter key writes literal, a missed literal read falls back to the canonical key', () => {
    const provider = makeRelay([makeModel(BASE), makeModel(DATED)]);
    const dated = makeModel(DATED);
    const fallbackModelId = generationParameterFallbackModelId(provider, dated);
    expect(fallbackModelId).toBe(BASE);
    // When the literal ID is itself canonical there is no fallback key; official providers do not fall back.
    expect(generationParameterFallbackModelId(provider, makeModel(BASE))).toBeUndefined();
    expect(generationParameterFallbackModelId({ ...provider, kind: 'openAI' }, dated)).toBeUndefined();

    // A value under the historical canonical key: read back when the literal key misses.
    saveGenerationParameterOverrides({ providerId: provider.id, modelId: BASE }, { temperature: { state: 'value', value: 0.3 } });
    expect(loadGenerationParameterOverrides({ providerId: provider.id, modelId: DATED, fallbackModelId })).toEqual({
      temperature: { state: 'value', value: 0.3 },
    });

    // After writing the literal key, reads of the literal key no longer fall back.
    saveGenerationParameterOverrides({ providerId: provider.id, modelId: DATED }, { temperature: { state: 'value', value: 0.9 } });
    expect(loadGenerationParameterOverrides({ providerId: provider.id, modelId: DATED, fallbackModelId })).toEqual({
      temperature: { state: 'value', value: 0.9 },
    });
    expect(loadGenerationParameterOverrides({ providerId: provider.id, modelId: BASE })).toEqual({
      temperature: { state: 'value', value: 0.3 },
    });
  });

  it('RL2-IDENT-07 disable deletes keys: delete the literal key; the canonical key only when no other enabled model has canonical equal to it', () => {
    const dated = makeModel(DATED, 'openai/gpt-4o');
    const dated2 = makeModel(DATED_2, 'openai/gpt-4o');
    // Another snapshot still has openai/gpt-4o as canonical: delete only the literal key.
    expect(relayParameterKeysToRemoveOnDisable([dated2], dated)).toEqual([DATED]);
    // No other enabled model with the same canonical: delete the canonical key too.
    expect(relayParameterKeysToRemoveOnDisable([makeModel('claude-sonnet-4-5', 'anthropic/claude-sonnet-4.5')], dated))
      .toEqual([DATED, 'openai/gpt-4o']);
    // Canonical equals the literal ID: only one key.
    expect(relayParameterKeysToRemoveOnDisable([], makeModel(BASE))).toEqual([BASE]);
    // Canonical happens to be another enabled model's literal key: that is someone else's literal key, do not delete.
    expect(relayParameterKeysToRemoveOnDisable([makeModel(BASE, undefined)], makeModel(DATED))).toEqual([DATED]);

    const providerId = 'A0000000-0000-0000-0000-0000000000A1';
    const value = { temperature: { state: 'value' as const, value: 0.5 } };
    saveGenerationParameterOverrides({ providerId, modelId: DATED }, value);
    saveGenerationParameterOverrides({ providerId, modelId: DATED_2 }, value);
    for (const modelId of relayParameterKeysToRemoveOnDisable([dated2], dated)) {
      removeGenerationParameterScopes({ providerId, modelId });
    }
    expect(loadGenerationParameterOverrides({ providerId, modelId: DATED })).toBeUndefined();
    expect(loadGenerationParameterOverrides({ providerId, modelId: DATED_2 })).toEqual(value);
  });

  it('RL2-IDENT-08 official provider (openAI) dated still folds into base (regression)', async () => {
    const official: Provider = {
      id: 'A0000000-0000-0000-0000-0000000000B2',
      kind: 'openAI',
      status: { kind: 'connected' },
      models: [makeModel(DATED), makeModel(BASE)],
      catalogModels: [],
      apiKey: 'sk-test',
      apiKeyPreview: 'sk-...test',
    };
    expect(ids(deduplicateModels([makeModel(DATED), makeModel(BASE)], 'openAI'))).toEqual([BASE]);
    expect(findModelInProvider({ ...official, models: [makeModel(DATED)] }, BASE)?.id).toBe(DATED);

    const store = storeWith(official);
    await refreshProviderMetadata(store);
    expect(ids(store.getState().providers[0]!.models)).toEqual([BASE]);
  });
});
