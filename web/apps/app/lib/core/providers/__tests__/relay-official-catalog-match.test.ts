/**
 * @vitest-environment jsdom
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel } from '@oriveo/shared';
import { DEFAULT_RELAY_RUNTIME_CONFIG } from '../../metadata/metadata-client';
import type { ResolvedModelMetadata } from '../../metadata/metadata-client';

const resolveMock = vi.fn();

vi.mock('../../metadata/metadata-client', async (importOriginal) => {
  const mod = await importOriginal<typeof import('../../metadata/metadata-client')>();
  return {
    ...mod,
    resolveCatalogModelAcrossProvidersWithProvider: (
      modelId: string,
      options?: { transportPriority?: string | null },
    ) => resolveMock(modelId, options),
  };
});

const { enrichRelayCatalog, enrichRelayLocalModel } = await import('../relay-official-catalog-match');

function makeLocalModel(overrides: Partial<AIModel> & { id: string }): AIModel {
  return {
    name: overrides.id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...overrides,
  };
}

function makeMatchedMetadata(
  overrides: Partial<ResolvedModelMetadata> & { canonicalModelId: string },
): ResolvedModelMetadata {
  return {
    canonicalModelId: overrides.canonicalModelId,
    displayName: overrides.displayName,
    contextLength: overrides.contextLength,
    pricingStatus: overrides.pricingStatus ?? 'unknown',
    capabilities: overrides.capabilities ?? ['text'],
    pricing: overrides.pricing ?? null,
    profiles: overrides.profiles ?? {},
    uiHints: overrides.uiHints,
  };
}

beforeEach(() => {
  resolveMock.mockReset();
});

describe('enrichRelayLocalModel', () => {
  it('returns the local model untouched when there is no official catalog match, without inventing capabilities', () => {
    resolveMock.mockReturnValueOnce(null);
    const local = makeLocalModel({ id: 'my-custom-model', capabilities: ['text'] });
    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);
    expect(enriched).toEqual({ ...local });
    expect(enriched.relayMatchedProviderKind).toBeUndefined();
  });

  it('merges displayName / capabilities / canonical / profile on an official catalog match', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text', 'image', 'file', 'web', 'reasoning'],
        profiles: { reasoning: 'openaiReasoning', webSearch: 'openaiWebSearch' },
        uiHints: { groupKey: 'openai', groupName: 'OpenAI', rank: 10, recommended: true },
      }),
    });
    const local = makeLocalModel({ id: 'gpt-5.4', name: 'gpt-5.4', capabilities: ['text'] });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(resolveMock).toHaveBeenCalledWith('gpt-5.4', { transportPriority: 'openAI' });
    expect(enriched.canonicalModelId).toBe('gpt-5.4');
    expect(enriched.name).toBe('GPT-5.4');
    expect(enriched.capabilities).toEqual(['text', 'image', 'file', 'web', 'reasoning']);
    expect(enriched.reasoningProfile).toBe('openaiReasoning');
    expect(enriched.webSearchProfile).toBe('openaiWebSearch');
    expect(enriched.groupName).toBe('OpenAI');
    expect(enriched.relayMatchedProviderKind).toBe('openAI');
    expect(enriched.relayMatchSource).toBe('transport_first');
  });

  it('keeps user fields for a manual model (bare ID with isManual=true) while merging official pricing', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text', 'image', 'file', 'web', 'reasoning'],
        pricingStatus: 'priced',
        pricing: { promptPerToken: 0.000002, completionPerToken: 0.000008 },
      }),
    });
    const local = makeLocalModel({
      id: 'gpt-5.4',
      name: 'gpt-5.4 (manual)',
      capabilities: ['text', 'image'],
      priceTier: '',
      isManual: true,
    });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(resolveMock).toHaveBeenCalledWith('gpt-5.4', { transportPriority: 'openAI' });
    expect(enriched.id).toBe('gpt-5.4');
    expect(enriched.name).toBe('gpt-5.4 (manual)');
    expect(enriched.capabilities).toEqual(['text', 'image']);
    expect(enriched.canonicalModelId).toBe('gpt-5.4');
    expect(enriched.promptPrice).toBe(0.000002);
    expect(enriched.completionPrice).toBe(0.000008);
    expect(enriched.priceTier).not.toBe('');
  });

  it('still takes the manual path for the legacy relay-manual- prefix format, keeping user fields', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text', 'image', 'file', 'web', 'reasoning'],
        pricingStatus: 'priced',
        pricing: { promptPerToken: 0.000002, completionPerToken: 0.000008 },
      }),
    });
    const local = makeLocalModel({
      id: 'relay-manual-gpt-5.4',
      name: 'gpt-5.4 (manual legacy)',
      capabilities: ['text', 'image'],
      priceTier: '',
    });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(enriched.name).toBe('gpt-5.4 (manual legacy)');
    expect(enriched.capabilities).toEqual(['text', 'image']);
    expect(enriched.canonicalModelId).toBe('gpt-5.4');
  });

  it('maps the official provider priority from the Relay transport instead of passing the transport key through', () => {
    resolveMock.mockReturnValue(null);

    enrichRelayLocalModel(makeLocalModel({ id: 'claude-sonnet-4.5' }), 'anthropic_messages', DEFAULT_RELAY_RUNTIME_CONFIG);
    enrichRelayLocalModel(makeLocalModel({ id: 'gemini-2.5-pro' }), 'gemini_generate_content', DEFAULT_RELAY_RUNTIME_CONFIG);
    enrichRelayLocalModel(makeLocalModel({ id: 'gpt-5.4' }), 'openai_chat_completions', DEFAULT_RELAY_RUNTIME_CONFIG);
    enrichRelayLocalModel(makeLocalModel({ id: 'custom-model' }), undefined, DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(resolveMock).toHaveBeenNthCalledWith(1, 'claude-sonnet-4.5', { transportPriority: 'anthropic' });
    expect(resolveMock).toHaveBeenNthCalledWith(2, 'gemini-2.5-pro', { transportPriority: 'gemini' });
    expect(resolveMock).toHaveBeenNthCalledWith(3, 'gpt-5.4', { transportPriority: 'openAI' });
    expect(resolveMock).toHaveBeenNthCalledWith(4, 'custom-model', { transportPriority: null });
  });

  it('narrows capabilities when the transport envelope does not support web or imageGeneration', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text', 'image', 'file', 'web', 'imageGeneration', 'reasoning'],
        profiles: {
          reasoning: 'openaiReasoning',
          webSearch: 'openaiWebSearch',
          imageGen: 'openaiImageGen',
        },
      }),
    });
    const local = makeLocalModel({ id: 'gpt-5.4', capabilities: ['text'] });

    // openai_chat_completions defaults to web=false, imageGeneration=false, nativeFile=false
    const enriched = enrichRelayLocalModel(
      local,
      'openai_chat_completions',
      DEFAULT_RELAY_RUNTIME_CONFIG,
    );

    expect(enriched.capabilities).toEqual(
      expect.arrayContaining(['text', 'image', 'file', 'reasoning']),
    );
    expect(enriched.capabilities).not.toContain('web');
    expect(enriched.capabilities).not.toContain('imageGeneration');
    expect(enriched.webSearchProfile).toBeUndefined();
    expect(enriched.imageGenProfile).toBeUndefined();
    expect(enriched.reasoningProfile).toBe('openaiReasoning');
  });

  it('turns off purely official capabilities when the backend envelope disables imageGeneration', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-image-2',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-image-2',
        displayName: 'GPT Image 2',
        capabilities: ['imageGeneration'],
        profiles: { imageGen: 'openaiImageGen' },
      }),
    });
    const local = makeLocalModel({ id: 'gpt-image-2' });
    const runtimeConfig = {
      ...DEFAULT_RELAY_RUNTIME_CONFIG,
      transportEnvelopes: {
        ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes,
        openai_responses: {
          ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes.openai_responses,
          imageGeneration: false,
        },
      },
    };
    const enriched = enrichRelayLocalModel(local, 'openai_responses', runtimeConfig);
    expect(enriched.capabilities).not.toContain('imageGeneration');
    expect(enriched.imageGenProfile).toBeUndefined();
  });

  it('keeps a locally set manual model-level imageGeneration capability on a catalog match', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-image-2',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-image-2',
        displayName: 'GPT Image 2',
        capabilities: ['text'],
        profiles: { imageGen: 'openaiImageGen' },
      }),
    });
    const local = makeLocalModel({
      id: 'gpt-image-2',
      capabilities: ['text', 'imageGeneration'],
      imageGenProfile: 'localImageGen',
    });
    const runtimeConfig = {
      ...DEFAULT_RELAY_RUNTIME_CONFIG,
      transportEnvelopes: {
        ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes,
        openai_chat_completions: {
          ...DEFAULT_RELAY_RUNTIME_CONFIG.transportEnvelopes.openai_chat_completions,
          imageGeneration: false,
        },
      },
    };

    const enriched = enrichRelayLocalModel(local, 'openai_chat_completions', runtimeConfig);

    expect(enriched.capabilities).toEqual(['text', 'imageGeneration']);
    expect(enriched.imageGenProfile).toBe('openaiImageGen');
  });

  it('clears a stale local profile when the catalog matches but metadata has dropped the imageGen profile', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-image-2',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-image-2',
        displayName: 'GPT Image 2',
        capabilities: ['text'],
        profiles: {},
      }),
    });
    const local = makeLocalModel({
      id: 'gpt-image-2',
      capabilities: ['text', 'imageGeneration'],
      imageGenProfile: 'staleLocalImageGen',
    });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(enriched.capabilities).toEqual(['text', 'imageGeneration']);
    expect(enriched.imageGenProfile).toBeUndefined();
  });

  it('clears a stale local generationProfile when the catalog matches but metadata has dropped the generation profile', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text'],
        // `profiles.generation` is omitempty on the server, so the field disappears entirely when withdrawn
        profiles: {},
      }),
    });
    const local = makeLocalModel({
      id: 'gpt-5.4',
      capabilities: ['text'],
      generationProfile: { template: 'staleLocalGeneration' },
    });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(enriched.generationProfile).toBeUndefined();
  });

  it('keeps the local generationProfile when there is no official catalog match, since a pure relay model must not be cleared', () => {
    resolveMock.mockReturnValueOnce(null);
    const localGeneration = {
      template: 'userConfiguredGeneration',
      parameters: [{ id: 'temperature', support: 'supported', source: 'manual' }],
    };
    const local = makeLocalModel({
      id: 'my-custom-model',
      capabilities: ['text'],
      generationProfile: localGeneration,
    });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(enriched.generationProfile).toEqual(localGeneration);
    expect(enriched.relayMatchedProviderKind).toBeUndefined();
  });

  it('takes the official value when the catalog matches and metadata carries generation, overwriting the local one', () => {
    const officialGeneration = {
      template: 'openaiResponsesGeneration',
      parameters: [
        { id: 'temperature', support: 'supported', source: 'official' },
        { id: 'top_p', support: 'unsupported', source: 'official' },
      ],
    };
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text'],
        profiles: { generation: officialGeneration },
      }),
    });
    const local = makeLocalModel({
      id: 'gpt-5.4',
      capabilities: ['text'],
      generationProfile: { template: 'staleLocalGeneration' },
    });

    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(enriched.generationProfile).toEqual(officialGeneration);
  });

  it('all four profiles behave the same: on a match the official value wins, and anything the official side omits clears the local value', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'openAI',
      canonicalModelId: 'gpt-5.4',
      source: 'transport_first',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'gpt-5.4',
        displayName: 'GPT-5.4',
        capabilities: ['text', 'web', 'imageGeneration', 'reasoning'],
        // The official side only sends reasoning and webSearch, dropping imageGen and generation
        profiles: { reasoning: 'openaiReasoning', webSearch: 'openaiWebSearch' },
      }),
    });
    const local = makeLocalModel({
      id: 'gpt-5.4',
      capabilities: ['text'],
      reasoningProfile: 'staleLocalReasoning',
      webSearchProfile: 'staleLocalWebSearch',
      imageGenProfile: 'staleLocalImageGen',
      generationProfile: { template: 'staleLocalGeneration' },
    });

    // openai_responses has all four envelope entries enabled by default, so envelope narrowing does not interfere
    const enriched = enrichRelayLocalModel(local, 'openai_responses', DEFAULT_RELAY_RUNTIME_CONFIG);

    expect(enriched.reasoningProfile).toBe('openaiReasoning');
    expect(enriched.webSearchProfile).toBe('openaiWebSearch');
    expect(enriched.imageGenProfile).toBeUndefined();
    expect(enriched.generationProfile).toBeUndefined();
    expect(enriched.reasoningModeAvailable).toBe(true);
  });

  it('still matches when the transport is undefined, since a null envelope does not narrow', () => {
    resolveMock.mockReturnValueOnce({
      matchedProviderKind: 'anthropic',
      canonicalModelId: 'claude-sonnet-4.5',
      source: 'cross_provider',
      metadata: makeMatchedMetadata({
        canonicalModelId: 'claude-sonnet-4.5',
        displayName: 'Claude Sonnet 4.5',
        capabilities: ['text', 'image', 'file', 'reasoning'],
        profiles: { reasoning: 'anthropicReasoning' },
      }),
    });
    const local = makeLocalModel({ id: 'claude-sonnet-4.5', capabilities: ['text'] });
    const enriched = enrichRelayLocalModel(local, undefined, DEFAULT_RELAY_RUNTIME_CONFIG);
    expect(enriched.capabilities).toEqual(['text', 'image', 'file', 'reasoning']);
    expect(enriched.relayMatchedProviderKind).toBe('anthropic');
    expect(enriched.relayMatchSource).toBe('cross_provider');
  });
});

describe('enrichRelayCatalog', () => {
  it('enriches each entry and preserves order', () => {
    resolveMock.mockImplementation((modelId: string) => {
      if (modelId === 'gpt-5.4') {
        return {
          matchedProviderKind: 'openAI',
          canonicalModelId: 'gpt-5.4',
          source: 'transport_first',
          metadata: makeMatchedMetadata({
            canonicalModelId: 'gpt-5.4',
            displayName: 'GPT-5.4',
            capabilities: ['text', 'image'],
          }),
        };
      }
      return null;
    });

    const localModels = [
      makeLocalModel({ id: 'my-custom-model' }),
      makeLocalModel({ id: 'gpt-5.4' }),
    ];
    const enriched = enrichRelayCatalog(
      localModels,
      'openai_responses',
      DEFAULT_RELAY_RUNTIME_CONFIG,
    );

    expect(enriched).toHaveLength(2);
    expect(enriched[0].id).toBe('my-custom-model');
    expect(enriched[0].relayMatchedProviderKind).toBeUndefined();
    expect(enriched[1].id).toBe('gpt-5.4');
    expect(enriched[1].relayMatchedProviderKind).toBe('openAI');
    expect(enriched[1].name).toBe('GPT-5.4');
  });
});
