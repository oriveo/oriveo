/**
 * Shared fixture model_id_normalization.v1.json: every case runs through the Web
 * normalizeModelId.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { normalizeModelId } from '../model-id-normalization';
import { repoRoot } from '../../../../../../test-support/repo-root';

const ROOT = repoRoot();

interface NormalizationCase {
  caseId: string;
  input: string;
  expect: string;
}

const fixture = JSON.parse(readFileSync(
  resolve(ROOT, 'shared/model-contracts/model_id_normalization.v1.json'), 'utf8',
)) as { cases: NormalizationCase[] };

describe('model_id_normalization.v1', () => {
  it('fixture has cases', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const entry of fixture.cases) {
    it(`MODEL-ID-NORMALIZATION-${entry.caseId}`, () => {
      expect(normalizeModelId(entry.input)).toBe(entry.expect);
    });
  }
});
