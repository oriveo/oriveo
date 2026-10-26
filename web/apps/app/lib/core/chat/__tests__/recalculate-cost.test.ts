import { describe, it, expect } from 'vitest';
import type { ChatMessage } from '@oriveo/shared';
import { recalculateConversationCostTotals } from '../usage-tracking';

/** USD total (the estimatedCost part). */
const usdTotal = (messages: Parameters<typeof recalculateConversationCostTotals>[0]) =>
  recalculateConversationCostTotals(messages, null).estimatedCost;
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

describe('recalculateConversationCostTotals: USD total', () => {
  it('returns 0 for an empty message list', () => {
    expect(usdTotal([])).toBe(0);
  });

  it('only sums delivered messages', () => {
    const messages = [
      msg({ estimatedCost: 0.05, state: 'delivered' }),
      msg({ estimatedCost: 0.10, state: 'generating' }),
      msg({ estimatedCost: 0.03, state: 'failed' }),
      msg({ estimatedCost: 0.02, state: 'interrupted' }),
    ];
    expect(usdTotal(messages)).toBeCloseTo(0.05);
  });

  it('ignores costs at or below COST_EPSILON', () => {
    const messages = [
      msg({ estimatedCost: COST_EPSILON }),
      msg({ estimatedCost: 0.000005 }),
      msg({ estimatedCost: 0.01 }),
    ];
    expect(usdTotal(messages)).toBeCloseTo(0.01);
  });

  it('sums the cost of several messages correctly', () => {
    const messages = [
      msg({ estimatedCost: 0.05 }),
      msg({ estimatedCost: 0.10 }),
      msg({ estimatedCost: 0.03 }),
    ];
    expect(usdTotal(messages)).toBeCloseTo(0.18);
  });

  it('user message cost is counted too, as long as its state is delivered', () => {
    const messages = [
      msg({ role: 'user', estimatedCost: 0, state: 'delivered' }),
      msg({ role: 'assistant', estimatedCost: 0.05, state: 'delivered' }),
    ];
    expect(usdTotal(messages)).toBeCloseTo(0.05);
  });

  it('cost goes down after a message is deleted', () => {
    const m1 = msg({ estimatedCost: 0.05 });
    const m2 = msg({ estimatedCost: 0.10 });
    const m3 = msg({ estimatedCost: 0.03 });

    const allThree = usdTotal([m1, m2, m3]);
    const afterDelete = usdTotal([m1, m3]);

    expect(allThree).toBeCloseTo(0.18);
    expect(afterDelete).toBeCloseTo(0.08);
  });
});

describe('recalculateConversationCostTotals (non-USD currencies)', () => {
  it('USD only sums estimatedCost; non-USD sums per currency, only delivered messages count, and unavailable amounts are skipped', () => {
    const totals = recalculateConversationCostTotals([
      msg({ estimatedCost: 0.25, nonUsdCost: { currencyCode: 'CNY', amount: 0.12, costSource: 'localEstimate' } }),
      msg({ estimatedCost: 0, nonUsdCost: { currencyCode: 'CNY', amount: 3.5, costSource: 'localEstimate' } }),
      msg({ estimatedCost: 0, state: 'failed', nonUsdCost: { currencyCode: 'CNY', amount: 9, costSource: 'localEstimate' } }),
      msg({ estimatedCost: 0, nonUsdCost: { currencyCode: 'EUR', amount: 0, costSource: 'unknown' } }),
    ], null);
    expect(totals.estimatedCost).toBeCloseTo(0.25);
    expect(Object.keys(totals.nonUsdCostTotals ?? {})).toEqual(['CNY']);
    expect(totals.nonUsdCostTotals?.CNY).toBeCloseTo(3.62);
  });

  it('carries no nonUsdCostTotals key when there is no non-USD part', () => {
    const totals = recalculateConversationCostTotals([msg({ estimatedCost: 0.05 })], null);
    expect(totals).toEqual({ estimatedCost: 0.05 });
  });
});
