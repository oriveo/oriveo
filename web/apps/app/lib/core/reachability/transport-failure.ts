/**
 * Browser transport failure detection: unreachable, aborted or timed out.
 *
 * When a request never leaves the browser or the connection drops, `fetch()` throws a bare
 * `TypeError` with no status, no body and no structured marker, and every engine words it
 * differently: Chrome `Failed to fetch`, Safari `Load failed`, Firefox
 * `NetworkError when attempting to fetch resource` (Sentry events also add a host suffix, such as
 * `Failed to fetch (api.localhost)`).
 *
 * That is why this narrows on known messages instead of testing `instanceof TypeError`: a bare type
 * check would swallow real code defects (`x is not a function`, reading a property of null) as "the
 * user went offline", which is exactly the class of error that must not be silenced. Cancellation
 * (`AbortError`) and timeout (`TimeoutError`) are matched on `name` instead, which does not depend
 * on wording.
 *
 * Two callers, same meaning:
 *  - Normalization: turn a bare TypeError into a `kind: 'network'` ProviderError so the failure
 *    card says "network error, check your connection" rather than "provider error".
 *  - Sentry gate: a transport failure is an expected user-environment event with nothing to act on,
 *    so it is not reported as an error (Sentry's fetch instrumentation still leaves a breadcrumb).
 */

/** Known per-browser messages for a failed fetch connection, compared lowercase and allowing a host suffix. */
const FETCH_FAILURE_MESSAGES = [
  'failed to fetch',
  'load failed',
  'networkerror when attempting to fetch resource',
  'network request failed',
] as const;

export function isTransportFailure(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false;
  const name = (error as { name?: unknown }).name;
  // Cancellation and timeout come from the DOMException name, which is stable across engines and independent of wording.
  if (name === 'AbortError' || name === 'TimeoutError') return true;
  // Use name rather than `instanceof TypeError`: instanceof gives false negatives across realms
  // (iframe, worker, test host), while name is fixed by the specification.
  if (name !== 'TypeError') return false;
  const message = (error as { message?: unknown }).message;
  if (typeof message !== 'string') return false;
  const normalized = message.toLowerCase();
  return FETCH_FAILURE_MESSAGES.some((needle) => normalized.includes(needle));
}
