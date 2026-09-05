import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../metadata/metadata-client', () => ({
  resolveCatalogModel: vi.fn(),
}));

import { resolveCatalogModel } from '../metadata/metadata-client';
import { buildCatalogModel, enrichStoredModel } from './catalog-model';

const mockResolveCatalogModel = vi.mocked(resolveCatalogModel);

describe('buildCatalogModel', () => {
  beforeEach(() => {
    mockResolveCatalogModel.mockReset();
  });

  it('returns no group hints when metadata is missing (slug-based vendor fallback removed)', () => {
    mockResolveCatalogModel.mockReturnValue(null);

    const model = buildCatalogModel({
      providerKind: 'openRouter',
      runtimeModelId: 'nvidia/llama-3.1-nemotron-ultra',
      fallbackName: 'llama-3.1-nemotron-ultra',
      createdAt: 1234,
    });

    // Presentation contract: the vendor of an aggregate provider must come from the catalog, with no
    // fallback to parsing the model id slug.
    expect(model.id).toBe('nvidia/llama-3.1-nemotron-ultra');
    expect(model.groupKey).toBeUndefined();
    expect(model.groupName).toBeUndefined();
    expect(model.createdAt).toBe(1234);
  });

  it('keeps non-OpenRouter models ungrouped when metadata is missing', () => {
    mockResolveCatalogModel.mockReturnValue(null);

    const model = buildCatalogModel({
      providerKind: 'openAI',
      runtimeModelId: 'gpt-4.1',
      fallbackName: 'GPT-4.1',
    });

    expect(model.groupKey).toBeUndefined();
    expect(model.groupName).toBeUndefined();
  });

  it('falls back to completion pricing when prompt pricing is zero', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-5.4-nano',
      displayName: 'GPT-5.4 Nano',
      pricingStatus: 'priced',
      capabilities: ['text', 'image'],
      pricing: {
        promptPerToken: 0,
        completionPerToken: 0.00000125,
      },
      profiles: {},
      isDefault: false,
    });

    const model = buildCatalogModel({
      providerKind: 'openAI',
      runtimeModelId: 'gpt-5.4-nano',
      fallbackName: 'gpt-5.4-nano',
    });

    expect(model).toMatchObject({
      priceTier: '$1.25/M',
      promptPrice: 0,
      completionPrice: 0.00000125,
    });
  });

  it('backfills stale stored OpenRouter models with metadata rank and vendor', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'nvidia/llama-3.1-nemotron-ultra',
      displayName: 'Llama 3.1 Nemotron Ultra',
      pricingStatus: 'unknown',
      capabilities: ['text', 'reasoning'],
      pricing: null,
      profiles: { reasoning: 'oai_chat' },
      uiHints: {
        groupKey: 'nvidia',
        groupName: 'NVIDIA',
        rank: 166,
        recommended: true,
        badgeOrder: ['reasoning'],
      },
      isDefault: false,
    });

    const model = enrichStoredModel({
      id: 'nvidia/llama-3.1-nemotron-ultra',
      name: 'llama-3.1-nemotron-ultra',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      createdAt: 1234,
    }, 'openRouter');

    expect(model).toMatchObject({
      canonicalModelId: 'nvidia/llama-3.1-nemotron-ultra',
      name: 'Llama 3.1 Nemotron Ultra',
      groupKey: 'nvidia',
      groupName: 'NVIDIA',
      sortRank: 166,
      isRecommended: true,
      reasoningModeAvailable: true,
    });
  });

  it('clears a persisted capability verdict when the v2 catalog hit returns null', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-future',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      capabilityContractVersion: 2,
      toolCall: null,
      libraryAgentic: null,
      isDefault: false,
    });

    const enriched = enrichStoredModel({
      id: 'gpt-future',
      name: 'GPT Future',
      capabilities: ['text'],
      toolCall: true,
      libraryAgentic: true,
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
    }, 'openAI');

    expect(enriched.toolCall).toBeNull();
    expect(enriched.libraryAgentic).toBeNull();
  });

  it('passes safe evidence through on a catalog hit and clears a stale revision when the snapshot has no ETag', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-evidence',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      capabilityEvidenceCandidates: [{
        key: 'tool_call',
        support: 'supported',
        source: 'server_typed',
        grade: 'machine_verified',
        scope: 'provider_model_transport',
        providerKind: 'openAI',
        modelId: 'gpt-evidence',
        transport: 'openai_responses',
        metadataRevision: 'etag-new',
        evidenceRevision: 'evidence-r1',
      }],
      metadataRevision: undefined,
      isDefault: false,
    });

    const enriched = enrichStoredModel({
      id: 'gpt-evidence',
      name: 'GPT evidence',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      metadataRevision: 'etag-old',
      capabilityEvidenceCandidates: [{
        key: 'tool_call',
        support: 'unsupported',
        source: 'server_typed',
        grade: 'machine_verified',
        scope: 'provider_model_transport',
        providerKind: 'openAI',
        modelId: 'gpt-evidence',
        transport: 'openai_responses',
      }],
    }, 'openAI');

    expect(enriched.metadataRevision).toBeUndefined();
    expect(enriched.capabilityEvidenceCandidates).toEqual([
      expect.objectContaining({
        key: 'tool_call',
        support: 'supported',
        evidenceRevision: 'evidence-r1',
      }),
    ]);
  });

  it('keeps the stored value when a v1 catalog hit lacks the capability bit, and on a catalog miss too', () => {
    const stored = {
      id: 'gpt-legacy',
      name: 'GPT Legacy',
      capabilities: ['text'],
      toolCall: true,
      libraryAgentic: false,
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
    };
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-legacy',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      isDefault: false,
    });
    expect(enrichStoredModel(stored, 'openAI')).toMatchObject({
      toolCall: true,
      libraryAgentic: false,
    });

    mockResolveCatalogModel.mockReturnValue(null);
    expect(enrichStoredModel(stored, 'openAI')).toMatchObject({
      toolCall: true,
      libraryAgentic: false,
    });
  });

  it('clears stale remote price when metadata marks pricing unknown', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'nvidia/nemotron-3-super-120b-a12b:free',
      displayName: 'Nemotron 3 Super',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: {
        promptPerToken: 0,
        completionPerToken: 0,
      },
      profiles: {},
      isDefault: false,
    });

    const model = enrichStoredModel({
      id: 'nvidia/nemotron-3-super-120b-a12b:free',
      name: 'Nemotron 3 Super',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: 'Free',
    }, 'openRouter');

    expect(model).toMatchObject({
      priceTier: 'Price unknown',
      promptPrice: undefined,
      completionPrice: undefined,
    });
  });

  it('clears stale group metadata when latest metadata omits uiHints', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'openai/gpt-4o',
      displayName: 'GPT-4o',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      isDefault: false,
    });

    const model = enrichStoredModel({
      id: 'openai/gpt-4o',
      name: 'GPT-4o',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      groupKey: 'openai',
      groupName: 'OpenAI',
      sortRank: 120,
      badgeOrder: ['reasoning'],
      isRecommended: true,
    }, 'openRouter');

    expect(model).toMatchObject({
      groupKey: undefined,
      groupName: undefined,
      sortRank: undefined,
      badgeOrder: undefined,
      isRecommended: false,
    });
  });

  it('renders explicit free models as Free', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'meta-llama/llama-3.3-8b-instruct:free',
      displayName: 'Llama 3.3 8B Instruct',
      pricingStatus: 'free',
      capabilities: ['text'],
      pricing: {
        promptPerToken: 0,
        completionPerToken: 0,
      },
      profiles: {},
      isDefault: false,
    });

    const model = buildCatalogModel({
      providerKind: 'openRouter',
      runtimeModelId: 'meta-llama/llama-3.3-8b-instruct:free',
      fallbackName: 'llama-3.3-8b-instruct:free',
    });

    expect(model).toMatchObject({
      priceTier: 'Free',
      promptPrice: 0,
      completionPrice: 0,
    });
  });

  it('renders non-token priced models as Non-standard billing', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-image-1',
      displayName: 'GPT Image 1',
      pricingStatus: 'priced',
      pricingUnit: 'per_image',
      capabilities: ['text', 'imageGeneration'],
      pricing: {
        promptPerToken: null,
        completionPerToken: null,
        costPerUnit: 0.04,
      },
      profiles: {},
      isDefault: false,
    });

    const model = buildCatalogModel({
      providerKind: 'openAI',
      runtimeModelId: 'gpt-image-1',
      fallbackName: 'gpt-image-1',
    });

    expect(model).toMatchObject({
      priceTier: 'Non-standard billing',
      promptPrice: undefined,
      completionPrice: undefined,
    });
  });

  // ── Authoritative withdrawal vs catalog MISS ──
  //
  // The two look alike (both read as "the catalog gave me no profile") but mean the opposite. The test
  // is whether the catalog itself is present, not whether one profile field is. Getting it backwards
  // wipes the profiles of relay and hand-added models.

  it('clears stored profiles when the catalog still has the model but withdraws its profiles', () => {
    // How a narrowed level set or a withdrawn reasoning profile lands: the model is still in the catalog, profiles is empty.
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-5-pro',
      displayName: 'GPT-5 Pro',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      isDefault: false,
    });

    const model = enrichStoredModel({
      id: 'gpt-5-pro',
      name: 'GPT-5 Pro',
      capabilities: ['text', 'reasoning'],
      reasoningModeAvailable: true,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      reasoningProfile: 'oai_responses',
      webSearchProfile: 'oai_responses_web',
      imageGenProfile: 'oai_images',
      // generation follows the same rule as the other three: the server marks profiles.generation
      // omitempty, so the field simply disappears on withdrawal. A catalog hit must clear the stored
      // local value too, or the expert parameter entry and outbound injection keep feeding a withdrawn profile.
      generationProfile: { template: 'openai_chat_completions' },
    }, 'openAI');

    expect(model.reasoningProfile).toBeUndefined();
    expect(model.webSearchProfile).toBeUndefined();
    expect(model.imageGenProfile).toBeUndefined();
    expect(model.generationProfile).toBeUndefined();
    expect(model.reasoningModeAvailable).toBe(false);
  });

  it('adopts the catalog generation profile over the stored one on a catalog hit', () => {
    // The opposite of withdrawal: when the catalog still ships generation, the catalog wins (server authority, no merge, no keeping the old value).
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'gpt-5-pro',
      displayName: 'GPT-5 Pro',
      pricingStatus: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {
        generation: {
          template: 'openai_responses',
          revision: 'sha256:profile-current',
          parameters: [{ id: 'max_output_tokens', support: 'supported', source: 'authoritative_metadata' }],
        },
      },
      isDefault: false,
    });

    const model = enrichStoredModel({
      id: 'gpt-5-pro',
      name: 'GPT-5 Pro',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      generationProfile: { template: 'openai_chat_completions', parameters: [{ id: 'temperature' }] },
    }, 'openAI');

    expect(model.generationProfile).toEqual({
      template: 'openai_responses',
      revision: 'sha256:profile-current',
      parameters: [{ id: 'max_output_tokens', support: 'supported', source: 'authoritative_metadata' }],
    });
  });

  it('keeps stored profiles untouched when the catalog does not have the model at all', () => {
    // Hand-added or sync-backfilled models: a catalog MISS means "cannot tell", not "withdrawn".
    mockResolveCatalogModel.mockReturnValue(null);

    const model = enrichStoredModel({
      id: 'my-private-deployment',
      name: 'My Private Deployment',
      capabilities: ['text', 'reasoning'],
      reasoningModeAvailable: true,
      isAvailable: true,
      isDefault: false,
      priceTier: 'Free',
      reasoningProfile: 'oai_responses',
      webSearchProfile: 'oai_responses_web',
      imageGenProfile: 'oai_images',
      generationProfile: { template: 'openai_chat' },
    }, 'openAI');

    expect(model).toMatchObject({
      reasoningProfile: 'oai_responses',
      webSearchProfile: 'oai_responses_web',
      imageGenProfile: 'oai_images',
      generationProfile: { template: 'openai_chat' },
      reasoningModeAvailable: true,
      name: 'My Private Deployment',
      priceTier: 'Free',
    });
  });

  it('keeps relay model profiles because the backend catalog has no relay provider', () => {
    // relay's null is **derived**, not hand-written: the bundled catalog.providers map has no relay key
    // at all (neither the catalog build nor metadata-client's KIND_MAP defines one), so
    // resolveCatalogModel(<any id>, 'relay') is always null. A relay profile comes from the
    // relay-official-catalog-match sweep across official providers and has to survive enrich.
    const fakeCatalog: Record<string, Record<string, ReturnType<typeof mockResolveCatalogModel>>> = {
      openAI: {
        'gpt-5-pro': {
          canonicalModelId: 'gpt-5-pro',
          displayName: 'GPT-5 Pro',
          pricingStatus: 'unknown',
          capabilities: ['text'],
          pricing: null,
          profiles: {},
          isDefault: false,
        },
      },
    };
    mockResolveCatalogModel.mockImplementation(
      (modelId: string, providerKind: string) => fakeCatalog[providerKind]?.[modelId] ?? null,
    );

    const model = enrichStoredModel({
      id: 'gpt-5-pro',
      name: 'GPT-5 Pro (via relay)',
      capabilities: ['text', 'reasoning'],
      reasoningModeAvailable: true,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      reasoningProfile: 'oai_responses',
      webSearchProfile: 'oai_responses_web',
    }, 'relay');

    expect(model).toMatchObject({
      name: 'GPT-5 Pro (via relay)',
      reasoningProfile: 'oai_responses',
      webSearchProfile: 'oai_responses_web',
      reasoningModeAvailable: true,
    });
  });

  it('renders unknown pricing models as Price unknown', () => {
    mockResolveCatalogModel.mockReturnValue({
      canonicalModelId: 'glm-4.5-airx',
      displayName: 'GLM 4.5 AirX',
      pricingStatus: 'unknown',
      pricingUnit: 'unknown',
      capabilities: ['text'],
      pricing: null,
      profiles: {},
      isDefault: false,
    });

    const model = buildCatalogModel({
      providerKind: 'zhipu',
      runtimeModelId: 'glm-4.5-airx',
      fallbackName: 'glm-4.5-airx',
    });

    expect(model).toMatchObject({
      priceTier: 'Price unknown',
      promptPrice: undefined,
      completionPrice: undefined,
    });
  });
});
