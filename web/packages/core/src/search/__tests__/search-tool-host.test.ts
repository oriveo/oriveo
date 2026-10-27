import { describe, expect, it } from 'vitest';
import { CONTINUATION_KINDS } from '../../providers/request-preference/continuation';
import { HOST_PROMPTS, LOOP_LIMITS, resolveSearchToolHost, THINKING_TOOL_RULES } from '../search-tool-host';
import { loadContract } from './fixtures';

const fixture = loadContract('shared/search-contracts/tool-host.v1.json');
// JSON semantic comparison: a missing field is not the same as null
const json = (v: unknown) => JSON.parse(JSON.stringify(v));

describe('tool host table (tool-host.v1)', () => {
  it('constants match the fixture (continuation steps come from the local continuation table)', () => {
    expect(json(LOOP_LIMITS)).toStrictEqual(fixture.constants.loopLimits);
    expect(json(THINKING_TOOL_RULES)).toStrictEqual(fixture.constants.thinkingRules);
    expect(json(HOST_PROMPTS)).toStrictEqual(fixture.constants.prompts);
    const steps = Object.fromEntries(Object.entries(CONTINUATION_KINDS).map(([k, v]) => [k, v.maxSteps]));
    expect(steps).toStrictEqual(fixture.constants.continuationMaxSteps);
  });

  it('SRCH-HOST-01 cases: host, tools, step count, circuit breaker and confirmation', () => {
    expect(fixture.cases.length).toBeGreaterThan(0);
    for (const c of fixture.cases) {
      let got: unknown;
      try {
        got = json(resolveSearchToolHost(c.input));
      } catch (e) {
        got = { error: (e as Error).message };
      }
      expect(got, c.caseId).toStrictEqual(c.expect);
    }
  });
});
