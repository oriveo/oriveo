import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { PROVIDER_TEXT_TINT_RULE, providerTextTint } from './provider-text-tint';

/**
 * Provider text tint: reads the shared fixture provider-text-tint.v1.json and asserts every case
 * per channel |diff| <= 1, plus the rule constants.
 */
const REPO_ROOT = resolve(__dirname, '../../../../..');
const JSON_PATH = resolve(REPO_ROOT, 'shared/test-fixtures/provider-tint/provider-text-tint.v1.json');

const fixture = JSON.parse(readFileSync(JSON_PATH, 'utf8')) as {
  rule: { minContrast: number; step: number; light: string[]; dark: string[] };
  cases: { id: string; brand: string; light: string; dark: string }[];
};

const channels = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

function expectClose(actual: string, expected: string, label: string) {
  expect(actual, label).toMatch(/^#[0-9A-F]{6}$/);
  const a = channels(actual);
  const e = channels(expected);
  for (let i = 0; i < 3; i++) {
    expect(Math.abs(a[i] - e[i]), `${label} channel ${i}: ${actual} vs ${expected}`).toBeLessThanOrEqual(1);
  }
}

describe('providerTextTint', () => {
  it('providerTextTintMatchesSharedFixture', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
    for (const c of fixture.cases) {
      expectClose(providerTextTint(c.brand, false), c.light, `${c.id} light`);
      expectClose(providerTextTint(c.brand, true), c.dark, `${c.id} dark`);
      // lower-case input resolves the same way
      expectClose(providerTextTint(c.brand.toLowerCase(), true), c.dark, `${c.id} dark lower-case`);
    }
  });

  it('providerTextTintRuleMatchesFixture', () => {
    expect({
      minContrast: PROVIDER_TEXT_TINT_RULE.minContrast,
      step: PROVIDER_TEXT_TINT_RULE.step,
      light: [...PROVIDER_TEXT_TINT_RULE.light],
      dark: [...PROVIDER_TEXT_TINT_RULE.dark],
    }).toEqual(fixture.rule);
  });
});
