/**
 * Unit tests for the buildOfficialEnabledModels signature.
 *
 * Covers the 8-state Manual-Retained truth table:
 *   1. Importing an older backup: prevEnabledIds holds a dated id that maps to the canonical one
 *   2. A user default given as an alias: prevDefaultModelId=alias maps to the canonical id
 *   3. A user default dropped from metadata: falls back to providers[kind].defaultModelId
 *   4. Empty metadata: safe degradation returns an empty catalog
 *   5. Metadata hit plus a locally enabled model: rendered from the metadata fields (rows #1/#2)
 *   6. Metadata miss plus a locally enabled model with the flag on: pruned once (row #5)
 *   7. An alias resolving to a canonical id (row #8): remapped, and the local id becomes canonical
 */

import { describe, expect, it } from 'vitest';
import { buildOfficialEnabledModels } from '../official-model-sync';
import type { CatalogMetadataInput } from '../catalog-resolver';

const metadata: CatalogMetadataInput = {
  providers: {
    qwen: {
      defaultModelId: 'qwen3.6-plus',
      models: {
        'qwen3.6-plus': {
          canonicalModelId: 'qwen3.6-plus',
          aliases: ['qwen3.6-plus-2026-04-02'],
          displayName: 'Qwen 3.6 Plus',
          capabilities: ['text', 'reasoning'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 1, completionPerMToken: 3 },
          uiHints: { rank: 100, recommended: true },
        },
        'qwen3-max': {
          canonicalModelId: 'qwen3-max',
          displayName: 'Qwen 3 Max',
          capabilities: ['text'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 2, completionPerMToken: 6 },
        },
        'qwen-turbo': {
          canonicalModelId: 'qwen-turbo',
          displayName: 'Qwen Turbo',
          capabilities: ['text'],
          pricingStatus: 'free',
        },
      },
    },
  },
};

describe('buildOfficialEnabledModels (new signature)', () => {
  it('returns only the initial default enabled model with metadata-derived fields', () => {
    const result = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: [],
    });

    expect(result.catalogModels).toEqual([]);
    expect(result.models.map((m) => m.id)).toEqual(['qwen3.6-plus']);
    const qwen36 = result.models.find((m) => m.id === 'qwen3.6-plus');
    expect(qwen36?.name).toBe('Qwen 3.6 Plus');
    expect(qwen36?.capabilities).toContain('reasoning');
  });

  it('preserves preferredDefaultId (canonical) for new provider', () => {
    const result = buildOfficialEnabledModels('qwen', metadata, {
      preferredDefaultId: 'qwen3-max',
    });

    expect(result.defaultModelId).toBe('qwen3-max');
    expect(result.models.find((m) => m.id === 'qwen3-max')?.isDefault).toBe(true);
  });

  it('resolves alias → canonical for previous default model', () => {
    // Truth table #8: the alias resolves to a canonical id, so it is remapped
    const result = buildOfficialEnabledModels('qwen', metadata, {
      prevDefaultModelId: 'qwen3.6-plus-2026-04-02',
    });

    expect(result.defaultModelId).toBe('qwen3.6-plus');
  });

  it('resolves old backup prevEnabledIds (dated id) to canonical', () => {
    const result = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus-2026-04-02', 'qwen-turbo'],
    });

    // The dated id maps to the canonical one and the local id is updated asynchronously
    expect(result.models.some((m) => m.id === 'qwen3.6-plus')).toBe(true);
    expect(result.models.some((m) => m.id === 'qwen3.6-plus-2026-04-02')).toBe(false);
  });

  it('falls back to providers[kind].defaultModelId when prev default is unresolvable', () => {
    const result = buildOfficialEnabledModels('qwen', metadata, {
      prevDefaultModelId: 'non-existent-model',
    });

    expect(result.defaultModelId).toBe('qwen3.6-plus');
  });

  it('falls back to first canonical when metadata has no default and prev is unresolvable', () => {
    const metaNoDefault: CatalogMetadataInput = {
      providers: {
        qwen: { models: metadata.providers.qwen.models },
      },
    };
    const result = buildOfficialEnabledModels('qwen', metaNoDefault, {
      prevDefaultModelId: 'xxx',
    });

    expect(result.defaultModelId).toBeDefined();
    expect(
      Object.keys(metadata.providers.qwen.models).includes(result.defaultModelId),
    ).toBe(true);
  });

  it('returns empty catalog when metadata has no provider entry (safe degradation)', () => {
    const result = buildOfficialEnabledModels('qwen', { providers: {} }, {
      prevEnabledIds: ['qwen3.6-plus'],
    });

    expect(result.models).toEqual([]);
    expect(result.catalogModels).toEqual([]);
    expect(result.defaultModelId).toBe('');
  });

  it('prunes Manual-Retained models on flag on (truth table #5)', () => {
    // The local state holds a model that metadata does not know about
    const result = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus', 'deprecated-model-x'],
      prevDefaultModelId: 'deprecated-model-x',
    });

    // deprecated-model-x is not in the output
    expect(result.models.some((m) => m.id === 'deprecated-model-x')).toBe(false);
    // default falls back to providers[kind].defaultModelId
    expect(result.defaultModelId).toBe('qwen3.6-plus');
  });

  it('truth table #3: metadata hit but not locally enabled → visible, enableable', () => {
    const result = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: [], // the user enabled no models
    });

    // First registration enables only the initial default model; the other canonical models stay in the metadata catalog for the user to enable
    expect(result.models.map((m) => m.id)).toEqual(['qwen3.6-plus']);
  });
});
