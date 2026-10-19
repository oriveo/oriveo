import { describe, expect, it } from 'vitest';

import { COMPACT_NUMBER_LOCALES, formatCompactNumber, resolveCompactLocale } from '../compact-number';
import { ContextContractFixture } from './fixture';

interface CompactNumberContract {
  locales: Record<string, { decimal: string; group: string; tiers: Array<{ min: number; pattern: string; few?: string }> }>;
  cases: Array<{ id: string; input: { value: number; locale: string }; expected: string }>;
  localeCases: Array<{ id: string; input: string; expected: string }>;
}

const contract = ContextContractFixture.load<CompactNumberContract>('compact-number.v1.json');

describe('ContextContractCompactNumber', () => {
  it('cases', () => {
    expect(contract.cases.length).toBeGreaterThan(0);
    for (const c of contract.cases) {
      expect(formatCompactNumber(c.input.value, c.input.locale), c.id).toBe(c.expected);
    }
  });

  it('locale_cases', () => {
    expect(contract.localeCases.length).toBeGreaterThan(0);
    for (const c of contract.localeCases) {
      expect(resolveCompactLocale(c.input), c.id).toBe(c.expected);
    }
  });

  it('table_equals_fixture', () => {
    expect(Object.keys(COMPACT_NUMBER_LOCALES)).toEqual(Object.keys(contract.locales));
    for (const [code, expected] of Object.entries(contract.locales)) {
      const actual = COMPACT_NUMBER_LOCALES[code as keyof typeof COMPACT_NUMBER_LOCALES];
      expect(Object.keys(actual), code).toEqual(Object.keys(expected));
      expect(actual.decimal, `${code}.decimal`).toBe(expected.decimal);
      expect(actual.group, `${code}.group`).toBe(expected.group);
      expect(actual.tiers, `${code}.tiers`).toHaveLength(expected.tiers.length);
      expected.tiers.forEach((tier, i) => {
        const got = actual.tiers[i];
        expect(Object.keys(got), `${code}.tiers[${i}] keys`).toEqual(Object.keys(tier));
        expect(got.min, `${code}.tiers[${i}].min`).toBe(tier.min);
        expect(got.pattern, `${code}.tiers[${i}].pattern`).toBe(tier.pattern);
        expect(got.few, `${code}.tiers[${i}].few`).toBe(tier.few);
      });
    }
  });
});
