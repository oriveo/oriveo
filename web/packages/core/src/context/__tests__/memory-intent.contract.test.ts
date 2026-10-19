import { describe, expect, it } from 'vitest';

import {
  acceptMemoryCandidate,
  classifyMemoryIntent,
  makeMemoryCandidate,
  memoryIntentCanonical,
  memoryIntentFingerprint,
  rejectMemoryCandidate,
  sweepMemoryCandidates,
  type MemoryCandidateContext,
  type MemoryCandidateEdit,
  type MemoryCandidateRecord,
} from '../memory-intent';
import {
  MEMORY_INTENT_CANDIDATE_TTL_MS,
  MEMORY_INTENT_CODE_TOKEN_CHARS,
  MEMORY_INTENT_CONFIDENCE_EXPLICIT,
  MEMORY_INTENT_CONFIDENCE_IMPLICIT,
  MEMORY_INTENT_CONTENT_MAX_CODE_POINTS,
  MEMORY_INTENT_LEXICON,
  MEMORY_INTENT_SECRET_PATTERNS,
  MEMORY_INTENT_SEPARATORS,
  MEMORY_INTENT_UUID_NAMESPACE,
  MEMORY_INTENT_VERSION,
} from '../memory-intent-lexicon';
import { ContextContractFixture } from './fixture';

type LexiconTable = Record<string, unknown> & { kindStarts: Record<string, string[]> };

interface MemoryIntentContract {
  version: number;
  constants: {
    candidateTtlMs: number;
    contentMaxCodePoints: number;
    uuidNamespace: string;
    confidence: { explicit_persist: number; implicit_persist: number };
    codeTokenChars: string;
    separators: string;
  };
  lexiconModes: Record<string, string>;
  lexicon: Record<string, LexiconTable>;
  secretPatterns: Array<{ id: string; regex: string; luhn: boolean }>;
  cases: Array<{ id: string; text: string; expected: unknown }>;
  fingerprintCases: Array<{ id: string; content: string; expected: { canonical: string; fingerprint: string } }>;
  candidateCases: Array<{
    id: string;
    text: string;
    context: MemoryCandidateContext;
    expected: unknown;
  }>;
  transitionCases: Array<{
    id: string;
    op: 'accept' | 'reject';
    record: MemoryCandidateRecord;
    edit: MemoryCandidateEdit | null;
    nowMs: number;
    expected: unknown;
  }>;
  sweepCases: Array<{
    id: string;
    records: MemoryCandidateRecord[];
    activeContents: string[];
    nowMs: number;
    expected: unknown;
  }>;
}

const contract = ContextContractFixture.load<MemoryIntentContract>('memory-intent.v1.json');

const DUMMY_CONTEXT: MemoryCandidateContext = {
  conversationId: '3f1c9a52-7d4e-4b8a-9c21-5e6f7a8b9c0d',
  folderId: null,
  messageId: '0b1c2d3e-4f50-4617-8899-aabbccddeeff',
  nowMs: 1792137600000,
  activeContents: [],
  records: [],
};

describe('ContextContractMemoryIntent', () => {
  it('cases', () => {
    expect(contract.cases.length).toBeGreaterThan(0);
    const failures: string[] = [];
    for (const c of contract.cases) {
      const actual = classifyMemoryIntent(c.text);
      if (JSON.stringify(actual) !== JSON.stringify(c.expected)) {
        failures.push(`${c.id}: expected ${JSON.stringify(c.expected)} got ${JSON.stringify(actual)}`);
      }
    }
    expect(failures).toStrictEqual([]);
    for (const c of contract.cases) expect(classifyMemoryIntent(c.text), c.id).toStrictEqual(c.expected);
  });

  it('fingerprintCases', () => {
    expect(contract.fingerprintCases.length).toBeGreaterThan(0);
    for (const c of contract.fingerprintCases) {
      expect(
        { canonical: memoryIntentCanonical(c.content), fingerprint: memoryIntentFingerprint(c.content) },
        c.id,
      ).toStrictEqual(c.expected);
    }
  });

  it('candidateCases', () => {
    expect(contract.candidateCases.length).toBeGreaterThan(0);
    for (const c of contract.candidateCases) {
      const actual = makeMemoryCandidate(classifyMemoryIntent(c.text), c.context);
      expect(actual, c.id).toStrictEqual(c.expected);
    }
  });

  it('transitionCases', () => {
    expect(contract.transitionCases.length).toBeGreaterThan(0);
    // Fixture edits are passed through as-is: a null edit must behave like an absent one.
    for (const c of contract.transitionCases) {
      const actual =
        c.op === 'accept'
          ? acceptMemoryCandidate(c.record, c.edit, c.nowMs)
          : rejectMemoryCandidate(c.record, c.nowMs);
      expect(actual, c.id).toStrictEqual(c.expected);
    }
  });

  it('sweepCases', () => {
    expect(contract.sweepCases.length).toBeGreaterThan(0);
    for (const c of contract.sweepCases) {
      expect(sweepMemoryCandidates(c.records, c.activeContents, c.nowMs), c.id).toStrictEqual(c.expected);
    }
  });

  it('lexicon_matches_fixture', () => {
    const embedded = MEMORY_INTENT_LEXICON.map(
      ({ code, mode, kindProject, kindGoal, kindPreference, kindIdentity, ...rest }) =>
        [
          code,
          mode,
          { ...rest, kindStarts: { project: kindProject, goal: kindGoal, preference: kindPreference, identity: kindIdentity } },
        ] as const,
    );
    const fixture = Object.entries(contract.lexicon);
    expect(fixture.length).toBeGreaterThan(0);
    expect(embedded.map(([code]) => code)).toStrictEqual(fixture.map(([code]) => code));
    expect(Object.fromEntries(embedded.map(([code, mode]) => [code, mode]))).toStrictEqual(contract.lexiconModes);
    for (const [code, table] of fixture) {
      const mine = embedded.find(([c]) => c === code)?.[2];
      expect(mine, code).toStrictEqual(table);
      expect(Object.keys(mine!.kindStarts), code).toStrictEqual(Object.keys(table.kindStarts));
    }
  });

  it('constants_match_fixture', () => {
    expect(MEMORY_INTENT_VERSION).toBe(contract.version);
    expect(MEMORY_INTENT_CANDIDATE_TTL_MS).toBe(contract.constants.candidateTtlMs);
    expect(MEMORY_INTENT_CONTENT_MAX_CODE_POINTS).toBe(contract.constants.contentMaxCodePoints);
    expect(MEMORY_INTENT_UUID_NAMESPACE).toBe(contract.constants.uuidNamespace);
    expect(MEMORY_INTENT_CONFIDENCE_EXPLICIT).toBe(contract.constants.confidence.explicit_persist);
    expect(MEMORY_INTENT_CONFIDENCE_IMPLICIT).toBe(contract.constants.confidence.implicit_persist);
    expect(MEMORY_INTENT_CODE_TOKEN_CHARS).toBe(contract.constants.codeTokenChars);
    expect(MEMORY_INTENT_SEPARATORS).toBe(contract.constants.separators);
    expect(contract.secretPatterns.length).toBeGreaterThan(0);
    expect(MEMORY_INTENT_SECRET_PATTERNS).toStrictEqual(contract.secretPatterns);
  });

  it('no_classification_writes_active', () => {
    expect(contract.cases.length).toBeGreaterThan(0);
    let created = 0;
    for (const c of contract.cases) {
      const outcome = makeMemoryCandidate(classifyMemoryIntent(c.text), DUMMY_CONTEXT);
      if (outcome.action !== 'create') {
        expect(outcome.candidate, c.id).toBeNull();
        continue;
      }
      created++;
      expect(outcome.candidate.status, c.id).toBe('pending');
      const accepted = acceptMemoryCandidate(outcome.candidate, null, DUMMY_CONTEXT.nowMs);
      if ('error' in accepted) throw new Error(`${c.id}: ${accepted.error}`);
      expect(accepted.item.status, c.id).toBe('active');
      expect(accepted.record.status, c.id).toBe('accepted');
    }
    expect(created).toBeGreaterThan(0);
  });
});
