/**
 * Provider error reporting policy for Sentry.
 *
 * Drop user-visible provider/network kinds already shown in the UI
 * (invalidKey, unauthorized, quota, rateLimited, unavailable). Drop
 * transport failures classified as network. Keep unexpected local
 * failures such as emptyResponse / emptyModelCatalog / subscription
 * unavailable kinds that are not explained by a provider body.
 */

import { networkError, type ProviderError } from '../providers/errors';
import { isTransportFailure } from '../reachability/transport-failure';
import {
  PROVIDER_ERROR_DETAIL_MAX,
  attachProviderErrorDetail,
  attachProviderErrorSource,
  type ErrorWithProviderDetail,
} from '../../sentry/provider-error-detail';

const NON_REPORTABLE_PROVIDER_ERROR_KINDS = new Set<string>([
  'invalidKey',
  'unauthorized',
  'quotaExceeded',
  'badRequest',
  // The 429 family: model cooldowns and per-vendor rate limits. The user action is to wait or
  // switch models, which the error card already offers, and there is nothing to fix on the
  // engineering side. BYOK/Relay 429s stay classified as provider rate limits.
  'rateLimited',
  // A user-supplied custom request field the server compiler rejected: fail-closed is by design and the way out is to fix the JSON.
  'customRequestFieldsRejected',
  // Subscription-login account states: plan tier too low, authorisation expired, or this period's
  // quota used up. The user resolves all three in the vendor console.
  // `*SubscriptionUnavailable` is deliberately absent: it means a missing metadata recipe or a raised
  // client-version floor, which is a configuration defect and must keep being reported.
  'grokSubscriptionIneligible',
  'grokSubscriptionExpired',
  'grokSubscriptionQuotaExhausted',
  'openAISubscriptionIneligible',
  'openAISubscriptionExpired',
  'openAISubscriptionQuotaExhausted',
  // Transport failures: the client cannot connect, or the relay drops mid-stream. There is
  // nothing the user can act on, so these are silenced by kind rather than by string-matching
  // volatile text. Both an initial connection failure and a mid-stream reset in sse-parser are
  // already classified as network.
  'network',
]);

export function shouldReportProviderError(err: unknown): boolean {
  // A bare fetch failure has no kind at all, so it must be checked before the `typeof pe.kind !== 'string'` line below.
  if (isTransportFailure(err)) return false;
  const pe = err as ProviderError | undefined;
  if (!pe || typeof pe !== 'object' || typeof pe.kind !== 'string') return true;
  if (pe.source === 'provider' || pe.source === 'network') return false;
  if (NON_REPORTABLE_PROVIDER_ERROR_KINDS.has(pe.kind)) return false;
  return true;
}

/**
 * Normalisation shared by the send and continue catch blocks.
 *
 * It does exactly one thing: map bare transport failures that do not carry a kind yet onto the
 * `network` semantics. The chat stream is not the only network I/O on the send path; library
 * evidence fetches, knowledge retrieval and metadata / model-facts requests sit in the same try
 * block and none of them wraps a fetch failure into a ProviderError. Skipping the normalisation lets
 * `mapErrorKindKey(undefined)` fall back to `upstream`, so "your network is down" is shown to the
 * user as "the AI provider is having trouble, please try again later".
 *
 * Errors that already carry a kind are returned untouched: this is not a second classifier, the real
 * classification happens at each throw site.
 */
export function normalizeChatFailure(err: unknown): ProviderError {
  const pe = err as ProviderError | undefined;
  if (isTransportFailure(err) && typeof pe?.kind !== 'string') {
    return networkError(err);
  }
  return pe as ProviderError;
}

export function createProviderSentryError(err: unknown): Error {
  const pe = err as ProviderError | undefined;
  if (!pe || typeof pe !== 'object' || typeof pe.kind !== 'string') {
    return err instanceof Error ? err : new Error(String(err));
  }

  const label = pe.title?.trim() || pe.message?.trim() || 'Provider error';
  const sentryError = new Error(`Provider ${pe.kind}: ${label}`) as ErrorWithProviderDetail;
  sentryError.name = 'ProviderError';
  // Only failures that are the app's own responsibility reach here; beforeSend lifts detail into event.extra to help diagnosis.
  attachProviderErrorDetail(sentryError, pe.detail);
  attachProviderErrorSource(sentryError, pe.source);
  return sentryError;
}

/**
 * Stable grouping and diagnostic fields for a Sentry report. Only the low-cardinality provider and
 * error code are used, so that every ProviderError is not folded into a single issue by its shared
 * wrapper stack.
 */
export function buildProviderSentryContext(providerKind: string, err: unknown): {
  fingerprint: string[];
  extra?: { providerErrorDetail: string };
} {
  const pe = err as ProviderError | undefined;
  const errorKind = pe && typeof pe === 'object' && typeof pe.kind === 'string'
    ? pe.kind
    : 'non_provider';
  const managedCode = pe && typeof pe === 'object' && typeof pe.managedErrorCode === 'string'
    ? pe.managedErrorCode.trim()
    : '';
  const detail = pe && typeof pe === 'object' && typeof pe.detail === 'string'
    ? pe.detail.slice(0, PROVIDER_ERROR_DETAIL_MAX)
    : '';

  return {
    fingerprint: ['provider-error', providerKind, managedCode || errorKind],
    ...(detail ? { extra: { providerErrorDetail: detail } } : {}),
  };
}
