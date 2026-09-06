import { extractErrorSnippet } from '../util/error-snippet';
import { classifyRelayHTTPError, isQuotaExhaustion, type RelayErrorContext } from './relay-error-classifier';
import type { ProviderErrorSource } from '@oriveo/shared/pure-types';
import { redactRelayCredentials } from '@oriveo/shared/relay/endpoint-policy';

/**
 * HTTP / SSE failures mapped to a user-facing ProviderError.
 * Quota, unauthorized, and unavailable kinds are generic and apply to any
 * user-owned API key.
 */
export type ProviderErrorKind =
  | 'invalidKey'
  | 'unauthorized'
  | 'badRequest'
  | 'quotaExceeded'
  | 'rateLimited'
  | 'unavailable'
  | 'network'
  | 'emptyResponse'
  | 'upstream'
  | 'emptyModelCatalog'
  // Specific to Grok subscription sign-in: the four failure modes call for completely different
  // user actions, and collapsing them into invalidKey/rateLimited would report "your xAI plan does
  // not allow third-party apps" as "your key is invalid", pointing the user the wrong way.
  | 'grokSubscriptionUnavailable'
  | 'grokSubscriptionIneligible'
  | 'grokSubscriptionExpired'
  | 'grokSubscriptionQuotaExhausted'
  // Specific to Codex (ChatGPT subscription sign-in). Not merged with the four Grok kinds: the
  // copy has to name which subscription and where to fix it ("your ChatGPT plan" versus "your xAI
  // plan"), and one generic wording would leave the user with nothing to act on.
  | 'openAISubscriptionUnavailable'
  | 'openAISubscriptionIneligible'
  | 'openAISubscriptionExpired'
  | 'openAISubscriptionQuotaExhausted';

export type ProviderErrorActionKind =
  | 'checkApiKey'
  | 'adjustRequest'
  | 'chooseDifferentModel'
  | 'waitOrRetry'
  | 'waitOrChangeProvider'
  | 'checkNetwork'
  | 'contactProvider'
  | 'none';

export type { ProviderErrorSource } from '@oriveo/shared/pure-types';

export type ProviderQuotaSource = 'provider' | 'entitlement' | 'unknown';

export type ProviderErrorSeverity = 'info' | 'warning' | 'error';

export interface ProviderErrorNextAction {
  kind: ProviderErrorActionKind;
  labelKey: string;
}

export interface ProviderError {
  kind: ProviderErrorKind;
  title: string;
  message: string;
  detail?: string;
  i18nKey?: 'moderation' | 'imageGenUser';
  // nextAction, retryable and source are optional: the web production toProviderError only emits
  // kind, title, message, detail and i18nKey, while desktop IPC rich errors carry these as well.
  // When to-ipc-error omits them they are derived from ERROR_CODE_META so the type stays uniform.
  nextAction?: ProviderErrorNextAction;
  retryable?: boolean;
  source?: ProviderErrorSource;
  severity?: ProviderErrorSeverity;
  status?: number;
  upstreamURL?: string;
  quotaSource?: ProviderQuotaSource;
  traceId?: string;
}

export class ProviderErrorObject extends Error implements ProviderError {
  readonly kind: ProviderErrorKind;
  readonly title: string;
  readonly detail?: string;
  readonly i18nKey?: 'moderation' | 'imageGenUser';
  readonly nextAction?: ProviderErrorNextAction;
  readonly retryable?: boolean;
  readonly source?: ProviderErrorSource;
  readonly severity?: ProviderErrorSeverity;
  readonly status?: number;
  readonly upstreamURL?: string;
  readonly quotaSource?: ProviderQuotaSource;
  readonly traceId?: string;

  constructor(error: ProviderError) {
    super(error.message);
    this.name = 'ProviderError';
    this.kind = error.kind;
    this.title = error.title;
    this.detail = error.detail;
    this.i18nKey = error.i18nKey;
    this.nextAction = error.nextAction;
    this.retryable = error.retryable;
    this.source = error.source;
    this.severity = error.severity;
    this.status = error.status;
    this.upstreamURL = error.upstreamURL;
    this.quotaSource = error.quotaSource;
    this.traceId = error.traceId;
  }
}

export function asProviderErrorObject(error: ProviderError): ProviderErrorObject {
  return error instanceof ProviderErrorObject ? error : new ProviderErrorObject(error);
}

/**
 * Map HTTP status / error to user-friendly ProviderError.
 *
 * Security hardening: `detail` is extracted through an allow list of
 * `error.{message,code,type}` and never contains the full raw body. This keeps prompt fragments
 * echoed by an upstream relay station, or SSE chunk tokens, from leaking through the detail field
 * into an error card, a screenshot or a support log. Note that `relayErrorContext` still passes
 * the trimmed body to the classifier for pattern matching, which happens only in memory and is
 * never surfaced in the UI.
 */
export function toProviderError(
  status: number,
  body: string,
  upstreamURL?: string,
  relayErrorContext?: RelayErrorContext,
  sensitiveCredentialValues: readonly string[] = [],
  classifyContext?: ProviderErrorClassifyContext,
): ProviderError {
  const classified = classifyProviderError(status, body, upstreamURL, relayErrorContext, classifyContext);
  // The four subscription failure kinds are explained here, because the upstream only replies
  // "Unauthorized" or "Forbidden"; using that as the body would turn "your plan does not support
  // this" into a line of English the user cannot act on.
  if (
    (classifyContext?.grokSubscriptionAuth && isGrokSubscriptionErrorKind(classified.kind)) ||
    (classifyContext?.openAISubscriptionAuth && isOpenAISubscriptionErrorKind(classified.kind))
  ) {
    return {
      ...classified,
      source: 'provider',
      status,
      ...(upstreamURL ? { upstreamURL } : {}),
    };
  }
  // When the upstream already gave a readable reason, that text (only redacted and length-capped)
  // is the single source of truth for the user-facing body. kind and title only carry structured
  // recovery semantics and must not overwrite the upstream text with a message of our own.
  const upstreamMessage = extractErrorSnippet(body.trim(), 500, sensitiveCredentialValues);
  return {
    ...classified,
    message: upstreamMessage ?? redactRelayCredentials(classified.message, sensitiveCredentialValues),
    detail: upstreamMessage
      ?? (classified.detail ? redactRelayCredentials(classified.detail, sensitiveCredentialValues) : undefined),
    source: 'provider',
    status,
    ...(upstreamURL ? { upstreamURL } : {}),
  };
}

/** Extra context for classifying BYOK/subscription HTTP errors. */
export interface ProviderErrorClassifyContext {
  grokSubscriptionAuth?: boolean;
  openAISubscriptionAuth?: boolean;
}

const GROK_SUBSCRIPTION_ERROR_KINDS = new Set<ProviderErrorKind>([
  'grokSubscriptionUnavailable',
  'grokSubscriptionIneligible',
  'grokSubscriptionExpired',
  'grokSubscriptionQuotaExhausted',
]);

export function isGrokSubscriptionErrorKind(kind: ProviderErrorKind): boolean {
  return GROK_SUBSCRIPTION_ERROR_KINDS.has(kind);
}

const OPENAI_SUBSCRIPTION_ERROR_KINDS = new Set<ProviderErrorKind>([
  'openAISubscriptionUnavailable',
  'openAISubscriptionIneligible',
  'openAISubscriptionExpired',
  'openAISubscriptionQuotaExhausted',
]);

export function isOpenAISubscriptionErrorKind(kind: ProviderErrorKind): boolean {
  return OPENAI_SUBSCRIPTION_ERROR_KINDS.has(kind);
}

/**
 * Status code triage for the Codex subscription path.
 *
 * Structurally the same as Grok, but with its own copy: 426 is the only early signal that OpenAI
 * raised its minimum client version, so it gets its own kind and forces one metadata refresh; 403
 * is a problem with the user's ChatGPT plan and must never be reported as a fault on our side;
 * 401 goes through automatic renewal and then re-login; 429 means the Codex quota for this period
 * is used up.
 */
export function openAISubscriptionProviderError(status: number, detail?: string): ProviderError | null {
  switch (status) {
    case 426:
      return {
        kind: 'openAISubscriptionUnavailable',
        title: 'ChatGPT Sign-in Unavailable',
        message: 'ChatGPT subscription sign-in is temporarily unavailable while we update it. You can connect with an API key instead.',
        detail,
      };
    case 403:
      return {
        kind: 'openAISubscriptionIneligible',
        title: 'Subscription Not Eligible',
        message: "Your ChatGPT account's current plan doesn't allow using Codex in third-party apps.",
        detail,
      };
    case 401:
      return {
        kind: 'openAISubscriptionExpired',
        title: 'ChatGPT Sign-in Expired',
        message: 'Your ChatGPT sign-in has expired. Please authorize again.',
        detail,
      };
    case 429:
      return {
        kind: 'openAISubscriptionQuotaExhausted',
        title: 'Codex Quota Used Up',
        message: "You've used up this period's Codex quota. It will resume after the next reset.",
        detail,
      };
    default:
      return null;
  }
}

/**
 * Status code triage for the subscription path.
 *
 * 426 is the only early signal that xAI raised its minimum client version, so it gets its own kind
 * and forces one metadata refresh; 403 is a problem with the user's xAI plan and must never be
 * reported as a fault on our side; 401 goes through automatic renewal and then re-login; 429 means
 * this week's usage pool is exhausted.
 */
export function grokSubscriptionProviderError(status: number, detail?: string): ProviderError | null {
  switch (status) {
    case 426:
      return {
        kind: 'grokSubscriptionUnavailable',
        title: 'Grok Subscription Unavailable',
        message: 'Grok subscription sign-in is temporarily unavailable while we update it. You can connect with an API key instead.',
        detail,
      };
    case 403:
      return {
        kind: 'grokSubscriptionIneligible',
        title: 'Subscription Not Eligible',
        message: "Your xAI account's current plan doesn't allow using the Grok subscription in third-party apps.",
        detail,
      };
    case 401:
      return {
        kind: 'grokSubscriptionExpired',
        title: 'Grok Sign-in Expired',
        message: 'Your Grok sign-in has expired. Please authorize again.',
        detail,
      };
    case 429:
      return {
        kind: 'grokSubscriptionQuotaExhausted',
        title: 'Grok Quota Used Up',
        message: "You've used up this period's Grok subscription quota. It will resume after the next reset.",
        detail,
      };
    default:
      return null;
  }
}

function classifyProviderError(
  status: number,
  body: string,
  upstreamURL?: string,
  relayErrorContext?: RelayErrorContext,
  classifyContext?: ProviderErrorClassifyContext,
): ProviderError {
  const trimmedBody = body.trim();
  // detail prefers error.{message,code,type}; other shapes are passed through redacted and length-capped.
  const detail = extractErrorSnippet(trimmedBody);
  // classifier uses trimmedBody for relay / subscription mapping  
  if (classifyContext?.grokSubscriptionAuth) {
    const subscriptionError = grokSubscriptionProviderError(status, detail);
    if (subscriptionError) return subscriptionError;
  }
  if (classifyContext?.openAISubscriptionAuth) {
    const subscriptionError = openAISubscriptionProviderError(status, detail);
    if (subscriptionError) return subscriptionError;
  }
  const relayError = classifyRelayHTTPError(status, trimmedBody, upstreamURL, relayErrorContext);
  if (relayError) return { ...relayError, detail };
  const normalizedBody = trimmedBody.toLowerCase();
  const isQuotaError = isQuotaExhaustion(normalizedBody);
  const isUnauthorizedError =
    /session|sign in|login|device token|device session|authentication|access expired|refresh your access|\u4f1a\u8bdd\u5df2\u8fc7\u671f|\u4f1a\u8bdd\u65e0\u6548|\u4f1a\u8bdd\u5931\u6548/.test(normalizedBody);
  const isUnavailableError = /temporarily unavailable|currently unavailable|unavailable|not available|disabled|offline|maintenance|\u6682\u4e0d\u53ef\u7528|\u4e0d\u53ef\u7528|\u5df2\u505c\u7528|\u7ef4\u62a4/.test(normalizedBody);

  if (status === 400) {
    return {
      kind: 'badRequest',
      title: 'Bad Request',
      message: 'The request was malformed. Please check your input and try again.',
      detail,
    };
  }
  if (status === 404 && isUnavailableError) {
    return {
      kind: 'unavailable',
      title: 'Temporarily Unavailable',
      message: 'This model is temporarily unavailable. Please try another model or come back later.',
      detail,
    };
  }
  if (status === 401 || status === 403) {
    // 403 + quota body maps to quotaExceeded for user-owned keys.
    if (isQuotaError) {
      return {
        kind: 'quotaExceeded',
        title: 'Provider Quota Reached',
        message: 'The provider reports that the quota or credit for this API key is used up. Check your billing with the provider, or switch models.',
        detail,
      };
    }
    if (isUnavailableError) {
      return {
        kind: 'unavailable',
        title: 'Temporarily Unavailable',
        message: 'This model is temporarily unavailable. Please try another model or come back later.',
        detail,
      };
    }
    if (isUnauthorizedError) {
      return {
        kind: 'unauthorized',
        title: 'Access Expired',
        message: 'Your access could not be verified. Please retry to refresh your session.',
        detail,
      };
    }
    return {
      kind: 'invalidKey',
      title: 'Invalid API Key',
      message: 'The API key you entered is invalid or has been revoked. Please check your key and try again.',
      detail,
    };
  }
  if (status === 429) {
    if (isQuotaError) {
      return {
        kind: 'quotaExceeded',
        title: 'Provider Quota Reached',
        message: 'The provider reports that the quota or credit for this API key is used up. Check your billing with the provider, or switch models.',
        detail,
      };
    }
    if (isUnavailableError) {
      return {
        kind: 'unavailable',
        title: 'Temporarily Unavailable',
        message: 'This model is temporarily unavailable. Please try another model or come back later.',
        detail,
      };
    }
    return {
      kind: 'rateLimited',
      title: 'Rate Limited',
      message: 'You have exceeded the rate limit. Please wait a moment and try again.',
      detail,
    };
  }
  if (status === 402) {
    // Payment Required: the user's own provider account is out of balance or credit (OpenRouter's
    // "Insufficient credits" and similar). That is an account condition rather than a transport
    // fault, so it maps to quotaExceeded, stays out of Sentry, and does not fall through to the
    // upstream default that would misleadingly suggest retrying.
    return {
      kind: 'quotaExceeded',
      title: 'Provider Quota Reached',
      message: 'The provider reports that the quota or credit for this API key is used up. Check your billing with the provider, or switch models.',
      detail,
    };
  }
  if (status >= 500) {
    if (isUnavailableError) {
      return {
        kind: 'unavailable',
        title: 'Temporarily Unavailable',
        message: 'This model is temporarily unavailable. Please try another model or come back later.',
        detail,
      };
    }
    return {
      kind: 'upstream',
      title: 'Provider Error',
      message: 'The AI provider is experiencing issues. Please try again later.',
      detail,
    };
  }
  return {
    kind: 'upstream',
    title: 'Request Failed',
    message: `Request failed with status ${status}. Please try again.`,
    detail,
  };
}

function freeBusinessCode(body: string): number | null {
  try {
    const parsed = JSON.parse(body) as { code?: unknown };
    return typeof parsed.code === 'number' ? parsed.code : null;
  } catch {
    return null;
  }
}

export function networkError(err: unknown): ProviderErrorObject {
  return new ProviderErrorObject({
    kind: 'network',
    title: 'Network Error',
    message: 'Unable to connect. Please check your internet connection and try again.',
    detail: err instanceof Error ? err.message : String(err),
    source: 'network',
  });
}
