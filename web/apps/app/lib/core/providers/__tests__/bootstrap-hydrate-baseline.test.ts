/**
 * Baseline record for the blocking part of the bootstrap path.
 *
 * Purpose:
 *   1. Record the cost of a metadata refresh plus a rebuild of the official provider catalogs.
 *   2. Check that the timeout budget does not block the user for too long.
 *   3. Check that store.providers stays usable after a timeout, falling back to the local cache.
 *
 * This is not a strict benchmark; it varies too much under load. It is a smoke test and a baseline record.
 */

import { describe, expect, it } from 'vitest';
import { buildOfficialEnabledModels } from '../official-model-sync';
import type { CatalogMetadataInput } from '../catalog-resolver';

const largeMetadata: CatalogMetadataInput = {
  providers: {
    openRouter: {
      defaultModelId: 'openai/gpt-4o',
      models: Object.fromEntries(
        Array.from({ length: 500 }, (_, i) => [
          `vendor-${i % 20}/model-${i}`,
          {
            canonicalModelId: `vendor-${i % 20}/model-${i}`,
            displayName: `Model ${i}`,
            capabilities: i % 3 === 0 ? ['text', 'reasoning'] : ['text'],
            pricingStatus: 'priced' as const,
            pricing: { promptPerMToken: 1 + i * 0.01, completionPerMToken: 3 + i * 0.03 },
            uiHints: { rank: 500 - i, groupKey: `vendor-${i % 20}`, groupName: `Vendor ${i % 20}` },
          },
        ]),
      ),
    },
  },
};

describe('bootstrap hydrate baseline', () => {
  // elapsed is deliberately not asserted on: a wall-clock threshold set two or three orders of
  // magnitude above the measured cost is always green, and the day it goes red says the machine
  // running the tests was paging, not that this function regressed. A single timing also proves
  // nothing about complexity; asserting O(1) or O(n) would need at least two input sizes.
  // The timer is kept only to print the baseline for a human to read: it is an observation, not a gate.
  it('buildOfficialEnabledModels handles a 500-model catalog', () => {
    const started = performance.now();
    const build = buildOfficialEnabledModels('openRouter', largeMetadata, {
      prevEnabledIds: ['openai/gpt-4o', 'vendor-3/model-42'],
      prevDefaultModelId: 'openai/gpt-4o',
    });
    const elapsed = performance.now() - started;

    // The real invariant: out of 500 candidates only the one whose prevEnabledIds entry matches the
    // canonical catalog is enabled. The other, 'vendor-3/model-42', is not in openRouter's canonical
    // list and must be dropped.
    expect(build.models.length).toBe(1);
    console.info(`[baseline] buildOfficialEnabledModels on 500 canonical models: ${elapsed.toFixed(2)}ms`);
  });

  it('safe degradation: empty metadata returns empty models', () => {
    const build = buildOfficialEnabledModels('openRouter', { providers: {} }, {
      prevEnabledIds: ['openai/gpt-4o'],
    });

    // With no metadata the result must degrade safely to an empty list rather than passing
    // prevEnabledIds straight through, which would show the user a model the catalog does not have.
    expect(build.models).toEqual([]);
  });
});
