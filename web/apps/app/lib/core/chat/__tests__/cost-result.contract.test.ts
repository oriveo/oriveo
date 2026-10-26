/**
 * Shared fixture cost-result.v1.json: how the cost of a single message is recorded.
 *
 * - legacyCacheReadCases: the legacy single-tier pricing cache-read rate, cacheReadInputPerMToken > cachedInputPerMToken > input x 0.5.
 * - currencyCases were superseded by the recordCases of cost-currency.v1.json (declared by the fixture's $comment),
 *   see lib/core/cost/__tests__/cost-currency.contract.test.ts.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { calcCost, type PricingInput } from '../cost';
import { emptyUsageBreakdown } from '../usage-breakdown';

const ROOT = resolve(__dirname, '../../../../../../..');

interface LegacyCacheReadCase {
  id: string;
  pricing: PricingInput;
  expect: { cacheReadPerMToken: number };
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/test-fixtures/provider-pricing/cost-result.v1.json'), 'utf8',
)) as { legacyCacheReadCases: LegacyCacheReadCase[] };

describe('cost-result.v1 legacyCacheReadCases', () => {
  for (const entry of fixture.legacyCacheReadCases) {
    it(`COST-RESULT-${entry.id}`, () => {
      // Put in only 1M cache-read tokens: the cost is then the per-million cache-read price
      const result = calcCost({ ...emptyUsageBreakdown(), cachedInputTokens: 1_000_000 }, entry.pricing);
      expect(result.source).toBe('localEstimate');
      expect(result.cost).toBeCloseTo(entry.expect.cacheReadPerMToken, 10);
    });
  }
});
