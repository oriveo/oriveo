import { describe, expect, it } from 'vitest';

import {
  ContextContinuation,
  type ContinuationPlan,
  type ContinuationProjection,
  type ContinuationState,
} from '../continuation';
import { ContextContractFixture } from './fixture';

interface WireSystemContract {
  continuationPlan: ContinuationPlan;
  continuationCases: Array<{ id: string; state: ContinuationState; expected: ContinuationProjection }>;
}

const contract = ContextContractFixture.load<WireSystemContract>('wire-system.v1.json');

describe('ContextContractContinuation', () => {
  it('covers every fixture case', () => {
    expect(contract.continuationCases.length).toBeGreaterThan(0);
  });

  it.each(contract.continuationCases.map((c) => [c.id, c] as const))('%s', (_id, c) => {
    const decision = ContextContinuation.decideContinuation(c.state);
    expect(ContextContinuation.projectContinuation(decision, contract.continuationPlan)).toStrictEqual(c.expected);
  });
});
