/**
 * Contract tests for the merged official provider Setup, Resync and Backup Restore paths.
 *
 * They verify that:
 *   1. Setup: after registration the enabled models come from metadata (the resolved catalog),
 *      not from what adapter syncModels returned;
 *   2. Resync: once the metadata version grows, the catalog count refreshes even when the user's
 *      enabled models are unchanged;
 *   3. Qwen aliases: `qwen3.6-plus-2026-04-02` resolves to `qwen3.6-plus` after Setup and Resync.
 */

import { describe, expect, it } from 'vitest';
import { buildOfficialEnabledModels } from '../official-model-sync';
import type { CatalogMetadataInput } from '../catalog-resolver';

const qwenMetadataV1: CatalogMetadataInput = {
  providers: {
    qwen: {
      defaultModelId: 'qwen3.6-plus',
      models: {
        'qwen3.6-plus': {
          canonicalModelId: 'qwen3.6-plus',
          aliases: ['qwen3.6-plus-2026-04-02'],
          displayName: 'Qwen 3.6 Plus',
          capabilities: ['text'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 1, completionPerMToken: 3 },
        },
      },
    },
  },
};

const qwenMetadataV2: CatalogMetadataInput = {
  providers: {
    qwen: {
      defaultModelId: 'qwen3.6-plus',
      models: {
        'qwen3.6-plus': qwenMetadataV1.providers.qwen.models['qwen3.6-plus'],
        'qwen3.7-ultra': {
          canonicalModelId: 'qwen3.7-ultra',
          displayName: 'Qwen 3.7 Ultra',
          capabilities: ['text', 'reasoning'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 5, completionPerMToken: 15 },
        },
      },
    },
  },
};

const qwenMetadataV3: CatalogMetadataInput = {
  providers: {
    qwen: {
      defaultModelId: 'qwen3.6-plus',
      models: {
        ...qwenMetadataV2.providers.qwen.models,
        'qwen3.8-max': {
          canonicalModelId: 'qwen3.8-max',
          displayName: 'Qwen 3.8 Max',
          capabilities: ['text', 'reasoning'],
          pricingStatus: 'priced',
          pricing: { promptPerMToken: 8, completionPerMToken: 24 },
        },
      },
    },
  },
};

describe('official provider Setup path', () => {
  it('Setup: enabled models come from metadata full catalog, not adapter output', () => {
    const result = buildOfficialEnabledModels('qwen', qwenMetadataV1, {
      prevEnabledIds: [],
    });

    expect(result.models.length).toBe(1);
    expect(result.models[0].id).toBe('qwen3.6-plus');
    expect(result.catalogModels).toEqual([]);
  });

  it('Qwen alias: qwen3.6-plus-2026-04-02 → qwen3.6-plus after Setup', () => {
    const result = buildOfficialEnabledModels('qwen', qwenMetadataV1, {
      prevEnabledIds: ['qwen3.6-plus-2026-04-02'],
      prevDefaultModelId: 'qwen3.6-plus-2026-04-02',
    });

    expect(result.models.map((m) => m.id)).toContain('qwen3.6-plus');
    expect(result.models.map((m) => m.id)).not.toContain('qwen3.6-plus-2026-04-02');
    expect(result.defaultModelId).toBe('qwen3.6-plus');
  });

  it('Setup: repeated setup for same provider preserves the existing enabled subset', () => {
    const result = buildOfficialEnabledModels('qwen', qwenMetadataV2, {
      prevEnabledIds: ['qwen3.6-plus', 'qwen3.7-ultra'],
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
          id: 'qwen3.7-ultra',
          name: 'Qwen 3.7 Ultra',
          capabilities: ['text', 'reasoning'],
          reasoningModeAvailable: true,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      prevDefaultModelId: 'qwen3.6-plus',
    });

    expect(result.models.map((m) => m.id)).toEqual(['qwen3.6-plus', 'qwen3.7-ultra']);
  });
});

describe('official provider Resync path', () => {
  it('Resync: metadata version growth preserves the user enabled subset instead of auto-enabling new canonical models', () => {
    // The user enabled only qwen3.6-plus; qwen3.7-ultra appears after the metadata upgrade
    const afterResync = buildOfficialEnabledModels('qwen', qwenMetadataV2, {
      prevEnabledIds: ['qwen3.6-plus'],
      prevDefaultModelId: 'qwen3.6-plus',
    });

    expect(afterResync.models.map((m) => m.id)).toEqual(['qwen3.6-plus']);
  });

  it('Resync: aliases still resolve to canonical', () => {
    const afterResync = buildOfficialEnabledModels('qwen', qwenMetadataV2, {
      prevEnabledIds: ['qwen3.6-plus-2026-04-02'],
    });

    expect(afterResync.models.some((m) => m.id === 'qwen3.6-plus')).toBe(true);
  });

  it('Resync: legacy full-catalog enabled state collapses back to the initial default when old local catalog is detected', () => {
    const afterResync = buildOfficialEnabledModels('qwen', qwenMetadataV3, {
      prevEnabledIds: ['qwen3.6-plus', 'qwen3.7-ultra'],
      prevCatalogModels: [
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
          id: 'qwen3.7-ultra',
          name: 'Qwen 3.7 Ultra',
          capabilities: ['text', 'reasoning'],
          reasoningModeAvailable: true,
          isAvailable: true,
          isDefault: false,
          priceTier: '',
        },
      ],
      prevDefaultModelId: 'qwen3.6-plus',
    }, {
      repairLegacyAutoEnabledAll: true,
    });

    expect(afterResync.models.map((m) => m.id)).toEqual(['qwen3.6-plus']);
  });

  it('Resync: historical cloud full-catalog state also collapses back to metadata initial default', () => {
    const afterResync = buildOfficialEnabledModels('qwen', qwenMetadataV3, {
      prevEnabledIds: ['qwen3.6-plus', 'qwen3.7-ultra', 'qwen3.8-max'],
      prevDefaultModelId: 'qwen3.8-max',
      updatedAt: '2026-04-18T12:00:00Z',
      firestoreUpdatedAt: '2026-04-18T12:00:00Z',
    }, {
      repairLegacyAutoEnabledAll: true,
    });

    expect(afterResync.models.map((m) => m.id)).toEqual(['qwen3.6-plus']);
    expect(afterResync.defaultModelId).toBe('qwen3.6-plus');
  });

  it('Resync: intentional full-catalog state after cutoff is preserved', () => {
    const afterResync = buildOfficialEnabledModels('qwen', qwenMetadataV3, {
      prevEnabledIds: ['qwen3.6-plus', 'qwen3.7-ultra', 'qwen3.8-max'],
      prevDefaultModelId: 'qwen3.8-max',
      updatedAt: '2026-04-19T12:00:00Z',
      firestoreUpdatedAt: '2026-04-19T12:00:00Z',
    }, {
      repairLegacyAutoEnabledAll: true,
    });

    expect(afterResync.models.map((m) => m.id)).toEqual(['qwen3.6-plus', 'qwen3.7-ultra', 'qwen3.8-max']);
    expect(afterResync.defaultModelId).toBe('qwen3.8-max');
  });
});

describe('official provider Backup Restore path', () => {
  it('Backup: old catalogModels-heavy provider gets rebuilt from metadata', () => {
    // Simulated backup data: the user had enabled one dated id and one obsolete model
    const result = buildOfficialEnabledModels('qwen', qwenMetadataV1, {
      prevEnabledIds: ['qwen3.6-plus-2026-04-02', 'legacy-deprecated-model'],
      prevDefaultModelId: 'qwen3.6-plus-2026-04-02',
    });

    // The canonical id is kept and the obsolete model is pruned
    expect(result.models.map((m) => m.id)).toContain('qwen3.6-plus');
    expect(result.models.map((m) => m.id)).not.toContain('legacy-deprecated-model');
    expect(result.defaultModelId).toBe('qwen3.6-plus');
    expect(result.catalogModels).toEqual([]);
  });
});
