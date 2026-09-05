import { describe, expect, it } from 'vitest';
import { isRscNotFoundInvariantEvent } from '../ignore-rsc-invariant';
import type { SentryEventLike } from '../types';

describe('isRscNotFoundInvariantEvent', () => {
  it('matches the Next.js RSC not-found framework noise (exception.value)', () => {
    const event: SentryEventLike = {
      exception: {
        values: [
          {
            value:
              'Invariant: Expected RSC response, got text/html; charset=utf-8. This is a bug in Next.js.',
          },
        ],
      },
    };
    expect(isRscNotFoundInvariantEvent(event)).toBe(true);
  });

  it('matches the event.message shape as well', () => {
    const event: SentryEventLike = {
      message: 'Invariant: Expected RSC response, got text/html; charset=utf-8.',
    };
    expect(isRscNotFoundInvariantEvent(event)).toBe(true);
  });

  it('does not swallow a real application error', () => {
    const event: SentryEventLike = {
      exception: { values: [{ value: 'TypeError: Cannot read properties of undefined' }] },
    };
    expect(isRscNotFoundInvariantEvent(event)).toBe(false);
  });

  it('an empty event does not match', () => {
    expect(isRscNotFoundInvariantEvent({})).toBe(false);
  });
});
