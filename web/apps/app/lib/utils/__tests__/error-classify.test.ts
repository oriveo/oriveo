import { describe, expect, it } from 'vitest';
import { isRateLimitError } from '../error-classify';

describe('isRateLimitError', () => {
  describe('classification by errorKind, the path new messages take', () => {
    it('returns true for rate limit, quota and model-unavailable kinds', () => {
      expect(isRateLimitError('rateLimited')).toBe(true);
      expect(isRateLimitError('quotaExceeded')).toBe(true);
      expect(isRateLimitError('unavailable')).toBe(true);
    });

    it('returns false for kinds that switching models cannot fix', () => {
      expect(isRateLimitError('invalidKey')).toBe(false);
      expect(isRateLimitError('network')).toBe(false);
      expect(isRateLimitError('badRequest')).toBe(false);
    });

    it('stops looking at the localized title text once a kind is present', () => {
      // In a localized UI errorTitle is translated, so matching English keywords is bound to
      // miss; conversely a title containing "quota" must not make a non-quota error look like
      // one that a different model would fix.
      expect(isRateLimitError('network', 'Quota exceeded')).toBe(false);
      expect(isRateLimitError('quotaExceeded', '\u4f9b\u5e94\u5546\u989d\u5ea6\u5df2\u7528\u5b8c')).toBe(true);
    });
  });

  describe('historical messages without an errorKind fall back to text matching', () => {
    it('returns true when the title contains a rate limit or quota keyword', () => {
      expect(isRateLimitError(undefined, 'Rate limit exceeded')).toBe(true);
      expect(isRateLimitError(undefined, 'Quota exceeded')).toBe(true);
      expect(isRateLimitError(undefined, 'Error 429')).toBe(true);
      expect(isRateLimitError(undefined, 'Insufficient credits')).toBe(true);
    });

    it('also counts a match in detail, with an empty title', () => {
      expect(isRateLimitError(undefined, undefined, 'You have exceeded your limit')).toBe(true);
    });

    it('is case insensitive', () => {
      expect(isRateLimitError(undefined, 'RATE LIMIT')).toBe(true);
    });

    it('returns false for an ordinary error', () => {
      expect(isRateLimitError(undefined, 'Network error', 'Connection refused')).toBe(false);
      expect(isRateLimitError()).toBe(false);
      expect(isRateLimitError(undefined, '', '')).toBe(false);
    });
  });
});
