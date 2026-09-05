import type { ErrorEvent, Event } from "@sentry/nextjs";

/**
 * `/api/relay/forward` calls `controller.error()` and cuts the stream in three cases:
 * - idle timeout (90s without data by default)
 * - total duration cap (600s by default)
 * - response size beyond MAX_RESPONSE_BYTES, a forward route constant raised for image traffic
 *
 * These are deliberate server-side protections against a hostile or stalled upstream, not bugs.
 * The Next.js `nextjs.on_request_error` instrumentation still reports them to Sentry through the
 * cause chain, where they show up as `failed to pipe response` wrapping a
 * `Relay stream/response ...` cause. This filter recognises them and drops them so production
 * error monitoring stays clean.
 */
const RELAY_PROTECTIVE_PATTERNS = [
  /^Relay stream idle timeout/,
  /^Relay stream exceeded maximum duration/,
  /^Relay response exceeded the .* limit/,
] as const;

function matchesProtectivePattern(value: string | undefined): boolean {
  if (!value) return false;
  return RELAY_PROTECTIVE_PATTERNS.some((pattern) => pattern.test(value));
}

export function isIgnorableRelayProtectiveAbort(event: Event): boolean {
  const errorEvent = event as ErrorEvent;
  const values = errorEvent.exception?.values ?? [];
  // Any layer of the cause chain matching "Relay stream/response ..." counts as a controlled protective cut
  return values.some((entry) => matchesProtectivePattern(entry.value));
}

/**
 * When an upstream provider or relay resets the TLS connection mid-stream, or a mobile user
 * switches away or loses signal, the server gets a bare `ECONNRESET`; the undici fetch to the
 * upstream is aborted (`TypeError: terminated`) and the Next.js piping layer then throws
 * `failed to pipe response`. That chain happens in the framework after the handler has already
 * returned its Response, so application code physically cannot swallow it and should not try:
 * abort propagation is already correct. It is unavoidable network noise, and the same
 * interruption is what the client reports as `Provider upstream: Load failed`.
 *
 * Only applied to an allowlist of streaming routes, so a genuine server crash on a non-streaming
 * endpoint is still reported, and only when the chain carries a real disconnect signal
 * (ECONNRESET or an undici terminated), never on the surface `failed to pipe response` text.
 */
const STREAM_ROUTE_TRANSACTIONS = new Set<string>([
  "POST /api/chat/stream",
  "POST /api/relay/forward",
]);

const STREAM_DISCONNECT_PATTERNS = [
  /ECONNRESET/,
  /^terminated$/, // the undici fetch was aborted (client disconnect, or an upstream reset)
] as const;

function matchesDisconnectPattern(value: string | undefined): boolean {
  if (!value) return false;
  return STREAM_DISCONNECT_PATTERNS.some((pattern) => pattern.test(value));
}

export function isIgnorableStreamDisconnect(event: Event): boolean {
  // Streaming routes only; an ECONNRESET or a real 500 on a non-streaming endpoint is still reported
  if (!STREAM_ROUTE_TRANSACTIONS.has(event.transaction ?? "")) return false;
  const errorEvent = event as ErrorEvent;
  const values = errorEvent.exception?.values ?? [];
  return values.some((entry) => matchesDisconnectPattern(entry.value));
}
