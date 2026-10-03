/**
 * Per-IP concurrency limit for MCP forwarding.
 *
 * The per-minute rate limit (60 requests / minute) bounds how fast requests are started, not how
 * many are open at once: a single forward can live for up to 10 minutes (the total stream duration
 * cap), so with the rate limit alone one IP could pile up 600 simultaneous upstream connections.
 * In normal use the concurrent MCP requests of one browser are the few tool calls of a single
 * model turn, so 8 is plenty.
 *
 * Like the rate limiter this uses a Map on globalThis: enough for a single-instance deployment,
 * and it survives dev hot reloads.
 */
export const MAX_CONCURRENT_FORWARDS_PER_IP = 8;

declare global {
  var __oriveoMcpForwardInFlight: Map<string, number> | undefined;
}

function inFlight(): Map<string, number> {
  if (!globalThis.__oriveoMcpForwardInFlight) {
    globalThis.__oriveoMcpForwardInFlight = new Map();
  }
  return globalThis.__oriveoMcpForwardInFlight;
}

/**
 * Takes one concurrency slot. Returns the release function (safe to call repeatedly, it only takes
 * effect once), or null when all slots are taken.
 * The caller must make sure every path eventually releases it: the route covers this in two places,
 * the `finally` of its early returns and the settling of the response stream (fully read, errored,
 * cancelled or timed out).
 */
export function acquireForwardSlot(clientIp: string): (() => void) | null {
  const counts = inFlight();
  const current = counts.get(clientIp) ?? 0;
  if (current >= MAX_CONCURRENT_FORWARDS_PER_IP) return null;
  counts.set(clientIp, current + 1);
  let released = false;
  return () => {
    if (released) return;
    released = true;
    const remaining = (counts.get(clientIp) ?? 1) - 1;
    if (remaining <= 0) counts.delete(clientIp);
    else counts.set(clientIp, remaining);
  };
}

/** Number of slots an IP currently holds (for tests and troubleshooting). */
export function forwardSlotsInUse(clientIp: string): number {
  return inFlight().get(clientIp) ?? 0;
}

/** Test hook: clears every counter. Production code must not call it. */
export function __resetMcpForwardConcurrencyForTests(): void {
  globalThis.__oriveoMcpForwardInFlight = new Map();
}
