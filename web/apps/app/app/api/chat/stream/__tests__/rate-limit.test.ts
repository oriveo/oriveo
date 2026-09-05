import { describe, it, expect, beforeEach } from 'vitest';
import {
  checkRateLimit,
  getClientIp,
  buildRateLimitHeaders,
  __resetRateLimitForTests,
  RATE_LIMIT_CONFIG,
} from '../rate-limit';

beforeEach(() => {
  __resetRateLimitForTests();
});

describe('checkRateLimit', () => {
  it('allows the first request, with remaining = limit - 1', () => {
    const r = checkRateLimit('1.1.1.1', 1_000_000);
    expect(r.allowed).toBe(true);
    expect(r.remaining).toBe(RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW - 1);
    expect(r.limit).toBe(RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW);
  });

  it('accumulates the count across requests inside the window', () => {
    for (let i = 0; i < 10; i++) {
      const r = checkRateLimit('2.2.2.2', 1_000_000 + i);
      expect(r.allowed).toBe(true);
      expect(r.remaining).toBe(RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW - 1 - i);
    }
  });

  it('returns allowed=false past the limit', () => {
    const now = 1_000_000;
    for (let i = 0; i < RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW; i++) {
      checkRateLimit('3.3.3.3', now + i);
    }
    const denied = checkRateLimit('3.3.3.3', now + RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW);
    expect(denied.allowed).toBe(false);
    expect(denied.remaining).toBe(0);
  });

  it('expires requests outside the window and allows the next one', () => {
    const now = 1_000_000;
    for (let i = 0; i < RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW; i++) {
      checkRateLimit('4.4.4.4', now + i);
    }
    // Rejected as soon as the window hits the limit
    expect(checkRateLimit('4.4.4.4', now + 100).allowed).toBe(false);

    // Wait for the window to fully expire
    const future = now + RATE_LIMIT_CONFIG.WINDOW_MS + 1;
    const allowed = checkRateLimit('4.4.4.4', future);
    expect(allowed.allowed).toBe(true);
  });

  it('keeps different IPs independent', () => {
    const now = 1_000_000;
    for (let i = 0; i < RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW; i++) {
      checkRateLimit('5.5.5.5', now + i);
    }
    // 5.5.5.5 is over the limit
    expect(checkRateLimit('5.5.5.5', now + 100).allowed).toBe(false);
    // 6.6.6.6 is unaffected
    expect(checkRateLimit('6.6.6.6', now + 100).allowed).toBe(true);
  });

  it('points resetAt at the earliest timestamp + WINDOW_MS when rejecting', () => {
    const now = 1_000_000;
    checkRateLimit('7.7.7.7', now);
    for (let i = 1; i < RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW; i++) {
      checkRateLimit('7.7.7.7', now + i);
    }
    const denied = checkRateLimit('7.7.7.7', now + 1000);
    expect(denied.resetAt).toBe(now + RATE_LIMIT_CONFIG.WINDOW_MS);
  });
});

describe('getClientIp', () => {
  it('takes the last hop of X-Forwarded-For, the real peer written by the single trusted proxy', () => {
    // The list appends from far to near as client, proxy1, and with one trusted proxy the rightmost segment is used
    const h = new Headers({ 'x-forwarded-for': '10.0.0.1, 203.0.113.9' });
    expect(getClientIp(h)).toBe('203.0.113.9');
  });

  it('cannot be moved to another rate-limit bucket by forging the leftmost X-Forwarded-For entry', () => {
    // An attacker injects a different forged IP on the left each time, but the rightmost segment written by the trusted proxy stays the same
    const a = new Headers({ 'x-forwarded-for': '1.2.3.4, 203.0.113.9' });
    const b = new Headers({ 'x-forwarded-for': '5.6.7.8, 9.9.9.9, 203.0.113.9' });
    expect(getClientIp(a)).toBe('203.0.113.9');
    expect(getClientIp(b)).toBe('203.0.113.9');
  });

  it('uses the single segment directly when XFF has only one', () => {
    const h = new Headers({ 'x-forwarded-for': '198.51.100.1' });
    expect(getClientIp(h)).toBe('198.51.100.1');
  });

  it('falls back to X-Real-IP when X-Forwarded-For is missing', () => {
    const h = new Headers({ 'x-real-ip': '198.51.100.1' });
    expect(getClientIp(h)).toBe('198.51.100.1');
  });

  it('returns unknown when neither header is present', () => {
    expect(getClientIp(new Headers())).toBe('unknown');
  });
});

describe('buildRateLimitHeaders', () => {
  it('returns the standard X-RateLimit-* headers', () => {
    const outcome = checkRateLimit('8.8.8.8', 5_000_000);
    const headers = buildRateLimitHeaders(outcome);
    expect(headers['X-RateLimit-Limit']).toBe(String(RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW));
    expect(Number(headers['X-RateLimit-Remaining'])).toBe(RATE_LIMIT_CONFIG.MAX_REQUESTS_PER_WINDOW - 1);
    expect(headers['X-RateLimit-Reset']).toBe(String(Math.ceil((5_000_000 + RATE_LIMIT_CONFIG.WINDOW_MS) / 1000)));
  });
});
