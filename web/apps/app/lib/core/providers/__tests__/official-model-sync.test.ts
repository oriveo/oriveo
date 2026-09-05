import { describe, expect, it } from 'vitest';
import { buildOfficialEnabledModels } from '../official-model-sync';
import type { CatalogMetadataInput } from '../catalog-resolver';

const openAIMetadata: CatalogMetadataInput = {
  providers: {
    openAI: {
      defaultModelId: 'gpt-4.1',
      models: {
        'gpt-4o': {
          canonicalModelId: 'gpt-4o',
          displayName: 'GPT-4o',
          capabilities: ['text'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 2, completionPerMToken: 10 },
        },
        'gpt-4.1': {
          canonicalModelId: 'gpt-4.1',
          displayName: 'GPT-4.1',
          capabilities: ['text'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 3, completionPerMToken: 12 },
        },
        'gpt-4.1-mini': {
          canonicalModelId: 'gpt-4.1-mini',
          displayName: 'GPT-4.1 mini',
          capabilities: ['text'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 1, completionPerMToken: 4 },
        },
      },
    },
  },
};

describe('buildOfficialEnabledModels', () => {
  it('uses only the initial metadata default model for a new provider and preserves the preferred default model', () => {
    const result = buildOfficialEnabledModels('openAI', openAIMetadata, {
      preferredDefaultId: 'gpt-4o',
    });

    expect(result.models.map((m) => m.id)).toEqual(['gpt-4o']);
    expect(result.defaultModelId).toBe('gpt-4o');
    expect(result.catalogModels).toEqual([]);
  });
});
