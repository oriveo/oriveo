/**
 * Shared fixture image_param_normalization.v1.json: every case shallow-merges
 * profileOverride over its named profile, must pass checkImageProfile, and then
 * runs through the Web normalizeImageParams; the whole result (error included)
 * is compared with expect.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { checkImageProfile } from '../image-profile';
import { normalizeImageParams, type ImageParamRequest } from '../image-param-normalization';

const ROOT = resolve(__dirname, '../../../../../../../..');
const CONTRACTS = resolve(ROOT, '\u5171\u4eab/model-contracts');

interface NormalizationCase {
  caseId: string;
  profile: string;
  profileOverride?: Record<string, unknown>;
  request: ImageParamRequest;
  expect: Record<string, unknown>;
}

function readJson<T>(name: string): T {
  return JSON.parse(readFileSync(resolve(CONTRACTS, name), 'utf8')) as T;
}

const fixture = readJson<{
  contractId: string;
  defaultAspect: string;
  profiles: Record<string, Record<string, unknown>>;
  cases: NormalizationCase[];
}>('image_param_normalization.v1.json');

describe('image_param_normalization.v1', () => {
  it('fixture identity and cases', () => {
    expect(fixture.contractId).toBe('image_param_normalization.v1');
    expect(fixture.cases.length).toBeGreaterThan(0);
  });

  for (const entry of fixture.cases) {
    it(`IMAGE-PARAM-NORMALIZATION-${entry.caseId}`, () => {
      const base = fixture.profiles[entry.profile];
      expect(base, `${entry.caseId}.profile exists`).toBeDefined();
      const merged = { ...base, ...(entry.profileOverride ?? {}) };
      const checked = checkImageProfile(merged);
      expect(checked.reason, `${entry.caseId}.checkImageProfile reason`).toBeNull();
      expect(checked.profile, `${entry.caseId}.checkImageProfile profile`).not.toBeNull();
      if (!checked.profile) return;
      const result = normalizeImageParams(checked.profile, entry.request, fixture.defaultAspect);
      expect(result, entry.caseId).toStrictEqual(entry.expect);
    });
  }
});
