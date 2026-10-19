import { describe, expect, it } from 'vitest';

import {
  CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS,
  normalizeConversationInstructions,
} from '../conversation-instructions';
import { ContextContractFixture } from './fixture';

type Parts = Array<{ text: string; repeat?: number }>;

interface ConversationInstructionsContract {
  maxCodePoints: number;
  cases: Array<{ id: string; input: Parts; expected: Parts }>;
}

const contract = ContextContractFixture.load<ConversationInstructionsContract>('conversation-instructions.v1.json');

function join(parts: Parts): string {
  return parts.map((p) => p.text.repeat(p.repeat ?? 1)).join('');
}

describe('ContextContractConversationInstructions', () => {
  it('cases', () => {
    const failures: string[] = [];
    for (const c of contract.cases) {
      const actual = normalizeConversationInstructions(join(c.input));
      const expected = join(c.expected);
      if (actual !== expected) {
        failures.push(`${c.id}: expected ${expected.length} code units got ${actual.length}`);
      }
    }
    expect(failures).toStrictEqual([]);
  });

  it('max_code_points_matches_fixture', () => {
    expect(CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS).toBe(contract.maxCodePoints);
  });
});
