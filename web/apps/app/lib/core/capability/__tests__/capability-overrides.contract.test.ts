// Delta normalization of Relay / custom-endpoint input capability overrides: each case of the fixture shared/test-fixtures/capability/overrides.v1.json is compared against its expect.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { normalizeCapabilityOverrides, type NormalizeCapabilityOverridesInput } from '../capability-overrides';

type OverrideCase = Omit<NormalizeCapabilityOverridesInput, 'legacy'> & {
  id: string;
  legacy: Record<string, unknown> | null;
  expect: unknown;
};

const cases: OverrideCase[] = (() => {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'capability', 'overrides.v1.json');
    if (existsSync(candidate)) {
      return (JSON.parse(readFileSync(candidate, 'utf8')) as { cases: OverrideCase[] }).cases;
    }
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('overrides.v1.json not found');
    dir = parent;
  }
})();

describe('capability overrides contract (overrides.v1.json)', () => {
  it('fixture has cases', () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  it.each(cases.map((c) => [c.id, c] as const))('%s', (_id, c) => {
    const result = normalizeCapabilityOverrides({
      connection: c.connection,
      legacy: c.legacy,
      stored: c.stored,
      serverVerdict: c.serverVerdict,
      now: c.now,
    });
    expect(result).toEqual(c.expect);
  });
});
