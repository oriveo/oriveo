import { describe, expect, it } from 'vitest';
import type { AIModel, ProviderKind } from '@oriveo/shared';
import {
  resolveProviderCatalog,
  resolveDefaultModel,
  type CatalogMetadataInput,
  type CatalogProviderMetadata,
  type ResolvedModel,
} from '../catalog-resolver';

/* ── Test helpers ────────────────────────────────── */

function makeModel(overrides: Partial<AIModel> & { id: string }): AIModel {
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

function makeProvider(overrides: {
  kind?: ProviderKind;
  models?: AIModel[];
  catalogModels?: AIModel[];
  authMode?: 'apiKey' | 'subscription';
}) {
  return {
    kind: overrides.kind ?? 'openAI' as ProviderKind,
    models: overrides.models ?? [],
    catalogModels: overrides.catalogModels ?? [],
    ...(overrides.authMode ? { authMode: overrides.authMode } : {}),
  };
}

function makeMetadata(
  providers: Record<string, CatalogProviderMetadata>,
): CatalogMetadataInput {
  return { providers };
}

/* ── Test cases ──────────────────────────────────── */

describe('resolveProviderCatalog - subscription instances', () => {
  // The official catalog and the subscription catalog do not overlap at all: the Codex backend is
  // the gpt-5.x family and the Grok CLI proxy only accepts grok-4.6/4.5, while the official catalog
  // holds gpt-4o/o3 and grok-4.3. Building the model library from official metadata would list
  // models that do not exist on this path, so every model the user adds fails.
  const officialMetadata = makeMetadata({
    openAI: {
      models: {
        'gpt-4o': { id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'] },
        o3: { id: 'o3', name: 'o3', capabilities: ['text'] },
      },
    } as unknown as CatalogProviderMetadata,
  });

  it('the catalog comes from what the subscription path just fetched, with no official catalog model in it', () => {
    const provider = makeProvider({
      kind: 'openAI',
      authMode: 'subscription',
      models: [makeModel({ id: 'gpt-5.6-sol', isDefault: true }), makeModel({ id: 'gpt-5.5' })],
    });

    const result = resolveProviderCatalog(provider, officialMetadata);

    expect(result.catalog.map((model) => model.id)).toEqual(['gpt-5.6-sol', 'gpt-5.5']);
    expect(result.catalog.some((model) => model.id === 'gpt-4o')).toBe(false);
    expect(result.availableModelCount).toBe(2);
  });

  it('every model in the subscription catalog is enabled and none is mislabelled as manual', () => {
    // On the official branch they would be marked isManual for being absent from metadata, and shown as user-entered in the model library.
    const provider = makeProvider({
      kind: 'openAI',
      authMode: 'subscription',
      models: [makeModel({ id: 'gpt-5.6-sol', isDefault: true })],
    });

    const result = resolveProviderCatalog(provider, officialMetadata);

    expect(result.enabledModels.map((model) => model.id)).toEqual(['gpt-5.6-sol']);
    expect(result.hasManualModels).toBe(false);
    expect(result.defaultModel?.id).toBe('gpt-5.6-sol');
  });

  it('the same provider kind still uses official metadata as its catalog source in API key mode', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [makeModel({ id: 'gpt-4o' })],
    });

    const result = resolveProviderCatalog(provider, officialMetadata);

    expect(result.catalog.map((model) => model.id).sort()).toEqual(['gpt-4o', 'o3']);
  });
});

describe('resolveProviderCatalog', () => {
  it('official provider - metadata is the catalog source (3 models in metadata, 1 enabled)', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [makeModel({ id: 'gpt-4o' })],
    });

    const metadata = makeMetadata({
      openAI: {
        defaultModelId: 'gpt-4o',
        models: {
          'gpt-4o': {
            displayName: 'GPT-4o',
            capabilities: ['text', 'image'],
            toolCall: true,
            uiHints: { rank: 100 },
          },
          'gpt-4o-mini': {
            displayName: 'GPT-4o mini',
            capabilities: ['text'],
            uiHints: { rank: 80, recommended: true },
          },
          'o4-mini': {
            displayName: 'o4-mini',
            capabilities: ['text', 'reasoning'],
            uiHints: { rank: 90, recommended: true },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    expect(result.catalog).toHaveLength(3);
    expect(result.enabledModels).toHaveLength(1);
    expect(result.enabledModels[0].id).toBe('gpt-4o');
    expect(result.enabledModels[0].isEnabled).toBe(true);
    expect(result.enabledModels[0].isManual).toBe(false);
    expect(result.enabledModels[0].name).toBe('GPT-4o');
    expect(result.enabledModels[0].toolCall).toBe(true);
    expect(result.availableModelCount).toBe(3);
    expect(result.hasManualModels).toBe(false);
  });

  it('a v2 catalog hit covers true / false / null and clears the previous local verdict', () => {
    const provider = makeProvider({
      models: [
        makeModel({ id: 'true-model', toolCall: false, libraryAgentic: false }),
        makeModel({ id: 'false-model', toolCall: true, libraryAgentic: true }),
        makeModel({ id: 'unknown-model', toolCall: true, libraryAgentic: true }),
      ],
    });
    const metadata: CatalogMetadataInput = {
      capabilityContractVersion: 2,
      providers: {
        openAI: {
          models: {
            'true-model': { toolCall: true, libraryAgentic: true },
            'false-model': { toolCall: false, libraryAgentic: false },
            'unknown-model': { toolCall: null, libraryAgentic: null },
          },
        },
      },
    };

    const byID = new Map(
      resolveProviderCatalog(provider, metadata).enabledModels
        .map((model) => [model.id, model]),
    );
    expect(byID.get('true-model')).toMatchObject({ toolCall: true, libraryAgentic: true });
    expect(byID.get('false-model')).toMatchObject({ toolCall: false, libraryAgentic: false });
    expect(byID.get('unknown-model')).toMatchObject({ toolCall: null, libraryAgentic: null });
  });

  it('a v1 or capability-less catalog hit keeps the previous verdict when the field is missing', () => {
    const provider = makeProvider({
      models: [makeModel({ id: 'legacy-model', toolCall: true, libraryAgentic: false })],
    });
    const result = resolveProviderCatalog(provider, makeMetadata({
      openAI: { models: { 'legacy-model': { displayName: 'Legacy' } } },
    }));

    expect(result.enabledModels[0]).toMatchObject({
      toolCall: true,
      libraryAgentic: false,
    });
  });

  it('projects already decoded metadata evidence onto the catalog AIModel unchanged', () => {
    const result = resolveProviderCatalog(makeProvider({ kind: 'openAI' }), {
      providers: {
        openAI: {
          models: {
            'gpt-evidence': {
              canonicalModelId: 'gpt-evidence',
              transport: 'openai_responses',
              profiles: {
                generation: {
                  template: 'openai_responses',
                  revision: 'sha256:profile-r1',
                  parameters: [{
                    id: 'max_output_tokens',
                    support: 'supported',
                    source: 'authoritative_metadata',
                  }],
                },
              },
              capabilityEvidenceCandidates: [{
                key: 'tool_call',
                support: 'supported',
                source: 'server_typed',
                grade: 'machine_verified',
                scope: 'provider_model_transport',
                providerKind: 'openAI',
                modelId: 'gpt-evidence',
                transport: 'openai_responses',
                metadataRevision: 'etag-current',
                evidenceRevision: 'evidence-r1',
              }],
              metadataRevision: 'etag-current',
            },
          },
        },
      },
    });

    expect(result.catalog[0]).toMatchObject({
      id: 'gpt-evidence',
      metadataRevision: 'etag-current',
      generationProfile: {
        template: 'openai_responses',
        revision: 'sha256:profile-r1',
      },
      capabilityEvidenceCandidates: [expect.objectContaining({
        key: 'tool_call',
        evidenceRevision: 'evidence-r1',
      })],
    });
  });

  it('a catalog miss keeps the local tri-state value but still marks the model as manual', () => {
    const provider = makeProvider({
      models: [makeModel({ id: 'future-model', toolCall: true, libraryAgentic: null })],
    });
    const result = resolveProviderCatalog(provider, {
      capabilityContractVersion: 2,
      providers: { openAI: { models: {} } },
    });

    expect(result.enabledModels[0]).toMatchObject({
      id: 'future-model',
      isManual: true,
      toolCall: true,
      libraryAgentic: null,
    });
  });

  it('Relay - uses the local catalogModels and ignores metadata', () => {
    const localModels = [
      makeModel({ id: 'custom-gpt', name: 'Custom GPT' }),
      makeModel({ id: 'custom-llama', name: 'Custom Llama' }),
    ];

    const provider = makeProvider({
      kind: 'relay',
      models: [makeModel({ id: 'custom-gpt' })],
      catalogModels: localModels,
    });

    // Metadata carrying relay data is still not used
    const metadata = makeMetadata({
      relay: {
        models: {
          'should-not-use': { displayName: 'Should Not Use' },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    expect(result.catalog).toHaveLength(2);
    expect(result.enabledModels).toHaveLength(1);
    expect(result.enabledModels[0].id).toBe('custom-gpt');
    // Confirm that no model from metadata was used
    expect(result.catalog.find((m) => m.id === 'should-not-use')).toBeUndefined();
  });

  it('manual model - the user enabled a model outside the catalog (isManual: true)', () => {
    const provider = makeProvider({
      kind: 'anthropic',
      models: [
        makeModel({ id: 'claude-sonnet-4' }),
        makeModel({ id: 'my-custom-finetune' }),
      ],
    });

    const metadata = makeMetadata({
      anthropic: {
        models: {
          'claude-sonnet-4': {
            displayName: 'Claude Sonnet 4',
            capabilities: ['text', 'image'],
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    const manual = result.enabledModels.find((m) => m.id === 'my-custom-finetune');
    expect(manual).toBeDefined();
    expect(manual!.isManual).toBe(true);
    expect(manual!.isEnabled).toBe(true);

    const official = result.enabledModels.find((m) => m.id === 'claude-sonnet-4');
    expect(official).toBeDefined();
    expect(official!.isManual).toBe(false);

    expect(result.hasManualModels).toBe(true);
  });

  it('a manual model that later appears in metadata picks up its metadata and becomes isManual: false', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel({ id: 'new-model', name: 'Fallback Name' }),
      ],
    });

    // new-model now appears in metadata
    const metadata = makeMetadata({
      openAI: {
        models: {
          'new-model': {
            displayName: 'New Model (Official)',
            capabilities: ['text', 'reasoning'],
            uiHints: { rank: 95 },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    expect(result.enabledModels).toHaveLength(1);
    const model = result.enabledModels[0];
    expect(model.isManual).toBe(false);
    expect(model.name).toBe('New Model (Official)');
    expect(model.capabilities).toContain('reasoning');
    expect(model.sortRank).toBe(95);
  });

  it('a model dropped from metadata turns an enabled model into isManual: true', () => {
    const provider = makeProvider({
      kind: 'gemini',
      models: [
        makeModel({ id: 'gemini-1.5-pro', name: 'Gemini 1.5 Pro' }),
        makeModel({ id: 'gemini-2.0-flash' }),
      ],
    });

    // Metadata only has gemini-2.0-flash; gemini-1.5-pro is gone
    const metadata = makeMetadata({
      gemini: {
        models: {
          'gemini-2.0-flash': {
            displayName: 'Gemini 2.0 Flash',
            capabilities: ['text'],
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    const removed = result.enabledModels.find((m) => m.id === 'gemini-1.5-pro');
    expect(removed).toBeDefined();
    expect(removed!.isManual).toBe(true);
    expect(removed!.isEnabled).toBe(true);
    expect(removed!.name).toBe('Gemini 1.5 Pro');

    const kept = result.enabledModels.find((m) => m.id === 'gemini-2.0-flash');
    expect(kept).toBeDefined();
    expect(kept!.isManual).toBe(false);

    expect(result.hasManualModels).toBe(true);
  });

  it('alias match - the user enabled an old ID, metadata matches through the alias, and no duplicate manual model appears', () => {
    const provider = makeProvider({
      kind: 'anthropic',
      models: [
        makeModel({ id: 'claude-3.5-sonnet' }),
      ],
    });

    const metadata = makeMetadata({
      anthropic: {
        models: {
          'claude-sonnet-4': {
            displayName: 'Claude Sonnet 4',
            canonicalModelId: 'claude-sonnet-4',
            aliases: ['claude-3.5-sonnet', 'claude-3-5-sonnet-latest'],
            capabilities: ['text', 'image'],
            uiHints: { rank: 95 },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    // Exactly one enabled model, keeping the old ID the user had
    expect(result.enabledModels).toHaveLength(1);
    expect(result.enabledModels[0].id).toBe('claude-3.5-sonnet');
    expect(result.enabledModels[0].isManual).toBe(false);
    expect(result.enabledModels[0].name).toBe('Claude Sonnet 4');

    // There should be no manual models
    expect(result.hasManualModels).toBe(false);

    // The catalog still holds 1 entry, not 2
    expect(result.catalog).toHaveLength(1);
  });

  it('metadata returns an empty catalog - defensive degradation shows only enabled models, as manual', () => {
    const provider = makeProvider({
      kind: 'groq',
      models: [
        makeModel({ id: 'llama-4-scout', name: 'Llama 4 Scout' }),
        makeModel({ id: 'mixtral-8x7b', name: 'Mixtral 8x7b' }),
      ],
    });

    // metadata is null
    const result = resolveProviderCatalog(provider, null);

    expect(result.catalog).toHaveLength(2);
    expect(result.enabledModels).toHaveLength(2);
    expect(result.enabledModels.every((m) => m.isManual)).toBe(true);
    expect(result.hasManualModels).toBe(true);
    expect(result.recommendedModels).toHaveLength(0);
  });

  it('metadata has the provider but an empty models list - the same defensive degradation', () => {
    const provider = makeProvider({
      kind: 'groq',
      models: [
        makeModel({ id: 'llama-4-scout', name: 'Llama 4 Scout' }),
      ],
    });

    const metadata = makeMetadata({
      groq: { models: {} },
    });

    const result = resolveProviderCatalog(provider, metadata);

    // With an empty metadata catalog the enabled model becomes manual
    expect(result.enabledModels).toHaveLength(1);
    expect(result.enabledModels[0].isManual).toBe(true);
    expect(result.hasManualModels).toBe(true);
  });

  it('zero enabled models - the catalog comes from metadata, enabledModels is empty and defaultModel is null', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [],
    });

    const metadata = makeMetadata({
      openAI: {
        defaultModelId: 'gpt-4o',
        models: {
          'gpt-4o': {
            displayName: 'GPT-4o',
            capabilities: ['text', 'image'],
            uiHints: { rank: 100 },
          },
          'gpt-4o-mini': {
            displayName: 'GPT-4o mini',
            capabilities: ['text'],
            uiHints: { rank: 80 },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    expect(result.catalog).toHaveLength(2);
    expect(result.enabledModels).toHaveLength(0);
    expect(result.defaultModel).toBeNull();
    expect(result.hasManualModels).toBe(false);
  });

  it('recommended models - isRecommended && !isEnabled, ordered by sortRank descending', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [makeModel({ id: 'gpt-4o' })],
    });

    const metadata = makeMetadata({
      openAI: {
        models: {
          'gpt-4o': {
            displayName: 'GPT-4o',
            uiHints: { rank: 100, recommended: true },
          },
          'o4-mini': {
            displayName: 'o4-mini',
            uiHints: { rank: 90, recommended: true },
          },
          'gpt-4.1': {
            displayName: 'GPT-4.1',
            uiHints: { rank: 95, recommended: true },
          },
          'gpt-4o-mini': {
            displayName: 'GPT-4o mini',
            uiHints: { rank: 70 },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    // gpt-4o is already enabled, so it is not in the recommended list
    expect(result.recommendedModels.find((m) => m.id === 'gpt-4o')).toBeUndefined();

    // The remaining recommended models are ordered by rank descending
    expect(result.recommendedModels).toHaveLength(2);
    expect(result.recommendedModels[0].id).toBe('gpt-4.1'); // rank 95
    expect(result.recommendedModels[1].id).toBe('o4-mini');  // rank 90

    // gpt-4o-mini is not recommended, so it is not in the list
    expect(result.recommendedModels.find((m) => m.id === 'gpt-4o-mini')).toBeUndefined();
  });

  it('recommended model ordering - equal rank falls back to createdAt descending, then to name', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [],
    });

    const metadata = makeMetadata({
      openAI: {
        models: {
          'model-a': {
            displayName: 'Alpha',
            uiHints: { rank: 80, recommended: true },
          },
          'model-b': {
            displayName: 'Beta',
            uiHints: { rank: 80, recommended: true },
          },
          'model-c': {
            displayName: 'Charlie',
            uiHints: { rank: 80, recommended: true },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    // Equal rank and both createdAt undefined (treated as 0), so the order is alphabetical by name
    expect(result.recommendedModels.map((m) => m.name)).toEqual([
      'Alpha', 'Beta', 'Charlie',
    ]);
  });
});

describe('resolveDefaultModel', () => {
  it('prefers the isDefault flag set by the user', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel({ id: 'gpt-4o', isDefault: true }),
        makeModel({ id: 'o4-mini' }),
      ],
    });

    const enabledModels: ResolvedModel[] = [
      { ...makeModel({ id: 'gpt-4o', isDefault: true }), isEnabled: true, isManual: false },
      { ...makeModel({ id: 'o4-mini' }), isEnabled: true, isManual: false },
    ];

    const meta: CatalogProviderMetadata = {
      defaultModelId: 'o4-mini',
      models: {},
    };

    const result = resolveDefaultModel(provider, enabledModels, meta);
    expect(result?.id).toBe('gpt-4o');
  });

  it('uses metadata defaultModelId when the user set no isDefault', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel({ id: 'gpt-4o' }),
        makeModel({ id: 'o4-mini' }),
      ],
    });

    const enabledModels: ResolvedModel[] = [
      { ...makeModel({ id: 'gpt-4o' }), isEnabled: true, isManual: false },
      { ...makeModel({ id: 'o4-mini' }), isEnabled: true, isManual: false },
    ];

    const meta: CatalogProviderMetadata = {
      defaultModelId: 'o4-mini',
      models: {},
    };

    const result = resolveDefaultModel(provider, enabledModels, meta);
    expect(result?.id).toBe('o4-mini');
  });

  it('falls back to metadata defaultModelId when the isDefault model is not in the enabled list', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel({ id: 'removed-model', isDefault: true }),
        makeModel({ id: 'o4-mini' }),
      ],
    });

    // removed-model is absent from enabledModels, so it may have been filtered out
    const enabledModels: ResolvedModel[] = [
      { ...makeModel({ id: 'o4-mini' }), isEnabled: true, isManual: false },
    ];

    const meta: CatalogProviderMetadata = {
      defaultModelId: 'o4-mini',
      models: {},
    };

    const result = resolveDefaultModel(provider, enabledModels, meta);
    expect(result?.id).toBe('o4-mini');
  });

  it('uses the first enabled model when metadata defaultModelId is not in the enabled list either', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel({ id: 'gpt-4o' }),
        makeModel({ id: 'o4-mini' }),
      ],
    });

    const enabledModels: ResolvedModel[] = [
      { ...makeModel({ id: 'gpt-4o' }), isEnabled: true, isManual: false },
      { ...makeModel({ id: 'o4-mini' }), isEnabled: true, isManual: false },
    ];

    const meta: CatalogProviderMetadata = {
      defaultModelId: 'nonexistent-model',
      models: {},
    };

    const result = resolveDefaultModel(provider, enabledModels, meta);
    expect(result?.id).toBe('gpt-4o');
  });

  it('uses the first enabled model when there is no metadata', () => {
    const provider = makeProvider({
      kind: 'relay',
      models: [
        makeModel({ id: 'custom-model' }),
      ],
    });

    const enabledModels: ResolvedModel[] = [
      { ...makeModel({ id: 'custom-model' }), isEnabled: true, isManual: false },
    ];

    const result = resolveDefaultModel(provider, enabledModels, null);
    expect(result?.id).toBe('custom-model');
  });

  it('returns null when enabledModels is empty', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [],
    });

    const result = resolveDefaultModel(provider, [], null);
    expect(result).toBeNull();
  });

  it('matches metadata defaultModelId through canonicalModelId', () => {
    const provider = makeProvider({
      kind: 'anthropic',
      models: [
        makeModel({ id: 'claude-3.5-sonnet', canonicalModelId: 'claude-sonnet-4' }),
      ],
    });

    const enabledModels: ResolvedModel[] = [
      {
        ...makeModel({ id: 'claude-3.5-sonnet', canonicalModelId: 'claude-sonnet-4' }),
        isEnabled: true,
        isManual: false,
      },
    ];

    const meta: CatalogProviderMetadata = {
      defaultModelId: 'claude-sonnet-4',
      models: {},
    };

    const result = resolveDefaultModel(provider, enabledModels, meta);
    expect(result?.id).toBe('claude-3.5-sonnet');
  });
});

describe('resolveProviderCatalog — metadata enrichment', () => {
  it('inherits full model information from metadata (displayName / capabilities / pricing / profiles)', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [makeModel({ id: 'o4-mini' })],
    });

    const metadata = makeMetadata({
      openAI: {
        defaultModelId: 'o4-mini',
        models: {
          'o4-mini': {
            displayName: 'o4-mini',
            canonicalModelId: 'o4-mini',
            contextLength: 200000,
            capabilities: ['text', 'image', 'reasoning'],
            pricing: {
              promptPerMToken: 1.1,
              completionPerMToken: 4.4,
            },
            profiles: {
              reasoning: 'oai_responses',
              webSearch: null,
              imageGen: null,
            },
            uiHints: {
              groupKey: 'o-series',
              groupName: 'o Series',
              rank: 90,
              recommended: true,
              badgeOrder: ['reasoning', 'image'],
            },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);
    const model = result.enabledModels[0];

    expect(model.name).toBe('o4-mini');
    expect(model.canonicalModelId).toBe('o4-mini');
    expect(model.capabilities).toContain('reasoning');
    expect(model.capabilities).toContain('image');
    expect(model.contextLength).toBe(200000);
    expect(model.promptPrice).toBeCloseTo(1.1 / 1_000_000);
    expect(model.completionPrice).toBeCloseTo(4.4 / 1_000_000);
    expect(model.reasoningProfile).toBe('oai_responses');
    expect(model.webSearchProfile).toBeUndefined();
    expect(model.groupKey).toBe('o-series');
    expect(model.groupName).toBe('o Series');
    expect(model.sortRank).toBe(90);
    expect(model.isDefault).toBe(true);
  });

  it('OpenRouter metadata web profile is preserved for enabled models', () => {
    const provider = makeProvider({
      kind: 'openRouter',
      models: [makeModel({ id: 'anthropic/claude-sonnet-4' })],
    });

    const metadata = makeMetadata({
      openRouter: {
        defaultModelId: 'anthropic/claude-sonnet-4',
        models: {
          'anthropic/claude-sonnet-4': {
            displayName: 'Claude Sonnet 4',
            capabilities: ['text', 'file', 'web'],
            profiles: { webSearch: 'or_web' },
            uiHints: { badgeOrder: ['file', 'web'] },
          },
        },
      },
    });

    const model = resolveProviderCatalog(provider, metadata).enabledModels[0];

    expect(model.capabilities).toContain('web');
    expect(model.webSearchProfile).toBe('or_web');
    expect(model.badgeOrder).toEqual(['file', 'web']);
  });

  it('defaultModel resolves correctly through resolveProviderCatalog', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [
        makeModel({ id: 'gpt-4o', isDefault: true }),
        makeModel({ id: 'o4-mini' }),
      ],
    });

    const metadata = makeMetadata({
      openAI: {
        defaultModelId: 'o4-mini',
        models: {
          'gpt-4o': { displayName: 'GPT-4o' },
          'o4-mini': { displayName: 'o4-mini' },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);

    // The setting made by the user takes priority
    expect(result.defaultModel?.id).toBe('gpt-4o');
  });

  it('non-token billed models do not fall back to a 0 token price and show Non-standard billing', () => {
    const provider = makeProvider({
      kind: 'openAI',
      models: [makeModel({ id: 'gpt-image-1' })],
    });

    const metadata = makeMetadata({
      openAI: {
        models: {
          'gpt-image-1': {
            displayName: 'GPT Image 1',
            pricingUnit: 'per_image',
            pricingStatus: 'priced',
            pricing: {
              promptPerMToken: null,
              completionPerMToken: null,
              costPerUnit: 0.04,
            },
          },
        },
      },
    });

    const result = resolveProviderCatalog(provider, metadata);
    const model = result.enabledModels[0];

    expect(model.priceTier).toBe('Non-standard billing');
    expect(model.promptPrice).toBeUndefined();
    expect(model.completionPrice).toBeUndefined();
  });
});
