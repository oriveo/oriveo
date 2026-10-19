import { describe, expect, it } from 'vitest';

import { ContextOverflowClassifier, type OverflowFamily, type OverflowVia } from '../overflow';
import { ContextContractFixture } from './fixture';

interface OverflowContract {
  patterns: Record<string, string>;
  cases: Array<{
    id: string;
    input: { family: OverflowFamily; status: number; body: unknown };
    expected: { overflow: boolean; via: OverflowVia | null };
  }>;
}

const contract = ContextContractFixture.load<OverflowContract>('overflow-errors.v1.json');

function bodyString(body: unknown): string {
  return typeof body === 'string' ? body : JSON.stringify(body);
}

const customBody = JSON.stringify({ error: { message: 'Upstream refused: CTX_OVER_9000 for this route' } });

describe('ContextContractOverflow', () => {
  for (const c of contract.cases) {
    it(c.id, () => {
      const { family, status, body } = c.input;
      expect(ContextOverflowClassifier.classify(family, status, bodyString(body))).toEqual(c.expected);
    });
  }

  it('default_patterns_equal_fixture', () => {
    expect(ContextOverflowClassifier.defaultPatterns).toEqual(contract.patterns);
  });

  it('extra_patterns_append', () => {
    expect(ContextOverflowClassifier.classify('openai_compatible', 400, customBody)).toEqual({
      overflow: false,
      via: null,
    });
    expect(
      ContextOverflowClassifier.classify('openai_compatible', 400, customBody, {
        openai_compatible: ['(?i)ctx_over_\\d+'],
      }),
    ).toEqual({ overflow: true, via: 'status+regex' });
  });

  it('extra_patterns_invalid_skipped', () => {
    expect(
      ContextOverflowClassifier.classify('openai_chat', 400, customBody, {
        openai_compatible: ['(unclosed', 'ctx_over_\\d+'],
      }),
    ).toEqual({ overflow: true, via: 'status+regex' });
  });
});
