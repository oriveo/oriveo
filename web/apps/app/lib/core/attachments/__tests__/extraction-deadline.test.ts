import { describe, expect, it } from 'vitest';
import { EXTRACTION_DEADLINE_MS, ExtractionDeadline } from '../extraction-deadline';
import { ExtractionError } from '../file-text-extractor';

function fakeClock(start = 1_000) {
  let now = start;
  return {
    now: () => now,
    advance: (ms: number) => { now += ms; },
  };
}

describe('ExtractionDeadline (spec section 14)', () => {
  it('default deadline is 30 seconds', () => {
    expect(EXTRACTION_DEADLINE_MS).toBe(30_000);
    const clock = fakeClock();
    expect(new ExtractionDeadline(clock.now).remainingMs).toBe(30_000);
  });

  it('check does not throw within the deadline; remaining time decreases with the clock', () => {
    const clock = fakeClock();
    const deadline = new ExtractionDeadline(clock.now);
    clock.advance(29_999);
    expect(deadline.expired).toBe(false);
    expect(deadline.remainingMs).toBe(1);
    expect(() => deadline.check()).not.toThrow();
  });

  it('times out at the deadline: check throws extraction_timeout, remaining time is 0', () => {
    const clock = fakeClock();
    const deadline = new ExtractionDeadline(clock.now);
    clock.advance(30_000);
    expect(deadline.expired).toBe(true);
    expect(deadline.remainingMs).toBe(0);
    const failure = (() => {
      try {
        deadline.check();
        return null;
      } catch (e) {
        return e;
      }
    })();
    expect(failure).toBeInstanceOf(ExtractionError);
    expect((failure as ExtractionError).code).toBe('extraction_timeout');
  });

  it('budget can be specified; uses performance.now() when no clock is injected', () => {
    const clock = fakeClock();
    const short = new ExtractionDeadline(clock.now, 5);
    clock.advance(5);
    expect(short.expired).toBe(true);

    const real = new ExtractionDeadline();
    expect(real.expired).toBe(false);
    expect(real.remainingMs).toBeGreaterThan(29_000);
  });
});
