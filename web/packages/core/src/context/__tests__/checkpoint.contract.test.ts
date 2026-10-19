import { describe, expect, it } from 'vitest';

import {
  ContextCheckpoint,
  type CheckpointFallbackMessage,
  type CheckpointKeptMessage,
  type CheckpointSpanMessage,
  type CheckpointUserCandidate,
} from '../checkpoint';
import { ContextHash } from '../hash';
import { ContextContractFixture } from './fixture';

interface ConcurrencyFixtureCandidate {
  checkpointId: string;
  coversToIndex: number;
  createdAt: string;
}

interface CheckpointContract {
  constants: {
    note: string;
    truncationMark: string;
    shortTruncationCodePoints: number;
    packerVersion: string;
    headings: string[];
    uuidNamespace: { url: string; value: string };
    sentenceBoundary: Record<string, unknown>;
  };
  truncateCases: Array<{
    id: string;
    input: { text: string; head: number; tail: number | null };
    expected: string;
  }>;
  spanCases: Array<{
    id: string;
    input: { messages: CheckpointSpanMessage[]; B: number; previousCoversTo: string | null };
    expected: Record<string, unknown>;
  }>;
  userMessageCases: Array<{
    id: string;
    input: { candidates: CheckpointUserCandidate[]; B: number; rhoHi: number; userMessagesMax?: number };
    expected: CheckpointKeptMessage[];
  }>;
  serializeCases: Array<{
    id: string;
    input: {
      coversFrom: string;
      coversTo: string;
      messagesCovered: number;
      kept: CheckpointKeptMessage[];
      summary: string | null;
    };
    expected: string;
  }>;
  validateCases: Array<{
    id: string;
    input: { summary: string; summaryMax: number; spanTokens: number; rhoHi: number };
    expected: { valid: boolean; reasons: string[] };
  }>;
  normalizeHeadingCases: Array<{
    id: string;
    input: { summary: string };
    expected: { summary: string };
  }>;
  idCases: Array<{
    id: string;
    input: {
      messages?: Array<{ id: string; text: string }>;
      conversationId?: string;
      coversTo?: string;
      packerVersion?: string;
    };
    expected: { textHashes?: string[]; coversDigest?: string; checkpointId?: string };
  }>;
  concurrencyCases: Array<{
    id: string;
    input: { a: ConcurrencyFixtureCandidate; b: ConcurrencyFixtureCandidate };
    expected: 'a' | 'b';
  }>;
  fallbackCases: Array<{
    id: string;
    input: {
      messages: CheckpointFallbackMessage[];
      B: number;
      rhoHi: number;
      fixedTokens: number;
      oldSummary: string | null;
    };
    expected: {
      tailStartId: string;
      keptUserIds: string[];
      total: number;
      targetMet: boolean;
      stages: string[];
      checkpointText?: string;
    };
  }>;
}

const contract = ContextContractFixture.load<CheckpointContract>('checkpoint.v1.json');

describe('ContextContractCheckpoint', () => {
  it('constants_equal_fixture', () => {
    expect(ContextCheckpoint.constants.note).toBe(contract.constants.note);
    expect(ContextCheckpoint.constants.truncationMark).toBe(contract.constants.truncationMark);
    expect(ContextCheckpoint.constants.shortTruncationCodePoints).toBe(contract.constants.shortTruncationCodePoints);
    expect(ContextCheckpoint.constants.packerVersion).toBe(contract.constants.packerVersion);
    expect(ContextCheckpoint.constants.headings).toEqual(contract.constants.headings);
    expect(ContextCheckpoint.constants.uuidNamespace).toBe(contract.constants.uuidNamespace.value);
    expect(ContextCheckpoint.constants.sentenceBoundary).toEqual(contract.constants.sentenceBoundary);
  });

  describe('truncate', () => {
    for (const c of contract.truncateCases) {
      it(c.id, () => {
        const { text, head, tail } = c.input;
        expect(ContextCheckpoint.truncate(text, head, tail), c.id).toBe(c.expected);
      });
    }
  });

  describe('span', () => {
    for (const c of contract.spanCases) {
      it(c.id, () => {
        const { messages, B, previousCoversTo } = c.input;
        expect(ContextCheckpoint.selectSpan(messages, B, previousCoversTo), c.id).toEqual(c.expected);
      });
    }
  });

  describe('userMessages', () => {
    for (const c of contract.userMessageCases) {
      it(c.id, () => {
        const { candidates, B, rhoHi, userMessagesMax } = c.input;
        expect(ContextCheckpoint.pickUserMessages(candidates, B, rhoHi, userMessagesMax), c.id).toEqual(c.expected);
      });
    }
  });

  describe('serialize', () => {
    for (const c of contract.serializeCases) {
      it(c.id, () => {
        const { coversFrom, coversTo, messagesCovered, kept, summary } = c.input;
        expect(ContextCheckpoint.serialize(coversFrom, coversTo, messagesCovered, kept, summary), c.id).toBe(
          c.expected,
        );
      });
    }
  });

  describe('validate', () => {
    for (const c of contract.validateCases) {
      it(c.id, () => {
        const { summary, summaryMax, spanTokens, rhoHi } = c.input;
        expect(ContextCheckpoint.validateSummary(summary, summaryMax, spanTokens, rhoHi), c.id).toEqual(c.expected);
      });
    }
  });

  describe('normalizeHeadings', () => {
    it('case_count', () => {
      expect(contract.normalizeHeadingCases).toHaveLength(9);
    });

    for (const c of contract.normalizeHeadingCases) {
      it(c.id, () => {
        expect(ContextCheckpoint.normalizeHeadings(c.input.summary), c.id).toBe(c.expected.summary);
      });
    }
  });

  describe('ids', () => {
    it('hash_nist_abc_vectors', () => {
      const abc = new TextEncoder().encode('abc');
      expect(ContextHash.sha256Hex(abc)).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      const sha1 = Array.from(ContextHash.sha1Bytes(abc), (b) => b.toString(16).padStart(2, '0')).join('');
      expect(sha1).toBe('a9993e364706816aba3e25717850c26c9cd0d89d');
      // The namespace itself is derived as UUIDv5(NAMESPACE_URL, url)
      expect(ContextHash.uuidV5('6ba7b811-9dad-11d1-80b4-00c04fd430c8', contract.constants.uuidNamespace.url)).toBe(
        contract.constants.uuidNamespace.value,
      );
    });

    for (const c of contract.idCases) {
      it(c.id, () => {
        const { messages, conversationId, coversTo, packerVersion } = c.input;
        if (messages) {
          expect(messages.map((m) => ContextCheckpoint.textHash(m.text)), c.id).toEqual(c.expected.textHashes);
          expect(ContextCheckpoint.coversDigest(messages), c.id).toBe(c.expected.coversDigest);
        }
        if (conversationId !== undefined && coversTo !== undefined && packerVersion !== undefined) {
          expect(ContextCheckpoint.checkpointId(conversationId, coversTo, packerVersion), c.id).toBe(
            c.expected.checkpointId,
          );
        }
      });
    }
  });

  describe('concurrency', () => {
    const toCandidate = (f: ConcurrencyFixtureCandidate) => ({
      checkpointId: f.checkpointId,
      coversToIndex: f.coversToIndex,
      createdAtMillis: Date.parse(f.createdAt),
    });
    for (const c of contract.concurrencyCases) {
      it(c.id, () => {
        const a = toCandidate(c.input.a);
        const b = toCandidate(c.input.b);
        const winner = ContextCheckpoint.resolveConcurrency(a, b);
        expect(winner, c.id).toBe(c.expected === 'a' ? a : b);
      });
    }
  });

  describe('fallback', () => {
    for (const c of contract.fallbackCases) {
      it(c.id, () => {
        const { messages, B, rhoHi, fixedTokens, oldSummary } = c.input;
        const result = ContextCheckpoint.fallback(messages, B, rhoHi, fixedTokens, oldSummary);
        const { tailStartId, keptUserIds, total, targetMet, stages } = result;
        const { checkpointText: expectedCheckpointText, ...expected } = c.expected;
        expect({ tailStartId, keptUserIds, total, targetMet, stages }, c.id).toEqual(expected);
        if (expectedCheckpointText !== undefined) {
          expect(result.checkpointText, c.id).toBe(expectedCheckpointText);
        }
        // total must be derived consistently from the checkpoint text the production code actually produced
        const tailStart = messages.findIndex((m) => m.id === tailStartId);
        const tailTokens = messages.slice(tailStart).reduce((sum, m) => sum + m.estTokens, 0);
        const checkpointTokens = result.checkpointText ? Math.ceil(Buffer.byteLength(result.checkpointText) * rhoHi) : 0;
        expect(fixedTokens + checkpointTokens + tailTokens, c.id).toBe(total);
      });
    }

    it('fallback_minimal_keeps_old_summary', () => {
      const base = contract.fallbackCases.find((c) => c.id === 'minimal_set_when_nothing_else_fits');
      if (!base) throw new Error('minimal_set_when_nothing_else_fits missing');
      const oldSummary = '## Goal\nKeep <going> & on.';
      const { messages, B, rhoHi, fixedTokens } = base.input;
      const result = ContextCheckpoint.fallback(messages, B, rhoHi, fixedTokens, oldSummary);
      expect(result.stages[result.stages.length - 1]).toBe('minimal');
      expect(result.checkpointText).toContain('<summary>## Goal\nKeep &lt;going&gt; &amp; on.</summary>');
      expect(result.checkpointText?.endsWith('</oriveo-context-checkpoint>')).toBe(true);
    });
  });
});
