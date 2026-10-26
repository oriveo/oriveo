/**
 * Runs the shared pricing-v2-estimate.v1 fixture case by case, so every platform gives the same answer.
 * Each pricingV2 first goes through the production decoder decodePricingV2, then to estimatePricingV2.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { decodePricingV2, estimatePricingV2, type PricingV2Usage } from './pricing-v2-estimate';

interface FixtureCase {
  name: string;
  pricingV2: unknown;
  usage: PricingV2Usage;
  at: string;
  expected: { status: string; amount?: number; currencyCode?: string };
}

const fixturePath = path.resolve(
  process.cwd(),
  '../../../shared/test-fixtures/provider-pricing/pricing-v2-estimate.v1.json',
);
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as { cases: FixtureCase[] };

describe('pricing-v2-estimate.v1 fixture', () => {
  it('the fixture runs all 24 cases', () => {
    expect(fixture.cases).toHaveLength(24);
  });

  for (const c of fixture.cases) {
    it(c.name, () => {
      const decoded = decodePricingV2(c.pricingV2);
      expect(decoded).toBeDefined();
      const result = estimatePricingV2(decoded!, c.usage, new Date(c.at));
      expect(result.status).toBe(c.expected.status);
      if (c.expected.status === 'estimated') {
        const amount = result.status === 'estimated' ? result.amount : NaN;
        expect(Math.abs(amount - c.expected.amount!)).toBeLessThanOrEqual(1e-9);
        const currency = result.status === 'estimated' ? result.currencyCode : undefined;
        expect(currency).toBe(c.expected.currencyCode);
      }
    });
  }
});

describe('decodePricingV2 drops only the key when the shape is bad', () => {
  const good = { unit: 'per_token', base: { inputPerMToken: 2, outputPerMToken: 8 } };
  it.each([
    ['not an object', 'x'],
    ['missing unit', { base: good.base }],
    ['unit price is not a number', { ...good, base: { inputPerMToken: '2', outputPerMToken: 8 } }],
    ['tier threshold is not an integer', { ...good, contextTiers: [{ aboveInputTokens: 1.5, semantics: 'whole_request' }] }],
    ['unknown tier semantics', { ...good, contextTiers: [{ aboveInputTokens: 1, semantics: 'stepwise' }] }],
    ['invalid window start', { ...good, timeWindows: [{ timezone: 'UTC', start: '24:00', end: '06:00' }] }],
    ['unknown window days', { ...good, timeWindows: [{ timezone: 'UTC', days: ['funday'], start: '00:00', end: '06:00' }] }],
    ['unknown cache write ttl', { ...good, cache: { writes: [{ ttl: '2h', perMToken: 1 }] } }],
    ['top-level key outside the allowlist', { ...good, discount: 0.5 }],
    ['in-tier key outside the allowlist', { ...good, contextTiers: [{ aboveInputTokens: 1, semantics: 'incremental', extra: 1 }] }],
    ['unit is not in the enum', { ...good, unit: 'per_call' }],
  ])('%s → undefined', (_label, raw) => {
    expect(decodePricingV2(raw)).toBeUndefined();
  });

  it('a well-formed value decodes unchanged', () => {
    expect(decodePricingV2(good)).toEqual(good);
  });
});
