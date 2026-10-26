/**
 * Rejection signature contract test: cases come only from the shared fixture rejection-signatures.v1.json,
 * asserting the actual output of matchRejectionSignature; it also asserts the checked-in generated file is in sync with the fixture.
 */
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { matchRejectionSignature } from '../rejection-signatures';
import {
  FIXTURE_PATH,
  generateRejectionSignaturesSource,
  OUTPUT_PATH,
} from '../../../../scripts/generate-rejection-signatures.mjs';

interface SignatureEntry {
  signatureId: string;
  kind: 'input_rejected' | 'param_rejected';
  capabilityKey?: string;
  parameter?: string;
}

interface RejectionFixture {
  byWireFamily: Record<string, SignatureEntry[]>;
  byProtocol: Record<string, SignatureEntry[]>;
  cases: Array<{
    id: string;
    protocol: string;
    wireFamily?: string;
    response: { status: number; body: unknown };
    expect: { signatureId: string | null };
  }>;
}

const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as RejectionFixture;
const signaturesById = new Map(
  [...Object.values(fixture.byWireFamily), ...Object.values(fixture.byProtocol)]
    .flat()
    .map((entry) => [entry.signatureId, entry]),
);

describe('rejection signatures fixture cases', () => {
  for (const testCase of fixture.cases) {
    it(testCase.id, () => {
      const result = matchRejectionSignature({
        protocol: testCase.protocol,
        wireFamily: testCase.wireFamily,
        status: testCase.response.status,
        body: testCase.response.body,
      });
      const expectedId = testCase.expect.signatureId;
      if (expectedId === null) {
        expect(result).toBeNull();
        return;
      }
      const entry = signaturesById.get(expectedId);
      expect(entry).toBeDefined();
      const expected =
        entry!.kind === 'input_rejected'
          ? { signatureId: expectedId, kind: entry!.kind, capabilityKey: entry!.capabilityKey }
          : { signatureId: expectedId, kind: entry!.kind, parameter: entry!.parameter };
      expect(result).toEqual(expected);
    });
  }
});

describe('rejection signatures generated file', () => {
  it('in-memory regeneration is byte-identical to the checked-in file', () => {
    expect(generateRejectionSignaturesSource()).toBe(readFileSync(OUTPUT_PATH, 'utf8'));
  });
});
