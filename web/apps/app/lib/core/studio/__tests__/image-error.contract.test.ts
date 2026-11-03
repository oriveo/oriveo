// @vitest-environment node
/**
 * Shared fixture image_error_samples.v1.json: every case runs through the Web
 * classifyImageResult, every kind's policy matches the fixture, every real sample of
 * image_response_samples.v1 classifies to its expected result, and every U5a fetch
 * failure is an error kind of the same name.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  classifyImageResult,
  IMAGE_ERROR_POLICIES,
  type ImageErrorKind,
  type ImageErrorPolicy,
} from '../image-error';
import type { ImageFetchFailure } from '../image-response';

const ROOT = resolve(__dirname, '../../../../../../../..');
const CONTRACTS = resolve(ROOT, '\u5171\u4eab/model-contracts');
const SAMPLES_DIR = resolve(CONTRACTS, 'image_response_samples.v1');

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, 'utf8')) as T;
}

interface FixturePolicy {
  consumesFreeQuota: false | 'by_delivered_count' | 'already_settled';
  autoRetry: false | 'once_before_body_sent';
  ui: string;
  report?: boolean;
}

interface ErrorCase {
  caseId: string;
  http: number;
  nRequested: number;
  body: unknown;
  expectKind: string;
}

interface ErrorFixture {
  kinds: Record<string, FixturePolicy>;
  cases: ErrorCase[];
}

interface ResponseIndex {
  samples: { file: string; nRequested: number; expect: { result: string } }[];
}

const fixture = readJson<ErrorFixture>(resolve(CONTRACTS, 'image_error_samples.v1.json'));
const responseIndex = readJson<ResponseIndex>(resolve(SAMPLES_DIR, 'index.json'));

function expectedPolicy(p: FixturePolicy): ImageErrorPolicy {
  return {
    consumesFreeQuota: p.consumesFreeQuota === false ? 'none' : p.consumesFreeQuota,
    autoRetry: p.autoRetry === false ? 'none' : p.autoRetry,
    ui: p.ui,
    report: p.report ?? false,
  };
}

// Exhaustive over ImageFetchFailure: a missing or extra key fails to compile.
const FETCH_FAILURES: Record<ImageFetchFailure, true> = {
  network: true,
  timeout: true,
  decode_failed: true,
};

describe('image_error_samples.v1.json', () => {
  it('cases', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
    for (const c of fixture.cases) {
      const kind = classifyImageResult({ http: c.http, body: c.body, nRequested: c.nRequested });
      expect(kind, c.caseId).toBe(c.expectKind);
    }
  });

  it('kinds', () => {
    expect(Object.keys(IMAGE_ERROR_POLICIES).sort()).toEqual(Object.keys(fixture.kinds).sort());
    for (const [kind, policy] of Object.entries(fixture.kinds)) {
      expect(IMAGE_ERROR_POLICIES[kind as ImageErrorKind], kind).toEqual(expectedPolicy(policy));
    }
  });

  it('realSamples', () => {
    expect(responseIndex.samples.length).toBeGreaterThan(0);
    for (const s of responseIndex.samples) {
      const file = readJson<{ meta: { http: number }; response: unknown }>(resolve(SAMPLES_DIR, s.file));
      const result = classifyImageResult({ http: file.meta.http, body: file.response, nRequested: s.nRequested });
      expect(result, s.file).toBe(s.expect.result);
    }
  });

  it('failureKinds', () => {
    const failures = Object.keys(FETCH_FAILURES) as ImageFetchFailure[];
    expect(failures.length).toBe(3);
    for (const failure of failures) {
      const kind: ImageErrorKind = failure;
      expect(Object.keys(fixture.kinds), failure).toContain(kind);
      expect(IMAGE_ERROR_POLICIES[kind], failure).toBeDefined();
    }
  });
});
