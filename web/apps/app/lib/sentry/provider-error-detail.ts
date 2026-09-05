import type { Event, EventHint } from "@sentry/nextjs";
import type { ProviderErrorSource } from "@oriveo/shared";

/**
 * Supplies detail and source metadata for ProviderErrors that are the app's own responsibility.
 * Upstream responses with source=provider are dropped in beforeSend, so upstream bodies never reach Sentry.
 *
 * Path: `createProviderSentryError` attaches detail to the wrapper error, then `lift` in beforeSend
 * moves it from hint.originalException into `event.extra`.
 * extra rather than message/cause, because detail differs every time and would blow up error grouping.
 * It is not passed as extra at the captureException call sites because those are spread across many
 * operations files, whereas lifting it in beforeSend covers every provider error at once.
 */

/** detail is already whitelisted in errors.ts and fairly short; this hard cap is defence in depth. */
export const PROVIDER_ERROR_DETAIL_MAX = 1000;

export type ErrorWithProviderDetail = Error & {
  providerErrorDetail?: string;
  providerErrorSource?: ProviderErrorSource;
};

/** Attaches the truncated detail to the Sentry wrapper error; attaches nothing when detail is missing. */
export function attachProviderErrorDetail(
  error: ErrorWithProviderDetail,
  detail: string | undefined,
): void {
  if (!detail) return;
  error.providerErrorDetail = detail.slice(0, PROVIDER_ERROR_DETAIL_MAX);
}

export function attachProviderErrorSource(
  error: ErrorWithProviderDetail,
  source: ProviderErrorSource | undefined,
): void {
  if (!source) return;
  error.providerErrorSource = source;
}

/**
 * Defence in depth in beforeSend: even if a future call site forgets shouldReportProviderError,
 * upstream responses with source=provider must not reach Sentry. Handles both a directly captured
 * ProviderErrorObject and an Error wrapped by createProviderSentryError.
 */
export function isProviderResponseErrorHint(hint?: EventHint): boolean {
  const original = hint?.originalException as (ErrorWithProviderDetail & { source?: ProviderErrorSource }) | undefined;
  return original?.providerErrorSource === 'provider' || original?.source === 'provider';
}

/** beforeSend: lifts detail from the wrapper error into event.extra, or returns the event unchanged. */
// The generic keeps the concrete event type (ErrorEvent in, ErrorEvent out); widening it to Event
// makes the beforeSend return type mismatch the ErrorEvent | null the SDK expects, which only a full
// tsc run surfaces.
export function liftProviderErrorDetail<T extends Event>(event: T, hint?: EventHint): T {
  const original = hint?.originalException as ErrorWithProviderDetail | undefined;
  const detail = original?.providerErrorDetail;
  if (!detail) return event;
  event.extra = { ...event.extra, providerErrorDetail: detail };
  return event;
}
