import { describe, expect, it } from 'vitest';
import { formatCompactCost, formatUsageCost } from './usage-format';

// Platform currency output uses NBSP / NNBSP between amount and symbol; compare on plain spaces.
function normalize(text: string): string {
  return text.replace(/[‎‏؜]/g, '').replace(/[  ]/g, ' ');
}

describe('usage-format USD display', () => {
  it('formatUsageCost follows the de currency format with the "$" symbol', () => {
    expect(normalize(formatUsageCost(54.2, 'de'))).toBe('54,20 $');
  });

  it('formatUsageCost keeps the en-US output unchanged', () => {
    expect(formatUsageCost(54.2, 'en-US')).toBe('$54.20');
    expect(formatUsageCost(0.00005, 'en-US')).toBe('$0.00005');
  });

  it('formatCompactCost follows the de currency format and keeps its fraction tiers', () => {
    expect(normalize(formatCompactCost(0.5, 'de'))).toBe('0,50 $');
    expect(normalize(formatCompactCost(58.44, 'de'))).toBe('58,4 $');
  });

  it('formatCompactCost keeps the en-US tiers unchanged', () => {
    expect(formatCompactCost(0.001, 'en-US')).toBe('$0.0010');
    expect(formatCompactCost(5.234, 'en-US')).toBe('$5.23');
    expect(formatCompactCost(58.44, 'en-US')).toBe('$58.4');
    expect(formatCompactCost(120.4, 'en-US')).toBe('$120');
  });
});
