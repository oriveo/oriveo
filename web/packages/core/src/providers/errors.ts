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

/**
 * Finer reason for a transport-level failure (the `network_detail` of chat failure telemetry; a closed set shared across platforms).
 * It travels only on the normalized error object and never feeds UI copy decisions.
 */
export type ChatNetworkDetail =
  | 'dns' | 'connect' | 'tls' | 'timeout' | 'reset' | 'offline' | 'proxy' | 'fetch_failed' | 'other';

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
  /** The relay replied 2xx but the content is a web page: per-model probing treats it as a route-level rejection. */
  relayHTMLPage?: true;
  /** message is the relay guidance sentence produced by classifyRelayHTTPError: the body keeps the guidance, and the upstream original goes only into detail. */
  relayGuidance?: true;
  quotaSource?: ProviderQuotaSource;
  traceId?: string;
  /** Comes from an upstream in-stream error frame (see StreamEvent.streamErrorFrame). */
  streamErrorFrame?: boolean;
  /**
   * Raw `error.type` / `error.code` / `error.status` (lowercase) from the upstream error body or error-frame JSON.
   * Taken from JSON fields only, never scanned out of body text; it still goes through the telemetry allowlist before reporting.
   */
  upstreamErrorType?: string;
  /** Finer reason when kind is network (telemetry `network_detail`). */
  networkDetail?: ChatNetworkDetail;
  /** Stable guidance key when relayGuidance matched (one table shared across platforms, keyed by RelayGuidanceCode.stableKey). */
  relayGuidanceKey?: string;
  /** HTTP status of the error; kept even after mapping to a dedicated 401/429 error (used by overflow detection). */
  httpStatus?: number;
  /**
   * Raw HTTP error body (first 32 KB of UTF-8), used only for local overflow detection: never shown,
   * logged or persisted. Non-enumerable (see withProviderErrorRawBody): spreading and serialization drop it.
   */
  rawBody?: string;
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
  readonly upstreamErrorType?: string;
  readonly networkDetail?: ChatNetworkDetail;
  readonly httpStatus?: number;
  declare readonly rawBody?: string;

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
    if (error.upstreamErrorType) this.upstreamErrorType = error.upstreamErrorType;
    if (error.networkDetail) this.networkDetail = error.networkDetail;
    if (error.httpStatus !== undefined) this.httpStatus = error.httpStatus;
    withProviderErrorRawBody(this, providerErrorRawBodyOf(error));
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
  const classified = {
    ...withUpstreamErrorType(
      classifyProviderError(status, body, upstreamURL, relayErrorContext, classifyContext),
      body,
    ),
    httpStatus: status,
  };
  return withProviderErrorRawBody(
    toProviderErrorPublic(status, body, classified, upstreamURL, sensitiveCredentialValues, classifyContext),
    providerErrorRawBody(body),
  );
}

function toProviderErrorPublic(
  status: number,
  body: string,
  classified: ProviderError,
  upstreamURL: string | undefined,
  sensitiveCredentialValues: readonly string[],
  classifyContext: ProviderErrorClassifyContext | undefined,
): ProviderError {
  // The four subscription failure kinds are explained here, because the upstream only replies
  // "Unauthorized" or "Forbidden"; using that as the body would turn "your plan does not support
  // this" into a line of English the user cannot act on.
  if (
    (classifyContext?.grokSubscriptionAuth && isGrokSubscriptionErrorKind(classified.kind)) ||
    (classifyContext?.openAISubscriptionAuth && isOpenAISubscriptionErrorKind(classified.kind))
  ) {
    // The source is `oriveo`, not `provider`: on the subscription path the version headers,
    // endpoints and credential exchange are all supplied and carried out by the app, while the
    // upstream text is written for the vendor's own CLI users (xAI's 426 reads "Your Grok CLI
    // version (1.0.4) is outdated… via `grok update`"), which an app user cannot act on. Marking
    // it `provider` has two consequences: the failure card shows that text as its body and the
    // localized subscription copy is never rendered, and the 426 signal that the published
    // configuration needs updating is dropped by the rule that errors returned by a provider are
    // not reported. The upstream text still travels in `detail`.
    return {
      ...classified,
      source: 'oriveo',
      status,
      ...(upstreamURL ? { upstreamURL } : {}),
    };
  }
  // When the upstream already gave a readable reason, that text (only redacted and length-capped)
  // is the single source of truth for the user-facing body. kind and title only carry structured
  // recovery semantics and must not overwrite the upstream text with a message of our own.
  const upstreamMessage = extractErrorSnippet(body.trim(), 500, sensitiveCredentialValues);
  // A relay guidance hit: the body is a guidance sentence telling the user where to change things, and the upstream original is demoted to detail.
  if (classified.relayGuidance) {
    return {
      ...classified,
      message: redactRelayCredentials(classified.message, sensitiveCredentialValues),
      detail: upstreamMessage
        ?? (classified.detail ? redactRelayCredentials(classified.detail, sensitiveCredentialValues) : undefined),
      source: 'provider',
      status,
      ...(upstreamURL ? { upstreamURL } : {}),
    };
  }
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

/**
 * Attach the raw error body as a non-enumerable field: only overflow detection reads it by name;
 * spreading, JSON serialization and failure-card details never see it (rawBody must not leak).
 */
export function withProviderErrorRawBody<T extends object>(target: T, rawBody: string | undefined): T {
  if (rawBody === undefined) return target;
  Object.defineProperty(target, 'rawBody', {
    value: rawBody,
    enumerable: false,
    writable: false,
    configurable: true,
  });
  return target;
}

/** Read the non-enumerable raw error body (for overflow detection only). */
export function providerErrorRawBodyOf(value: unknown): string | undefined {
  if (value == null || typeof value !== 'object') return undefined;
  const raw = (value as { rawBody?: unknown }).rawBody;
  return typeof raw === 'string' ? raw : undefined;
}

/** Upper bound on the retained raw HTTP error body (UTF-8 bytes). */
export const PROVIDER_ERROR_RAW_BODY_LIMIT = 32 * 1024;

const rawBodyEncoder = new TextEncoder();
const rawBodyDecoder = new TextDecoder();

/** First 32 KB of the raw error body as UTF-8; the cut point backs up to a whole character boundary. */
export function providerErrorRawBody(body: string): string {
  const bytes = rawBodyEncoder.encode(body);
  if (bytes.length <= PROVIDER_ERROR_RAW_BODY_LIMIT) return body;
  let end = PROVIDER_ERROR_RAW_BODY_LIMIT;
  // 0b10xxxxxx is a continuation byte of a multi-byte character: step back to the character start.
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return rawBodyDecoder.decode(bytes.subarray(0, end));
}

/** Classification context: the same status code means something different on the subscription path than in BYOK key mode. */
export interface ProviderErrorClassifyContext {
  grokSubscriptionAuth?: boolean;
  openAISubscriptionAuth?: boolean;
}

/**
 * Upstream temporary overload / shared pool at capacity. The user action is wait, switch
 * model, or retry, so this maps to `rateLimited`.
 *
 * Deliberately omitted:
 * - `internal server error`: a real 5xx, still reported
 * - bare `unavailable`: `unavailable for free` is a permanent signal; `temporarily unavailable`
 *   already has its own branch
 * - bare substring `overloaded` / `rate limit`: would false-positive on account copy such as
 *   "account overloaded with extra seats"
 */
const TRANSIENT_OVERLOAD_NEEDLES = [
  'temporarily rate-limited',
  'rate-limited upstream',
  'temporarily overloaded',
  'currently overloaded',
  'overloaded_error',
  'resourceexhausted',
  'at capacity',
  'queue timeout',
  'rate_limit',
  'rate limit reached',
  'rate limit exceeded',
] as const;

export function isTransientOverloadError(text: string): boolean {
  const lower = text.toLowerCase();
  if (TRANSIENT_OVERLOAD_NEEDLES.some((needle) => lower.includes(needle))) return true;
  // Anthropic's production text is the whole sentence "Overloaded"; a substring match would
  // false-positive on account copy.
  return lower.trim() === 'overloaded';
}

/**
 * In-stream errors (HTTP 200 SSE) have no usable status code, so triage by type/message.
 * Quota exhaustion beats overload: Gemini `Resource has been exhausted (e.g. check quota)`
 * contains quota.
 */
export function classifyInStreamProviderErrorKind(
  message: string,
  typeOrCode?: string,
): ProviderErrorKind {
  const text = `${typeOrCode ?? ''} ${message}`;
  if (isQuotaExhaustion(text)) return 'quotaExceeded';
  if (isTransientOverloadError(text)) return 'rateLimited';
  return 'upstream';
}

const GROK_SUBSCRIPTION_ERROR_KINDS = new Set<ProviderErrorKind>([
  'grokSubscriptionUnavailable',
  'grokSubscriptionIneligible',
  'grokSubscriptionExpired',
  'grokSubscriptionQuotaExhausted',
]);

/**
 * Failure kinds of the two subscription paths (Grok and ChatGPT). Their copy, source and recovery
 * actions are decided by the app rather than passed through from upstream.
 */
export function isSubscriptionErrorKind(kind: string | undefined): boolean {
  return typeof kind === 'string'
    && (kind.startsWith('grokSubscription') || kind.startsWith('openAISubscription'));
}

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

  // Capacity / overload is independent of HTTP status: a 200 SSE and a 5xx can both carry
  // "Service temporarily overloaded". 401/403 stay auth; quota exhaustion beats overload.
  if (
    status !== 401
    && status !== 403
    && !isQuotaError
    && isTransientOverloadError(normalizedBody)
  ) {
    return {
      kind: 'rateLimited',
      title: 'Rate Limited',
      message: 'You have exceeded the rate limit. Please wait a moment and try again.',
      detail,
    };
  }

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

export function networkError(err: unknown, networkDetail?: ChatNetworkDetail): ProviderErrorObject {
  return new ProviderErrorObject({
    kind: 'network',
    title: 'Network Error',
    message: 'Unable to connect. Please check your internet connection and try again.',
    detail: err instanceof Error ? err.message : String(err),
    source: 'network',
    networkDetail: networkDetail ?? transportNetworkDetail(err, 'connect'),
  });
}

/**
 * Transport exception -> network_detail. Looks only at the exception `name` (stable across engines), never at the message text:
 * TimeoutError -> timeout; a disconnect after the stream started -> reset; a fetch TypeError while sending the request -> fetch_failed; anything else -> other.
 * Device offline (navigator.onLine) is layered on by the emitter; this function does not read globals.
 */
export function transportNetworkDetail(err: unknown, phase: 'connect' | 'read'): ChatNetworkDetail {
  const name = err && typeof err === 'object' ? (err as { name?: unknown }).name : undefined;
  if (name === 'TimeoutError') return 'timeout';
  if (phase === 'read') return 'reset';
  if (name === 'TypeError') return 'fetch_failed';
  return 'other';
}

/**
 * `error.type` / `error.code` / `error.status` of the upstream error body JSON (first string value, lowercase).
 * A Gemini error body may be a one-element array. Non-JSON or none of these fields -> undefined.
 */
export function upstreamErrorTypeFromBody(body: string): string | undefined {
  let parsed: unknown;
  try { parsed = JSON.parse(body.trim()); } catch { return undefined; }
  if (Array.isArray(parsed)) parsed = parsed[0];
  const error = parsed && typeof parsed === 'object' ? (parsed as { error?: unknown }).error : undefined;
  if (!error || typeof error !== 'object' || Array.isArray(error)) return undefined;
  return upstreamErrorTypeValue(error as Record<string, unknown>);
}

/** Raw type/code/status on an error object (the `error` of an in-stream frame or an HTTP error body). */
export function upstreamErrorTypeValue(error: Record<string, unknown>): string | undefined {
  for (const key of ['type', 'code', 'status'] as const) {
    const value = error[key];
    if (typeof value === 'string' && value.trim()) return normalizeUpstreamErrorType(value);
  }
  return undefined;
}

export function normalizeUpstreamErrorType(value: unknown): string | undefined {
  if (typeof value !== 'string' || !value.trim()) return undefined;
  return value.trim().toLowerCase().slice(0, 64);
}

function withUpstreamErrorType(error: ProviderError, body: string): ProviderError {
  const upstreamErrorType = upstreamErrorTypeFromBody(body);
  return upstreamErrorType ? { ...error, upstreamErrorType } : error;
}
