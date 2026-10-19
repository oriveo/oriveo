import { describe, expect, it } from 'vitest';

import {
  STOP_REASONS,
  StopReasonResolver,
  type StopFamily,
  type StopReason,
  type StreamEnding,
} from '../stop-reason';
import { ContextContractFixture } from './fixture';

interface StopReasonContract {
  enum: string[];
  cases: Array<{
    id: string;
    input: { family: StopFamily; ended: StreamEnding; finishRaw: string | null; hadContent: boolean };
    expected: StopReason;
  }>;
}

const contract = ContextContractFixture.load<StopReasonContract>('stop-reason.v1.json');

describe('ContextContractStopReason', () => {
  for (const c of contract.cases) {
    it(c.id, () => {
      expect(contract.enum).toEqual([...STOP_REASONS]);
      const { family, ended, finishRaw, hadContent } = c.input;
      expect(StopReasonResolver.resolve(family, ended, finishRaw, hadContent)).toBe(c.expected);
    });
  }
});
