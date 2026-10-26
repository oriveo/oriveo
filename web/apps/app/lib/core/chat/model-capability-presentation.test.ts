import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { makeRelayRequested, type AIModel, type Provider, type ProviderKind } from '@oriveo/shared';
import * as capabilityFacade from '@oriveo/core/providers/capability-evidence-facade';
import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../metadata/metadata-client';
import * as capabilityEvidence from './capability-evidence';
import { createRelayManualModel } from '../provider-model-ops';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../infra/storage/partition';
import {
  createModelCapabilityPresentationProjector,
  modelSupportsCapabilityFilter,
  visibleModelCapabilityBadges,
} from './model-capability-presentation';

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-evidence',
    name: 'GPT Evidence',
    capabilities: ['text', 'file', 'image', 'web', 'reasoning', 'imageGeneration'],
    reasoningModeAvailable: true,
    isAvailable: true,
    isDefault: true,
    priceTier: '',
    transport: 'openai_chat',
    ...overrides,
  };
}

function makeProvider(model: AIModel, kind: ProviderKind = 'openAI'): Provider {
  return {
    id: 'provider-1',
    kind,
    status: { kind: 'connected' },
    models: [model],
    catalogModels: [model],
    apiKey: 'local-test-key',
    apiKeyPreview: 'local-test-preview',
  } as Provider;
}

afterEach(() => {
  __resetMetadataClientForTest();
  resetCapabilityEvidenceIdentitiesForTesting();
  localStorage.clear();
});

describe('model capability presentation', () => {
  it('drives real filters and badges from production recipe controls plus evidence namespaces', async () => {
    await __seedMetadataCacheForTest({
      data: {
        version: 1,
        contractVersion: 1,
        updatedAt: '2026-08-15T00:00:00Z',
        profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
        capabilityRuntime: {
          schemaVersion: 2,
          revision: 'presentation-runtime',
          generatedAt: '2026-08-15T00:00:00Z',
          recipes: { 'fixture.reasoning': { id: 'fixture.reasoning' } },
          controlDefinitions: {},
          sourceIndex: {},
        },
        providers: {},
        providerConfigs: [],
      },
      timestamp: Date.now(),
    });
    await initMetadata();
    const model = makeModel({
      capabilityControls: {
        reasoning: { state: 'auto_available', recipeRef: 'fixture.reasoning' },
        web: { state: 'unavailable', reasonCode: 'model_capability_absent' },
        // The image / file badges read the input-capability projection's visible: the image badge lights only when the vision verdict is available; a missing file_input key = unknown, not lit.
        vision_input: { state: 'auto_available', wireFamily: 'openai_chat.image_url' },
      } as AIModel['capabilityControls'],
      capabilityEvidenceCandidates: [
        {
          key: 'vision_input',
          support: 'supported',
          source: 'server_profile',
          grade: 'effect_verified',
          scope: 'provider_model_transport',
          providerKind: 'openAI',
          modelId: 'gpt-evidence',
          transport: 'openai_chat',
        },
        {
          key: 'web_search',
          support: 'unsupported',
          source: 'server_profile',
          grade: 'effect_verified',
          scope: 'provider_model_transport',
          providerKind: 'openAI',
          modelId: 'gpt-evidence',
          transport: 'openai_chat',
        },
        {
          key: 'reasoning_level/deep',
          support: 'supported',
          source: 'server_profile',
          grade: 'effect_verified',
          scope: 'provider_model_transport',
          providerKind: 'openAI',
          modelId: 'gpt-evidence',
          transport: 'openai_chat',
        },
      ],
    });
    const provider = makeProvider(model);

    expect(modelSupportsCapabilityFilter(provider, model, 'image')).toBe(true);
    expect(modelSupportsCapabilityFilter(provider, model, 'web')).toBe(false);
    expect(modelSupportsCapabilityFilter(provider, model, 'reasoning')).toBe(true);
    expect(modelSupportsCapabilityFilter(provider, model, 'file')).toBe(false);
    expect(visibleModelCapabilityBadges(provider, model)).toEqual([
      'text',
      'image',
      'reasoning',
      'imageGeneration',
    ]);
  });

  it('treats a catalog-miss persisted evidence view as memory, then falls back to the model bit', () => {
    const model = makeModel({ capabilityEvidenceCandidates: [], toolCall: true });
    const provider = makeProvider(model);

    expect(modelSupportsCapabilityFilter(provider, model, 'tool')).toBe(true);
  });

  it('projects a subscription modelFacts tool fact into the UI-only badge without persisting it in capabilities', async () => {
    await __seedMetadataCacheForTest({
      data: {
        version: 1,
        contractVersion: 1,
        updatedAt: '2026-08-23T00:00:00Z',
        profiles: { reasoning: {}, webSearch: {}, imageGen: {}, generation: {} },
        providers: {},
        modelFacts: { 'openAI/gpt-evidence': { toolCall: true, source: 'models.dev' } },
        modelFactsRevision: 'facts-r1',
      },
      timestamp: Date.now(),
    });
    await initMetadata();
    const model = makeModel({ toolCall: undefined, transport: undefined });
    const provider = { ...makeProvider(model), authMode: 'subscription' } as Provider;

    expect(modelSupportsCapabilityFilter(provider, model, 'tool')).toBe(true);
    expect(visibleModelCapabilityBadges(provider, model)).toContain('toolCall');
    expect(model.capabilities).not.toContain('toolCall');
  });

  it('keeps catalog-declared badges but fails evidence-backed dimensions closed without a Provider', () => {
    const model = makeModel();
    expect(visibleModelCapabilityBadges(undefined, model)).toEqual([
      'text',
      'imageGeneration',
    ]);
  });

  it('does not treat Relay raw declarations as verified without actual stream context', () => {
    const model = makeModel({ transport: 'openai_chat' });
    const provider = makeProvider(model, 'relay');

    expect(modelSupportsCapabilityFilter(provider, model, 'image')).toBe(false);
    expect(modelSupportsCapabilityFilter(provider, model, 'web')).toBe(false);
    expect(visibleModelCapabilityBadges(provider, model)).toEqual([
      'text',
      'imageGeneration',
    ]);
  });

  it('vision_relay_add_on_unknown: Relay unknown + user add lights the image badge without a caller stream context', () => {
    const requested = makeRelayRequested('openai_compatible');
    requested.authMode = 'none';
    requested.securityMode = 'local_http';
    requested.transport = 'openai_chat_completions';
    requested.resolvedAPIBaseURL = 'http://127.0.0.1:8080/v1';
    const base = createRelayManualModel('relay-add-unknown');
    const model: AIModel = {
      ...base,
      capabilityOverrides: { vision_input: { op: 'add', setAt: '2026-10-19T00:00:00.000Z', baseVerdict: 'unknown' } },
    } as AIModel;
    const provider = {
      id: 'relay-add', kind: 'relay', status: { kind: 'connected' }, models: [model], catalogModels: [model],
      apiKey: '', apiKeyPreview: '', baseURLText: 'http://127.0.0.1:8080', relayKind: 'openai_compatible',
      relayRequested: requested, relayResolvedBaseURLText: 'http://127.0.0.1:8080/v1',
      relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'none',
    } as Provider;
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);

    expect(createModelCapabilityPresentationProjector()(provider, model).image).toBe(true);
    expect(visibleModelCapabilityBadges(provider, model)).toContain('image');
    // Without a user add, unknown does not light up.
    expect(createModelCapabilityPresentationProjector()(provider, base).image).toBe(false);
  });

  it('projects each model once per render cache even when sort, filter, and row ask repeatedly', () => {
    const models = Array.from({ length: 810 }, (_, index) => makeModel({
      id: `model-${index}`,
      name: `Model ${index}`,
      capabilities: [],
      reasoningProfile: undefined,
      reasoningModeAvailable: false,
      capabilityEvidenceCandidates: [],
    }));
    const provider = {
      ...makeProvider(models[0]),
      models,
      catalogModels: models,
    } as Provider;
    const resolveSpy = vi.spyOn(capabilityFacade, 'resolveCapabilityEvidence');
    const currentModelSpy = vi.spyOn(capabilityEvidence, 'currentCapabilityEvidenceModel');
    const querySpy = vi.spyOn(capabilityEvidence, 'modelCapabilityEvidenceQuery');
    const candidatesSpy = vi.spyOn(capabilityEvidence, 'modelCapabilityEvidenceCandidates');
    const project = createModelCapabilityPresentationProjector();

    for (const model of models) {
      expect(project(provider, model)).toBe(project(provider, model));
      project(provider, model);
    }

    // Reasoning/Web use Server recipe controls and vision reads the input-capability
    // projection; only tool still uses the evidence facade.
    expect(resolveSpy).toHaveBeenCalledTimes(810);
    expect(querySpy).toHaveBeenCalledTimes(810);
    // One shared shape for reasoning/vision/web plus the adapter's stricter
    // tool namespace shape; still independent of the seven facade keys.
    expect(candidatesSpy).toHaveBeenCalledTimes(810 * 2);
    // Presentation invokes each public adapter once; their internal pure
    // normalization is deliberately not replaced by a second local adapter.
    // The input badge also fills the entry-point stream context (automatic intent),
    // which resolves the current evidence model once more per model.
    expect(currentModelSpy).toHaveBeenCalledTimes(810 * 2);
  });
});
