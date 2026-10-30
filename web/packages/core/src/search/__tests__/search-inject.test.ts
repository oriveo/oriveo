import { describe, expect, it } from 'vitest';
import {
  allocateCitations,
  budgetForNextSearch,
  FACT_STATES,
  fitWebResults,
  INJECTION_CAPS,
  searchInjectionBudget,
  summarizeSearchFacts,
  WEB_ENVELOPE_NOTE,
} from '../search-inject';
import { loadContract } from './fixtures';

const budget = loadContract('shared/search-contracts/injection-budget.v1.json');
const cite = loadContract('shared/search-contracts/citation-allocator.v1.json');
const facts = loadContract('shared/search-contracts/result-facts.v1.json');
// JSON semantic comparison: a missing field is not the same as null
const json = (v: unknown) => JSON.parse(JSON.stringify(v));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function eachCase(cases: any[], run: (c: any) => unknown) {
  expect(cases.length).toBeGreaterThan(0);
  for (const c of cases) expect(json(run(c)), c.caseId).toStrictEqual(c.expect);
}

describe('injection budget and envelope (injection-budget.v1)', () => {
  it('constants match the fixture', () => {
    expect(json(INJECTION_CAPS)).toStrictEqual(budget.constants.caps);
    expect(WEB_ENVELOPE_NOTE).toBe(budget.constants.note);
  });

  it('SRCH-INJ-01 budgetCases: per-call / per-reply caps; unknown window uses only the absolute cap', () => {
    eachCase(budget.budgetCases, (c) => searchInjectionBudget(c.input.B));
  });

  it('SRCH-INJ-02 nextCases: available now = min(per-call cap, remaining for this reply)', () => {
    eachCase(budget.nextCases, (c) => ({ budgetTokens: budgetForNextSearch(c.input) }));
  });

  it('SRCH-INJ-03 fitCases: skeleton first, drop whole trailing entries, even truncation; envelope is byte-for-byte identical', () => {
    expect(budget.fitCases.length).toBeGreaterThan(0);
    for (const c of budget.fitCases) {
      const r = fitWebResults(c.input);
      if (r.envelope) expect(r.estimatedTokens, c.caseId).toBeLessThanOrEqual(c.input.budgetTokens);
      expect(r.envelope, c.caseId).toBe(c.expect.envelope);
      expect(json(r), c.caseId).toStrictEqual(c.expect);
    }
  });
});

describe('unified citation numbering (citation-allocator.v1)', () => {
  it('SRCH-CITE-01 cases: one allocator per message; the same key reuses its number', () => {
    eachCase(cite.cases, (c) => allocateCitations(c.input.batches));
  });
});

describe('message facts (result-facts.v1)', () => {
  it('SRCH-FACT-01 cases: observed / unconfirmed / failed / not_requested', () => {
    expect([...FACT_STATES]).toStrictEqual(facts.constants.states);
    eachCase(facts.cases, (c) => summarizeSearchFacts(c.input));
  });
});
