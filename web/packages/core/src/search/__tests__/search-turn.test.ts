import { describe, expect, it } from 'vitest';
import { SEARCH_CALL_LIMITS } from '../search-route';
import { TOOL_MESSAGES } from '../search-transport';
import {
  applySearchEvent,
  finishSearchReply,
  LATENCY_BUCKETS,
  MIN_SEARCH_BUDGET_TOKENS,
  planSearchTurn,
  PRESEARCH_MESSAGES,
  RESULT_BUCKETS,
  searchedRecordLine,
  startSearchReply,
  TOOLS_REJECTED_STATUSES,
  WEB_SEARCH_TOOL,
  type SearchEffect,
} from '../search-turn';
import { loadContract } from './fixtures';

const turn = loadContract('shared/search-contracts/search-turn.v1.json');
// JSON semantic comparison: a missing field is not the same as null
const json = (v: unknown) => JSON.parse(JSON.stringify(v));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function eachCase(cases: any[], run: (c: any) => unknown) {
  expect(cases.length).toBeGreaterThan(0);
  for (const c of cases) {
    let got: unknown;
    try {
      got = json(run(c));
    } catch (e) {
      got = { error: (e as Error).message };
    }
    expect(got, c.caseId).toStrictEqual(c.expect);
  }
}

describe('execution-side combined entry (search-turn.v1)', () => {
  it('constants match the fixture', () => {
    const k = turn.constants;
    expect(json(PRESEARCH_MESSAGES)).toStrictEqual(k.presearchMessages);
    expect(json(TOOL_MESSAGES)).toStrictEqual(k.toolMessages);
    expect(json(WEB_SEARCH_TOOL)).toStrictEqual(k.webSearchTool);
    expect([...TOOLS_REJECTED_STATUSES]).toStrictEqual(k.toolsRejectedStatuses);
    expect(MIN_SEARCH_BUDGET_TOKENS).toBe(k.minSearchBudgetTokens);
    expect([...RESULT_BUCKETS]).toStrictEqual(k.resultBuckets);
    expect([...LATENCY_BUCKETS]).toStrictEqual(k.latencyBuckets);
    expect(SEARCH_CALL_LIMITS.maxSearchRequestsPerReply).toBe(k.maxSearchRequestsPerReply);
  });

  it('SRCH-TURN-01 planCases: pre-send planning (route, host, tool definitions, pre-search, reuse, budget, analytics)', () => {
    eachCase(turn.planCases, (c) => planSearchTurn(c.input));
  });

  it('SRCH-TURN-02 replyCases: startSearchReply -> applySearchEvent one by one -> finishSearchReply', () => {
    eachCase(turn.replyCases, (c) => {
      let state = startSearchReply(c.input.start);
      const effects: SearchEffect[] = [];
      for (const ev of c.input.events) {
        const r = applySearchEvent(state, ev);
        state = r.state;
        effects.push(r.effect);
      }
      return { effects, finish: finishSearchReply(state) };
    });
  });

  it('SRCH-TURN-03 recordCases: compact search record for history messages', () => {
    eachCase(turn.recordCases, (c) => ({ line: searchedRecordLine(c.input.citations) }));
  });
});
