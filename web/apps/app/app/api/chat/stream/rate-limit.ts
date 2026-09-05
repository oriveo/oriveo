/**
 * Per-IP in-memory sliding-window rate limit.
 *
 * Trade-offs:
 * - With BYOK the user brings their own apiKey, so this mainly guards against traffic floods
 *   saturating the server's egress rather than protecting billing, which the provider handles.
 * - Deployment is a single instance behind a reverse proxy, so an in-memory Map is enough. It is
 *   not strict across multiple regions, but it is still a useful first line.
 * - 60s window, 60 req/IP: a normal conversation issues 1-3 req/min, leaving 20x of headroom.
 *
 * The Map is a module-level singleton cached on globalThis so HMR and dev hot-reload do not reset
 * the counters.
 */

const WINDOW_MS = 60_000;
const MAX_REQUESTS_PER_WINDOW = 60;

interface RateLimitBucket {
  /** Timestamps of recent requests in ms, sorted oldest to newest */
  timestamps: number[];
}

declare global {
  var __oriveoChatStreamRateBuckets: Map<string, RateLimitBucket> | undefined;
}

function getBuckets(): Map<string, RateLimitBucket> {
  if (!globalThis.__oriveoChatStreamRateBuckets) {
    globalThis.__oriveoChatStreamRateBuckets = new Map();
  }
  return globalThis.__oriveoChatStreamRateBuckets;
}

export interface RateLimitOutcome {
  allowed: boolean;
  /** Reset epoch ms (when oldest timestamp ages out of window) */
  resetAt: number;
  /** Remaining allowance after this request (allowed=true) or 0 (allowed=false) */
  remaining: number;
  /** Total cap */
  limit: number;
}

/**
 * Check and count a request from an IP. The outcome carries allowed / remaining / resetAt.
 *
 * Callers should answer 429 with the standard RateLimit headers when `allowed === false`.
 */
export function checkRateLimit(ip: string, now: number = Date.now()): RateLimitOutcome {
  const buckets = getBuckets();
  const bucket = buckets.get(ip) ?? { timestamps: [] };
  const windowStart = now - WINDOW_MS;

  // Drop the timestamps that have aged out of the window.
  while (bucket.timestamps.length > 0 && bucket.timestamps[0] < windowStart) {
    bucket.timestamps.shift();
  }

  if (bucket.timestamps.length >= MAX_REQUESTS_PER_WINDOW) {
    // Denied: resetAt is when the oldest timestamp in the window expires.
    buckets.set(ip, bucket);
    return {
      allowed: false,
      resetAt: bucket.timestamps[0] + WINDOW_MS,
      remaining: 0,
      limit: MAX_REQUESTS_PER_WINDOW,
    };
  }

  bucket.timestamps.push(now);
  buckets.set(ip, bucket);

  return {
    allowed: true,
    resetAt: now + WINDOW_MS,
    remaining: MAX_REQUESTS_PER_WINDOW - bucket.timestamps.length,
    limit: MAX_REQUESTS_PER_WINDOW,
  };
}

/**
 * Deployment assumption: this service runs behind a fixed number of trusted reverse proxies, one
 * nginx or caddy layer by default. X-Forwarded-For is `client, proxy1, ..., proxyN`, appended left
 * to right from farthest to nearest, so the rightmost entry is the real peer IP written by the
 * nearest trusted proxy.
 *
 * Security point: the leftmost value is entirely client-controlled, so an attacker sending
 * `X-Forwarded-For: <random IP>` could forge a different IP per request and slip past per-IP
 * limiting. The value must therefore be counted a fixed number of hops from the right, never taken
 * from the left.
 *
 * The hop count comes from TRUSTED_PROXY_HOP_COUNT (default 1); the Nth entry from the end of the
 * XFF list is used.
 */
const TRUSTED_PROXY_HOP_COUNT = (() => {
  const raw = Number(process.env.TRUSTED_PROXY_HOP_COUNT);
  return Number.isInteger(raw) && raw >= 1 ? raw : 1;
})();

/**
 * Read the client IP from the headers. Prefers the Nth-from-last hop of X-Forwarded-For, where N is
 * the trusted proxy depth, then falls back to X-Real-IP and finally to 'unknown', where all such
 * requests share one bucket.
 */
export function getClientIp(headers: Headers): string {
  const xff = headers.get('x-forwarded-for');
  if (xff) {
    const hops = xff.split(',').map((part) => part.trim()).filter(Boolean);
    if (hops.length > 0) {
      // Take the Nth hop from the end, N being the trusted proxy count. If the chain is shorter than that, fall back to the rightmost value, which is closest to the nearest trusted proxy.
      const index = Math.max(0, hops.length - TRUSTED_PROXY_HOP_COUNT);
      const candidate = hops[index];
      if (candidate) return candidate;
    }
  }
  const realIp = headers.get('x-real-ip');
  if (realIp) return realIp.trim();
  return 'unknown';
}

export function buildRateLimitHeaders(outcome: RateLimitOutcome): Record<string, string> {
  return {
    'X-RateLimit-Limit': String(outcome.limit),
    'X-RateLimit-Remaining': String(outcome.remaining),
    'X-RateLimit-Reset': String(Math.ceil(outcome.resetAt / 1000)),
  };
}

/** Test hook: clear every bucket. Not for use in production code. */
export function __resetRateLimitForTests(): void {
  globalThis.__oriveoChatStreamRateBuckets = new Map();
}

export const RATE_LIMIT_CONFIG = {
  WINDOW_MS,
  MAX_REQUESTS_PER_WINDOW,
} as const;
