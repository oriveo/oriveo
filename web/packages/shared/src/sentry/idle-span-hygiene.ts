/**
 * Pageload and navigation transactions are idle spans: they stay open while any child span is in
 * flight (one child can hold them for childSpanTimeout, 15s; the hard cap is finalTimeout, 30s).
 *
 * Long-lived Firestore channels, streaming chat requests and the Cloudflare RUM beacon routinely
 * outlive the page load, stretching navigations to 10-30s while LCP is already 1.4-2.1s. Their
 * duration depends on connection lifetime or model output, not on loading the page, so no span is
 * created for them and the transaction ends when the page is actually idle. Trace headers are still
 * propagated (propagation follows tracePropagationTargets), so server transactions stay linked.
 */
const LONG_LIVED_REQUEST_PATTERNS: readonly RegExp[] = [
  // Firestore WebChannel: Listen is a long poll, Write is a persistent write channel.
  /firestore\.googleapis\.com\/google\.firestore\.v1\.Firestore\/(?:Listen|Write)\/channel/,
  // Streaming model output: /api/chat/stream, /api/managed/chat/stream, /api/free/chat/stream.
  /\/api\/(?:managed\/|free\/)?chat\/stream(?:[/?#]|$)/,
  /\/api\/relay\/forward(?:[/?#]|$)/,
  // Cloudflare Web Analytics beacon, sent after the load event.
  /\/cdn-cgi\/rum(?:[/?#]|$)/,
];

export function shouldCreateSpanForBrowserRequest(url: string): boolean {
  return !LONG_LIVED_REQUEST_PATTERNS.some((pattern) => pattern.test(url));
}

export interface SentryTransactionEventLike {
  type?: string;
  contexts?: {
    trace?: { op?: string; status?: string };
  } & Record<string, unknown>;
}

/**
 * When the tab goes to the background the SDK marks the idle transaction cancelled
 * (markBackgroundSpan). Background timers are throttled by the browser, so those durations are not
 * comparable; dropping them keeps pageload / navigation percentiles to foreground loads only.
 */
export function isBackgroundedIdleTransaction(event: SentryTransactionEventLike): boolean {
  const trace = event.contexts?.trace;
  if (!trace || trace.status !== 'cancelled') return false;
  return trace.op === 'pageload' || trace.op === 'navigation';
}
