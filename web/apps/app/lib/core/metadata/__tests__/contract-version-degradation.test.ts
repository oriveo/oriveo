/**
 * @vitest-environment jsdom
 *
 * Safe degradation path for contractVersion.
 *
 * Covers:
 *   - metadata.contractVersion inside the compatibility window `[N-1, N+1]`: consumed normally
 *   - metadata.contractVersion >= N+2: isContractVersionDegraded=true
 *   - buildOfficialEnabledModels does not extend the catalog while degraded=true
 *   - the bootstrap entry point reads this flag to decide whether to recompute
 *
 * The client constant SUPPORTED_CONTRACT_VERSION is 1, the initial release value.
 */

import { describe, expect, it } from 'vitest';
import {
  isContractVersionDegraded,
  SUPPORTED_CONTRACT_VERSION,
} from '../metadata-runtime';
import { buildOfficialEnabledModels } from '../../providers/official-model-sync';
import type { CatalogMetadataInput } from '../../providers/catalog-resolver';

describe('isContractVersionDegraded', () => {
  it('accepts null / undefined as not degraded (no contract info yet)', () => {
    expect(isContractVersionDegraded(null)).toBe(false);
    expect(isContractVersionDegraded(undefined)).toBe(false);
  });

  it('accepts contractVersion within [N-1, N+1] window', () => {
    // The client constant is currently 1, so 0, 1 and 2 (N-1/N/N+1) are consumed normally
    expect(isContractVersionDegraded(SUPPORTED_CONTRACT_VERSION - 1)).toBe(false);
    expect(isContractVersionDegraded(SUPPORTED_CONTRACT_VERSION)).toBe(false);
    expect(isContractVersionDegraded(SUPPORTED_CONTRACT_VERSION + 1)).toBe(false);
  });

  it('marks contractVersion >= N+2 as degraded', () => {
    expect(isContractVersionDegraded(SUPPORTED_CONTRACT_VERSION + 2)).toBe(true);
    expect(isContractVersionDegraded(SUPPORTED_CONTRACT_VERSION + 10)).toBe(true);
  });
});

describe('buildOfficialEnabledModels under contractVersion degradation', () => {
  const metadata: CatalogMetadataInput = {
    providers: {
      qwen: {
        defaultModelId: 'qwen3.6-plus',
        models: {
          'qwen3.6-plus': {
            canonicalModelId: 'qwen3.6-plus',
            displayName: 'Qwen 3.6 Plus',
            capabilities: ['text'],
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

  it('returns empty catalog when overrides.contractVersionDegraded=true (the official catalog must not be extended)', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus'],
    }, { contractVersionDegraded: true });

    // Both the list and the default are empty: a degraded contract must not leave a model selected.
    expect(build.models).toEqual([]);
    expect(build.defaultModelId).toBe('');
  });

  it('normal path when overrides.contractVersionDegraded=false', () => {
    const build = buildOfficialEnabledModels('qwen', metadata, {
      prevEnabledIds: ['qwen3.6-plus'],
    }, { contractVersionDegraded: false });

    expect(build.models.length).toBeGreaterThan(0);
  });
});
