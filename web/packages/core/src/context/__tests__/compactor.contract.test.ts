import { describe, expect, it } from 'vitest';

import {
  CONTEXT_COMPACTOR_CONSTANTS,
  ContextCompactionBreaker,
  ContextCompactor,
  type BreakerEvent,
  type CompactMessage,
  type SummaryRequestSpanMessage,
} from '../compactor';
import { ContextContractFixture } from './fixture';

interface CompactorContract {
  constants: {
    summaryPromptTemplate: string;
    languageFallback: string;
    serializedSystem: string;
    attachmentPlaceholder: string;
    maxSummaryAttempts: number;
    breaker: { failuresToTrip: number; fallbackTurns: number };
  };
  summaryPromptCases: Array<{
    id: string;
    input: { language: string | null; summaryMax: number };
    expected: string;
  }>;
  summaryRequestCases: Array<{
    id: string;
    input: {
      U: number;
      prefixTokens: number;
      rhoHi: number;
      language: string | null;
      summaryMax: number;
      previousCheckpointText: string | null;
      previousSummary: string | null;
      span: SummaryRequestSpanMessage[];
    };
    expected: Record<string, unknown>;
  }>;
  compactCases: Array<{
    id: string;
    input: {
      conversationId: string;
      B: number;
      rhoHi: number;
      messages: CompactMessage[];
      previous: { coversTo: string; summary: string } | null;
      summaryOutputs: Array<string | null>;
    };
    expected: Record<string, unknown>;
  }>;
  breakerCases: Array<{
    id: string;
    events: BreakerEvent[];
    expected: Array<{ mode: string; failures: number; turnsLeft: number }>;
  }>;
}

const contract = ContextContractFixture.load<CompactorContract>('checkpoint.v1.json');

describe('ContextContractCompactor', () => {
  it('constants match the fixture', () => {
    const c = contract.constants;
    expect(CONTEXT_COMPACTOR_CONSTANTS).toEqual({
      summaryPromptTemplate: c.summaryPromptTemplate,
      languageFallback: c.languageFallback,
      serializedSystem: c.serializedSystem,
      attachmentPlaceholder: c.attachmentPlaceholder,
      maxSummaryAttempts: c.maxSummaryAttempts,
      breaker: c.breaker,
    });
  });

  describe('summaryPrompt', () => {
    for (const testCase of contract.summaryPromptCases) {
      it(`summaryPrompt ${testCase.id}`, () => {
        expect(ContextCompactor.summaryPrompt(testCase.input.language, testCase.input.summaryMax)).toBe(
          testCase.expected,
        );
      });
    }
  });

  describe('summaryRequest', () => {
    for (const testCase of contract.summaryRequestCases) {
      it(`summaryRequest ${testCase.id}`, () => {
        expect(ContextCompactor.summaryRequest(testCase.input)).toEqual(testCase.expected);
      });
    }
  });

  describe('compact', () => {
    for (const testCase of contract.compactCases) {
      it(`compact ${testCase.id}`, () => {
        expect(ContextCompactor.compact(testCase.input)).toEqual(testCase.expected);
      });
    }
  });

  describe('breaker', () => {
    for (const testCase of contract.breakerCases) {
      it(`breaker ${testCase.id}`, () => {
        let breaker = ContextCompactionBreaker.initial;
        const states = testCase.events.map((event) => {
          breaker = breaker.apply(event);
          return { mode: breaker.mode, failures: breaker.failures, turnsLeft: breaker.turnsLeft };
        });
        expect(states).toEqual(testCase.expected);
      });
    }
  });
});
