import { describe, it, expect } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';
import { recalculateConversationCost } from '../usage-tracking';
import { COST_EPSILON } from '../../../utils/format-utils';

function msg(overrides: Partial<ChatMessage>): ChatMessage {
  return {
    id: crypto.randomUUID(),
    role: 'assistant',
    text: '',
    providerKind: 'openRouter',
    providerName: 'OpenRouter',
    modelName: 'gpt-4',
    estimatedCost: 0,
    state: 'delivered',
    ...overrides,
  };
}

describe('recalculateConversationCost', () => {
  it('returns 0 for an empty message list', () => {
    expect(recalculateConversationCost([])).toBe(0);
  });

  it('only sums delivered messages', () => {
    const messages = [
      msg({ estimatedCost: 0.05, state: 'delivered' }),
      msg({ estimatedCost: 0.10, state: 'generating' }),
      msg({ estimatedCost: 0.03, state: 'failed' }),
      msg({ estimatedCost: 0.02, state: 'interrupted' }),
    ];
    expect(recalculateConversationCost(messages)).toBeCloseTo(0.05);
  });

  it('ignores costs at or below COST_EPSILON', () => {
    const messages = [
      msg({ estimatedCost: COST_EPSILON }),
      msg({ estimatedCost: 0.000005 }),
      msg({ estimatedCost: 0.01 }),
    ];
    expect(recalculateConversationCost(messages)).toBeCloseTo(0.01);
  });

  it('sums the cost of several messages correctly', () => {
    const messages = [
      msg({ estimatedCost: 0.05 }),
      msg({ estimatedCost: 0.10 }),
      msg({ estimatedCost: 0.03 }),
    ];
    expect(recalculateConversationCost(messages)).toBeCloseTo(0.18);
  });

  it('user message cost is counted too, as long as its state is delivered', () => {
    const messages = [
      msg({ role: 'user', estimatedCost: 0, state: 'delivered' }),
      msg({ role: 'assistant', estimatedCost: 0.05, state: 'delivered' }),
    ];
    expect(recalculateConversationCost(messages)).toBeCloseTo(0.05);
  });

  it('cost goes down after a message is deleted', () => {
    const m1 = msg({ estimatedCost: 0.05 });
    const m2 = msg({ estimatedCost: 0.10 });
    const m3 = msg({ estimatedCost: 0.03 });

    const allThree = recalculateConversationCost([m1, m2, m3]);
    const afterDelete = recalculateConversationCost([m1, m3]);

    expect(allThree).toBeCloseTo(0.18);
    expect(afterDelete).toBeCloseTo(0.08);
  });
});
