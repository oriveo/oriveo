/**
 * A non-silent fallback for fire-and-forget best-effort promises that would otherwise
 * swallow errors with `.catch(() => {})`: console.warn plus a Sentry breadcrumb.
 *
 * A breadcrumb rather than captureException, because these are background operations that
 * do not block the main flow - usage reporting, attachment cleanup, sync writes - and a
 * single failure does not deserve an issue. Complete silence, however, would hide the "it
 * was called but nothing happened" class of problem in production. The breadcrumb rides
 * along with a real captureException when one occurs, which makes the root cause easier to
 * follow.
 *
 * Reuses the existing @sentry/nextjs pipeline rather than adding another mechanism.
 */
import * as Sentry from '@sentry/nextjs';

function describeError(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

/** Report a non-fatal error that would otherwise be silently swallowed. */
export function reportSilentError(context: string, error: unknown): void {
  console.warn(`[${context}]`, error);
  Sentry.addBreadcrumb({
    category: 'fire-and-forget',
    level: 'warning',
    message: context,
    data: { error: describeError(error) },
  });
}

/**
 * Higher-order wrapper returning a handler that can be passed straight to `Promise.catch`,
 * replacing a silent `.catch(() => {})`.
 * Usage: `somePromise.catch(withErrorReporting('domain.action'))`
 */
export function withErrorReporting(context: string): (error: unknown) => void {
  return (error) => reportSilentError(context, error);
}
