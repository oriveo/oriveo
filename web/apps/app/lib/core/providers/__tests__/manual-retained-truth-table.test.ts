/**
 * Eight-state truth table for manual-retained models, pinning down resolver behavior.
 *
 * Covers how `buildOfficialEnabledModels` treats models the user has enabled locally:
 *   #1 metadata hit + enabled + flag off -> use the metadata fields
 *   #2 metadata hit + enabled + flag on -> same as #1; the flag only affects the miss branch
 *   #3 metadata hit + not enabled -> the canonical id appears in the catalog
 *   #4 metadata miss + enabled + flag off -> keep the local entry (pre-launch behavior)
 *   #5 metadata miss + enabled + flag on -> prune once and fall back to the default model
 *   #6 and #7 metadata miss + not enabled -> appears in no list
 *   #8 alias resolves to a canonical id + enabled -> remapped to the canonical id
 *
 * Pre-launch has `MANUAL_RETAINED_PRUNING_ENABLED = false`, so these tests force both branches
 * explicitly through `overrides.manualRetainedPruningEnabled`.
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
        },
        'qwen3-max': {
          canonicalModelId: 'qwen3-max',
          displayName: 'Qwen 3 Max',
          capabilities: ['text'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 2, completionPerMToken: 6 },
        },
      },
    },
  },
};

describe('Manual-Retained truth table (Web resolver)', () => {
  it('#1 metadata hit + enabled + flag off → uses metadata fields, not manualRetained', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus'],
    }, { manualRetainedPruningEnabled: false });

    const model = build.models.find((m) => m.id === 'qwen3.6-plus');
    expect(model?.name).toBe('Qwen 3.6 Plus');
    expect(build.prunedModelIds).toEqual([]);
  });

  it('#2 metadata hit + enabled + flag on → behaves identically to #1', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus'],
    }, { manualRetainedPruningEnabled: true });

    const model = build.models.find((m) => m.id === 'qwen3.6-plus');
    expect(model?.name).toBe('Qwen 3.6 Plus');
    expect(build.prunedModelIds).toEqual([]);
  });

  it('#3 metadata hit + not enabled → falls back to a single initial default enabled model', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: [],
    }, { manualRetainedPruningEnabled: false });

    expect(build.models.map((m) => m.id)).toEqual(['qwen3.6-plus']);
  });

  it('#5 metadata miss + enabled + flag on → pruned, default falls back to providers[kind].defaultModelId', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus', 'legacy-removed-model'],
      prevEnabledModels: [
        {
          id: 'qwen3.6-plus',
          name: 'Qwen 3.6 Plus',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
        {
          id: 'legacy-removed-model',
          name: 'Legacy Removed Model',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
      ],
      prevDefaultModelId: 'legacy-removed-model',
    }, { manualRetainedPruningEnabled: true });

    // Pruned, so it is gone from the enabled list...
    expect(build.models.some((m) => m.id === 'legacy-removed-model')).toBe(false);
    // Default fallback.
    expect(build.defaultModelId).toBe('qwen3.6-plus');
    // ...and reported by id, so the UI can say what disappeared instead of silently dropping it.
    expect(build.prunedModelIds).toEqual(['legacy-removed-model']);
  });

  it('#5 multiple misses → all reported in prunedModelIds', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus', 'legacy-a', 'legacy-b'],
    }, { manualRetainedPruningEnabled: true });

    expect(new Set(build.prunedModelIds)).toEqual(new Set(['legacy-a', 'legacy-b']));
  });

  it('#4 metadata miss + enabled + flag off → keeps the local manual-retained model', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus', 'legacy-removed-model'],
      prevEnabledModels: [
        {
          id: 'qwen3.6-plus',
          name: 'Qwen 3.6 Plus',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
        {
          id: 'legacy-removed-model',
          name: 'Legacy Removed Model',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
          groupKey: 'legacy',
          groupName: 'Legacy',
        },
      ],
      prevDefaultModelId: 'legacy-removed-model',
    }, { manualRetainedPruningEnabled: false });

    expect(build.models.map((m) => m.id)).toEqual(['qwen3.6-plus', 'legacy-removed-model']);
    expect(build.defaultModelId).toBe('legacy-removed-model');
    expect(build.prunedModelIds).toEqual([]);
  });

  it('#6/#7 metadata miss + not enabled → does not appear anywhere', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: [],
    }, { manualRetainedPruningEnabled: true });

    expect(build.models.some((m) => m.id === 'non-existent')).toBe(false);
    expect(build.prunedModelIds).toEqual([]);
  });

  it('#8 alias + enabled → remapped to canonical; aliasRemappings reports old → canonical mapping', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus-2026-04-02'],
    }, { manualRetainedPruningEnabled: false });

    // A dated id stored locally is remapped to the canonical id.
    expect(build.models.some((m) => m.id === 'qwen3.6-plus')).toBe(true);
    expect(build.models.some((m) => m.id === 'qwen3.6-plus-2026-04-02')).toBe(false);
    // Callers can see which old ids were merged through aliasRemappings.
    expect(build.aliasRemappings).toEqual({
      'qwen3.6-plus-2026-04-02': 'qwen3.6-plus',
    });
  });

  it('pre-launch default (flag off) keeps behavior identical when no misses', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus', 'qwen3-max'],
    }, { manualRetainedPruningEnabled: false });

    expect(build.prunedModelIds).toEqual([]);
    expect(build.aliasRemappings).toEqual({});
  });

  it('flag default (unset) → module constant MANUAL_RETAINED_PRUNING_ENABLED decides; miss is not pruned in pre-launch', async () => {
    // No override: the module constant decides, and it is false before launch.
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus', 'legacy'],
      prevEnabledModels: [
        {
          id: 'qwen3.6-plus',
          name: 'Qwen 3.6 Plus',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: true,
          priceTier: '',
        },
        {
          id: 'legacy',
          name: 'Legacy',
          capabilities: ['text'],
          reasoningModeAvailable: false,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
    });

    // Pre-launch does not prune misses, so manual-retained models stay in the enabled models.
    expect(build.models.map((m) => m.id)).toEqual(['qwen3.6-plus', 'legacy']);
    expect(build.prunedModelIds).toEqual([]);
  });
});
