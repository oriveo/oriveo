import { describe, expect, it } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, Provider, Skill } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { getSkillById, resolveModelForSkill } from './query';

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
    const officialProvider = provider('official-provider', [officialModel]);
    const store = {
      getState: () => ({ providers: [relayProvider, officialProvider] }) as AppStore,
    } as StoreApi<AppStore>;

    expect(resolveModelForSkill(store, {
      id: 'skill-vision',
      modelCapabilityHint: 'vision',
    } as Skill)?.provider.id).toBe('official-provider');
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
