import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  COST_EPSILON,
  evaluateExpensiveModelMultiplier,
  formatCost,
  formatPerMillionPrice,
  formatRelativeTime,
  getDateTimeFormatter,
  getNumberFormatter,
} from '../format-utils';

describe('COST_EPSILON', () => {
  it('is 0.00001', () => {
    expect(COST_EPSILON).toBe(0.00001);
  });
});

describe('formatCost', () => {
  // ── Empty, zero and invalid values become an empty string ─────────────────────────

  it('returns an empty string for 0', () => {
    expect(formatCost(0, 'en')).toBe('');
  });

  it('returns an empty string for 0', () => {
    expect(formatCost(-1, 'en')).toBe('');
  });

  it('returns an empty string for 0', () => {
    expect(formatCost(NaN, 'en')).toBe('');
  });

  it('returns an empty string for 0', () => {
    expect(formatCost(Infinity, 'en')).toBe('');
  });

  it('returns an empty string for 0', () => {
    expect(formatCost(COST_EPSILON, 'en')).toBe('');
  });

  // ── Very small amounts keep 5 decimal places ───────────────────────────────────────

  it('returns the actual amount just above epsilon', () => {
    expect(formatCost(0.00002, 'en')).toBe('$0.00002');
  });

  it('returns the actual amount just above epsilon', () => {
    expect(formatCost(0.00009, 'en')).toBe('$0.00009');
  });

  // ── Small amounts become "$X.XXXX" with 4 decimal places ──────────────────────────────

  it('formats 0.0001 as $0.0001', () => {
    expect(formatCost(0.0001, 'en')).toBe('$0.0001');
  });

  it('formats 0.0001 as $0.0001', () => {
    expect(formatCost(0.0023, 'en')).toBe('$0.0023');
  });

  // ── Ordinary amounts become "$X.XX" with 2 decimal places ──────────────────────────────

  it('formats the 0.01 boundary as $0.01', () => {
    expect(formatCost(0.01, 'en')).toBe('$0.01');
  });

  it('1.005 rounds half away from zero to $1.01', () => {
    expect(formatCost(1.005, 'en')).toBe('$1.01');
  });

  it('formats the 0.01 boundary as $0.01', () => {
    expect(formatCost(0.05, 'en')).toBe('$0.05');
  });

  it('formats the 0.01 boundary as $0.01', () => {
    expect(formatCost(1.50, 'en')).toBe('$1.50');
  });

  it('formats the 0.01 boundary as $0.01', () => {
    expect(formatCost(99.99, 'en')).toBe('$99.99');
  });

  it('uses the de platform currency format with the symbol forced to $', () => {
    const normalize = (text: string) => text.replace(/[\u00a0\u202f]/g, ' ');
    expect(normalize(formatCost(1234.5, 'de'))).toBe('1.234,50 $');
    expect(normalize(formatCost(0.0023, 'de'))).toBe('0,0023 $');
    expect(formatCost(0, 'de')).toBe('');
  });
});

describe('formatPerMillionPrice', () => {
  it('shows the actual amount for a tiny unit price, without a less-than sign', () => {
    expect(formatPerMillionPrice(0.000000001)).toBe('$0.001/M');
  });

  it('non-USD and USD share the same digit rules (3 significant digits, no decimals for integers); symbol placement and separators follow the UI locale', () => {
    expect(formatPerMillionPrice(0.000_004)).toBe('$4/M');
    expect(formatPerMillionPrice(0.000_004, 'CNY', 'en')).toBe('CN¥4/M');
    expect(formatPerMillionPrice(0.000_004, 'CNY', 'zh-CN')).toBe('¥4/M');
    expect(formatPerMillionPrice(0.000_004, 'CNY', 'de')).toBe('4\u00a0CN¥/M');
    expect(formatPerMillionPrice(0.000_000_6, 'CNY', 'en')).toBe('CN¥0.6/M');
    expect(formatPerMillionPrice(0.000_000_6, 'CNY', 'de')).toBe('0,6\u00a0CN¥/M');
    expect(formatPerMillionPrice(0.001_234_5)).toBe('$1,230/M');
    expect(formatPerMillionPrice(0.001_234_5, 'CNY', 'en')).toBe('CN¥1,230/M');
    expect(formatPerMillionPrice(0.001_234_5, 'CNY', 'zh-CN')).toBe('¥1,230/M');
    expect(formatPerMillionPrice(0.001_234_5, 'CNY', 'de')).toBe('1.230\u00a0CN¥/M');
    expect(formatPerMillionPrice(0.000_000_001_234_5, 'CNY', 'zh-CN')).toBe('¥0.00123/M');
  });
});

describe('evaluateExpensiveModelMultiplier', () => {
  it('returns the integer multiplier when it is above 5', () => {
    expect(evaluateExpensiveModelMultiplier(0.001, 0.007)).toBe(7);
  });

  it('returns 5 when the multiplier is just above 5', () => {
    expect(evaluateExpensiveModelMultiplier(0.001, 0.0051)).toBe(5);
  });

  it('returns null at a multiplier of exactly 5, so nothing is triggered', () => {
    expect(evaluateExpensiveModelMultiplier(0.001, 0.005)).toBeNull();
  });

  it('returns null for a multiplier below 5', () => {
    expect(evaluateExpensiveModelMultiplier(0.001, 0.003)).toBeNull();
  });

  it('returns null when the old price is undefined', () => {
    expect(evaluateExpensiveModelMultiplier(undefined, 0.007)).toBeNull();
  });

  it('returns null when the new price is undefined', () => {
    expect(evaluateExpensiveModelMultiplier(0.001, undefined)).toBeNull();
  });

  it('returns null when the old price is 0', () => {
    expect(evaluateExpensiveModelMultiplier(0, 0.007)).toBeNull();
  });

  it('returns null when switching the other way, from cheap to cheaper', () => {
    expect(evaluateExpensiveModelMultiplier(0.007, 0.001)).toBeNull();
  });
});

describe('cached intl formatters', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('reuses number formatters for the same locale and options', () => {
    const left = getNumberFormatter('en-US', {
      style: 'decimal',
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
    const right = getNumberFormatter('en-US', {
      maximumFractionDigits: 2,
      minimumFractionDigits: 2,
      style: 'decimal',
    });

    expect(left).toBe(right);
  });

  it('reuses date formatters for the same locale and options', () => {
    const left = getDateTimeFormatter('en-US', {
      month: 'short',
      day: 'numeric',
      timeZone: 'UTC',
    });
    const right = getDateTimeFormatter('en-US', {
      timeZone: 'UTC',
      day: 'numeric',
      month: 'short',
    });

    expect(left).toBe(right);
  });

  it('formatRelativeTime reuses the same relative time formatter per locale', () => {
    const realRelativeTimeFormat = Intl.RelativeTimeFormat;
    const constructorSpy = vi.fn(function RelativeTimeFormatMock(
      locale?: string | string[],
      options?: Intl.RelativeTimeFormatOptions,
    ) {
      return new realRelativeTimeFormat(locale, options);
    });

    // @ts-expect-error test shim
    Intl.RelativeTimeFormat = constructorSpy;

    const now = new Date('2026-04-18T12:00:00.000Z').getTime();
    vi.spyOn(Date, 'now').mockReturnValue(now);

    expect(formatRelativeTime('2026-04-18T11:59:00.000Z', 'en-US')).toBe('1 min. ago');
    expect(formatRelativeTime('2026-04-18T11:58:00.000Z', 'en-US')).toBe('2 min. ago');
    expect(constructorSpy).toHaveBeenCalledTimes(1);
  });

  // Defensive against bad stored data: an invalid BCP-47 tag must not make Intl throw a RangeError and take the UI down
  it('getDateTimeFormatter falls back to the system default locale on an invalid locale instead of throwing', () => {
    expect(() => getDateTimeFormatter('chineseSimplified', { dateStyle: 'medium' })).not.toThrow();
    const formatter = getDateTimeFormatter('chineseSimplified', { dateStyle: 'medium' });
    // It should return a usable formatter, falling back to an undefined locale
    expect(typeof formatter.format(new Date('2026-04-18'))).toBe('string');
  });

  it('getNumberFormatter falls back to the system default locale on an invalid locale instead of throwing', () => {
    expect(() => getNumberFormatter('totally-not-a-locale', { minimumFractionDigits: 2 })).not.toThrow();
    const formatter = getNumberFormatter('totally-not-a-locale', { minimumFractionDigits: 2 });
    expect(typeof formatter.format(123)).toBe('string');
  });
});
