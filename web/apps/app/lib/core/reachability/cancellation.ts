/**
 * Decide whether a remote failure is actually a cancellation (the user stopped generation / closed the page / the task was cancelled / an explicit unsubscribe).
 * A cancellation is not a backend failure: filter with this before reporting reachability, and report nothing and leave the reachability state alone.
 */
export function isCancellationError(error: unknown, signal?: AbortSignal | null): boolean {
  // A timeout (AbortSignal.timeout -> TimeoutError) means the backend did not respond in time, not a cancellation, so it is reported as before.
  if (isTimeout(error) || (signal?.aborted && isTimeout(signal.reason))) return false;
  if (signal?.aborted) return true;
  if (typeof error !== 'object' || error === null) return false;
  const { name, code } = error as { name?: unknown; code?: unknown };
  // AbortError: fetch / AbortController; cancelled: the cancellation codes of Firestore and gRPC (including an explicit unsubscribe).
  return name === 'AbortError' || code === 'cancelled' || code === 'firestore/cancelled';
}

function isTimeout(value: unknown): boolean {
  return typeof value === 'object' && value !== null && (value as { name?: unknown }).name === 'TimeoutError';
}
