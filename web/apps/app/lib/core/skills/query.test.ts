import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, Provider, Skill } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import {
  __resetMetadataClientForTest,
  __seedMetadataCacheForTest,
  initMetadata,
} from '../metadata/metadata-client';
import { getSkillById, resolveModelForSkill } from './query';
import { startConversationWithSkill } from './start-conversation';

// Skill usage recording goes through lazy ops: this file only checks opening the conversation, so no real record is triggered.
vi.mock('./ops-lazy', () => ({
  loadSkillOps: () => Promise.resolve({ recordSkillUseOp: vi.fn() }),
}));

function model(id: string, evidence: AIModel['capabilityEvidenceCandidates']): AIModel {
  return {
    id,
    name: id,
    capabilities: ['reasoning'],
    reasoningModeAvailable: true,
    reasoningProfile: 'reasoning-profile',
    capabilityEvidenceCandidates: evidence,
    transport: 'openai_chat',
    isAvailable: true,
    isDefault: true,
    priceTier: '',
  };
}

function provider(id: string, models: AIModel[]): Provider {
  return {
    id,
    kind: 'openAI',
    status: { kind: 'connected' },
    models,
    catalogModels: models,
    apiKey: 'local-test-key',
    apiKeyPreview: 'local-test-preview',
  } as Provider;
}

describe('resolveModelForSkill capability evidence', () => {
  it('selects the model whose production evidence supports a real reasoning level', () => {
    const staleRawModel = model('raw-only', []);
    const evidencedModel = model('evidenced', [
      {
        key: 'reasoning_level/deep',
        support: 'supported',
        source: 'server_profile',
        grade: 'effect_verified',
        scope: 'provider_model_transport',
        providerKind: 'openAI',
        modelId: 'evidenced',
        transport: 'openai_chat',
      },
    ]);
    const rawProvider = provider('raw-provider', [staleRawModel]);
    const evidenceProvider = provider('evidence-provider', [evidencedModel]);
    const state = {
      providers: [rawProvider, evidenceProvider],
      lastUsedModelRef: { providerID: rawProvider.id, modelID: staleRawModel.id },
    } as AppStore;
    const store = { getState: () => state } as StoreApi<AppStore>;
    const skill = {
      id: 'skill-1',
      modelCapabilityHint: 'reasoning',
    } as Skill;

    expect(resolveModelForSkill(store, skill)).toEqual({
      provider: evidenceProvider,
      model: evidencedModel,
    });
  });

  it('does not select a Relay model from raw vision metadata without request context', () => {
    const relayModel = model('relay-vision', undefined);
    relayModel.capabilities = ['image'];
    const relayProvider = {
      ...provider('relay-provider', [relayModel]),
      kind: 'relay',
    } as Provider;
    const officialModel = model('official-vision', [
      {
        key: 'vision_input',
        support: 'supported',
        source: 'server_profile',
        grade: 'effect_verified',
        scope: 'provider_model_transport',
        providerKind: 'openAI',
        modelId: 'official-vision',
        transport: 'openai_chat',
      },
    ]);
    // Image input reads the input-capability projection: for an official provider, capabilityControls decides.
    officialModel.capabilityControls = {
      vision_input: { state: 'auto_available', wireFamily: 'openai_chat.image_url' },
    } as typeof officialModel.capabilityControls;
    const officialProvider = provider('official-provider', [officialModel]);
    const store = {
      getState: () => ({ providers: [relayProvider, officialProvider] }) as AppStore,
    } as StoreApi<AppStore>;

    expect(resolveModelForSkill(store, {
      id: 'skill-vision',
      modelCapabilityHint: 'vision',
    } as Skill)?.provider.id).toBe('official-provider');
  });

  it('matches the capability hint on the current connection first, then in list order', () => {
    const first = provider('first-provider', [{ ...model('first-long', []), contextLength: 200000 }]);
    const current = provider('current-provider', [{ ...model('current-long', []), contextLength: 200000 }]);
    const state = {
      providers: [first, current],
      lastUsedModelRef: { providerID: current.id, modelID: 'gone-model' },
    } as AppStore;
    const store = { getState: () => state } as StoreApi<AppStore>;

    expect(resolveModelForSkill(store, {
      id: 'skill-long',
      modelCapabilityHint: 'large-context',
    } as Skill)?.provider.id).toBe('current-provider');
  });
});

describe('resolveModelForSkill retired models', () => {
  afterEach(() => {
    __resetMetadataClientForTest();
  });

  it('skips the first enabled model when its id is tombstoned and takes the next usable one', async () => {
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest({
      data: {
        version: 1, contractVersion: 1, updatedAt: '2026-10-18T00:00:00Z',
        profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
        providers: {
          openAI: {
            retiredModels: [{ id: 'tomb-model', displayName: 'Tomb Model', routedTo: 'live-model' }],
            models: { 'live-model': { displayName: 'Live Model' } },
          },
        },
        providerConfigs: [],
      },
      timestamp: Date.now(),
    } as never);
    await initMetadata();
    const tombModel = { ...model('tomb-model', []), isDefault: false };
    const liveModel = { ...model('live-model', []), isDefault: false };
    const officialProvider = provider('official-provider', [tombModel, liveModel]);
    const state = {
      providers: [officialProvider],
      lastUsedModelRef: { providerID: officialProvider.id, modelID: tombModel.id },
    } as AppStore;
    const store = { getState: () => state } as StoreApi<AppStore>;

    expect(resolveModelForSkill(store, {
      id: 'skill-any',
      modelCapabilityHint: 'any',
      suggestedProviderId: 'openAI',
      suggestedModelId: 'tomb-model',
    } as Skill)).toEqual({ provider: officialProvider, model: liveModel });
  });
});

describe('getSkillById', () => {
  // Catalog ids are lowercase UUIDs; iOS writes a conversation's skillId as an uppercase uuidString.
  it('matches a skill id regardless of UUID case', () => {
    const catalogSkill = { id: '3fa85f64-5717-4562-b3fc-2c963f66afa6' } as Skill;
    const store = {
      getState: () => ({ catalogSkills: [catalogSkill], userSkills: [] as Skill[] }) as unknown as AppStore,
    } as StoreApi<AppStore>;

    expect(getSkillById(store, '3FA85F64-5717-4562-B3FC-2C963F66AFA6')).toBe(catalogSkill);
  });
});

describe('resolveModelForSkill unusable connection criterion', () => {
  it('keeps a connection in issue status and skips one missing credentials', () => {
    const noKeyModel = model('no-key-model', []);
    const issueModel = model('issue-model', []);
    const noKeyProvider = { ...provider('no-key-provider', [noKeyModel]), apiKey: '' } as Provider;
    const issueProvider = {
      ...provider('issue-provider', [issueModel]),
      status: { kind: 'issue', message: 'catalog fetch failed' },
    } as Provider;
    const state = {
      providers: [noKeyProvider, issueProvider],
      lastUsedModelRef: { providerID: noKeyProvider.id, modelID: noKeyModel.id },
    } as AppStore;
    const store = { getState: () => state } as StoreApi<AppStore>;

    expect(resolveModelForSkill(store, { id: 'skill-plain' } as Skill)).toEqual({
      provider: issueProvider,
      model: issueModel,
    });
  });
});

describe('startConversationWithSkill last-used ref', () => {
  it('opens a draft on the resolved model without rewriting lastUsedModelRef', () => {
    const skillModel = model('skill-model', []);
    const skillProvider = provider('skill-provider', [skillModel]);
    const lastUsedModelRef = { providerID: 'other-provider', modelID: 'other-model' };
    const addConversation = vi.fn();
    const setActiveConversationId = vi.fn();
    const setLastUsedModelRef = vi.fn();
    const state = {
      providers: [skillProvider],
      lastUsedModelRef,
      addConversation,
      setActiveConversationId,
      setLastUsedModelRef,
    } as unknown as AppStore;
    const store = { getState: () => state } as StoreApi<AppStore>;

    const result = startConversationWithSkill(store, { id: 'skill-plain' } as Skill, { title: 'Skill' });

    expect(result.kind).toBe('ok');
    expect(addConversation).toHaveBeenCalledWith(expect.objectContaining({
      providerID: skillProvider.id,
      modelID: skillModel.id,
      skillId: 'skill-plain',
    }));
    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(state.lastUsedModelRef).toEqual(lastUsedModelRef);
  });
});
