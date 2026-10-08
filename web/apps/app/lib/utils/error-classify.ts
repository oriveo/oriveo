/**
 * Message error classification: decide whether an error is a rate-limit or quota failure, which is what offers the "switch model" recovery action.
 */

import { isSubscriptionErrorKind } from '@oriveo/core/providers/errors';

/** Failure kinds that switching models may work around: rate limit, quota, model unavailable. */
const MODEL_SWITCH_WORTHY_KINDS = new Set<string>([
  'rateLimited',
  'quotaExceeded',
  'unavailable',
]);

export function isRateLimitError(
  errorKind?: string,
  errorTitle?: string,
  errorDetail?: string,
): boolean {
  // Prefer the semantic identifier. errorTitle holds the localized text as it was at write time, so
  // matching English keywords against it is guaranteed to miss in any non-English UI, and those users
  // would never see the "switch model" recovery action.
  // Every subscription sign-in failure, for both vendors (configuration needs updating, plan too
  // low, authorization expired, period quota used up), can be continued at once with a model that
  // does not go through that subscription.
  if (errorKind) return MODEL_SWITCH_WORTHY_KINDS.has(errorKind) || isSubscriptionErrorKind(errorKind);
  // errorKind was added later, so messages stored before it fall back to text matching.
  const text = `${errorTitle ?? ''} ${errorDetail ?? ''}`.toLowerCase();
  return /rate|limit|quota|429|insufficient|exceeded/.test(text);
}
