/**
 * Chat failure attribution for `chat_message_failed`. Every emitter of the failed event goes through
 * {@link chatFailureTelemetry}; it only ever outputs fixed short slugs, never error text.
 */
import type { ChatNetworkDetail, ProviderError } from '@oriveo/core/providers/errors';
import {
  RELAY_GUIDANCE_WEB_PAGE_RETURNED_KEY,
  relayGuidanceStableKey,
} from '@oriveo/core/providers/relay-error-classifier';
import { RELAY_HTML_PAGE_ERROR } from '@oriveo/core/providers/relay-stream';
import { RELAY_IMAGE_CHAT_MODEL_REQUIRED_KIND, RELAY_IMAGE_TRANSPORT_UNSUPPORTED_KIND } from '../providers/relay-image-route-error';

/** Which user action started the request attempt (sent / completed / failed / stopped all carry it). */
export type ChatAttemptKind = 'send' | 'edit' | 'retry' | 'regenerate' | 'continue' | 'recovery';

export type ChatFailurePhase = 'before_output' | 'after_output';

export type ChatSendBlockedReason =
  | 'no_model'
  | 'provider_missing'
  | 'conversation_not_ready'
  | 'library_unavailable'
  | 'research_unavailable'
  | 'other';

export interface ChatFailureTelemetryInput {
  /** The normalized failure (normalizeChatFailure output or a thrown stream error object). */
  error: unknown;
  /** Whether any text / reasoning delta of this attempt arrived before the failure. */
  outputStarted: boolean;
  /** Milliseconds from request start to the failure. */
  latencyMs: number;
  /** `navigator.onLine` at failure time; `false` turns any network failure into `network_offline`. */
  deviceOnline?: boolean;
}

export interface ChatFailureTelemetry {
  error_code: string;
  failure_phase: ChatFailurePhase;
  latency_ms: number;
  http_status?: number;
  network_detail?: ChatNetworkDetail;
  upstream_error_type?: string;
  relay_guidance?: string;
  error_class?: string;
}

export const UPSTREAM_ERROR_TYPE_ALLOWLIST: ReadonlySet<string> = new Set([
  'overloaded_error', 'rate_limit_error', 'api_error', 'invalid_request_error', 'authentication_error',
  'permission_error', 'not_found_error', 'request_too_large', 'billing_error', 'insufficient_quota',
  'rate_limit_exceeded', 'context_length_exceeded', 'model_not_found', 'invalid_api_key', 'server_error',
  'server_overloaded', 'resource_exhausted', 'unavailable', 'internal', 'invalid_argument',
  'permission_denied', 'unauthenticated', 'deadline_exceeded', 'failed_precondition', 'not_found',
  'content_filter', 'content_policy_violation',
]);

const ERROR_CLASS_PATTERN = /^[A-Za-z0-9_.$]{1,64}$/;
const NETWORK_DETAILS: ReadonlySet<string> = new Set([
  'dns', 'connect', 'tls', 'timeout', 'reset', 'offline', 'proxy', 'fetch_failed', 'other',
]);

/**
 * ProviderErrorKind (and the other kinds that reach the chat catch blocks) → error_code.
 * `badRequest` / `upstream` / `network` are resolved separately because they depend on
 * status / frame / transport facts. Every ProviderErrorKind has an entry or a branch below.
 */
export const KIND_ERROR_CODES: Readonly<Record<string, string>> = {
  // Tier 2: local / configuration
  invalidKey: 'invalid_key',
  unauthorized: 'sign_in_required',
  customRequestFieldsRejected: 'local_request_rejected',
  additionalBodyRejected: 'local_request_rejected',
  // Relay image generation blocked locally before sending: the Web enum has no invalid_configuration like Android, so it maps to local rejection.
  [RELAY_IMAGE_TRANSPORT_UNSUPPORTED_KIND]: 'local_request_rejected',
  [RELAY_IMAGE_CHAT_MODEL_REQUIRED_KIND]: 'local_request_rejected',
  attachment_text_over_limit: 'attachment_text_over_limit',
  attachment_count_over_limit: 'attachment_count_over_limit',
  grokSubscriptionUnavailable: 'subscription_grok_unavailable',
  grokSubscriptionIneligible: 'subscription_grok_ineligible',
  grokSubscriptionExpired: 'subscription_grok_expired',
  grokSubscriptionQuotaExhausted: 'subscription_grok_quota_exhausted',
  openAISubscriptionUnavailable: 'subscription_openai_unavailable',
  openAISubscriptionIneligible: 'subscription_openai_ineligible',
  openAISubscriptionExpired: 'subscription_openai_expired',
  openAISubscriptionQuotaExhausted: 'subscription_openai_quota_exhausted',
  // Tier 3: existing semantic classifications
  quotaExceeded: 'quota_exceeded',
  rateLimited: 'rate_limited',
  unavailable: 'model_unavailable',
  emptyModelCatalog: 'empty_catalog',
  // Tier 7
  emptyResponse: 'empty_response',
};

/** Already-normalized snake values some layers throw directly (proxy layer, library agent). */
const PASSTHROUGH_CODES: ReadonlySet<string> = new Set([
  ...Object.values(KIND_ERROR_CODES),
  'content_filtered', 'upstream_stream_error', 'network_offline', 'network_timeout', 'network_error', 'unknown',
]);

type FailureFields = Partial<ProviderError> & {
  name?: unknown;
  relayHTMLPage?: unknown;
  outputStarted?: unknown;
};

function fieldsOf(error: unknown): FailureFields {
  return error && typeof error === 'object' ? (error as FailureFields) : {};
}

function isHttpFailureStatus(status: unknown): status is number {
  return typeof status === 'number' && Number.isInteger(status) && status >= 300 && status <= 599;
}

function networkDetailOf(fields: FailureFields, deviceOnline: boolean | undefined): ChatNetworkDetail {
  if (deviceOnline === false) return 'offline';
  const detail = fields.networkDetail;
  if (typeof detail === 'string' && NETWORK_DETAILS.has(detail)) return detail;
  if (fields.name === 'TimeoutError') return 'timeout';
  return 'other';
}

function networkCode(detail: ChatNetworkDetail): string {
  if (detail === 'offline') return 'network_offline';
  if (detail === 'timeout') return 'network_timeout';
  return 'network_error';
}

function relayGuidanceOf(fields: FailureFields): string | undefined {
  // Prefer the explicit key the classifier attached; fall back to the source sentence for
  // objects that only carry `relayGuidance: true` (e.g. failures restored from storage).
  if (typeof fields.relayGuidanceKey === 'string' && /^[a-z][a-z0-9_]{0,63}$/.test(fields.relayGuidanceKey)) {
    return fields.relayGuidanceKey;
  }
  if (fields.relayHTMLPage === true) return RELAY_GUIDANCE_WEB_PAGE_RETURNED_KEY;
  if (fields.relayGuidance !== true || typeof fields.message !== 'string') return undefined;
  if (fields.message === RELAY_HTML_PAGE_ERROR) return RELAY_GUIDANCE_WEB_PAGE_RETURNED_KEY;
  return relayGuidanceStableKey(fields.message);
}

function errorCodeOf(fields: FailureFields, deviceOnline: boolean | undefined): string {
  const kind: string | undefined = typeof fields.kind === 'string' ? fields.kind : undefined;
  if (kind === 'network' || (kind === undefined && deviceOnline === false)) {
    return networkCode(networkDetailOf(fields, deviceOnline));
  }
  if (kind && /^library_[a-z0-9_]{1,60}$/.test(kind)) return kind;
  // Tier 6 is checked before the generic stream-frame tier: a safety block is the more specific fact.
  if (kind === 'moderation' || fields.i18nKey === 'moderation') return 'content_filtered';
  const status = fields.status;
  // Tier 3 covers HTTP non-2xx *and* in-stream error frames that already carry a semantic class
  // (rateLimited / quotaExceeded / unavailable / invalidKey); only unclassified frames fall to tier 5.
  if (kind && KIND_ERROR_CODES[kind]) return KIND_ERROR_CODES[kind]!;
  if (kind && PASSTHROUGH_CODES.has(kind)) return kind;
  if (fields.streamErrorFrame === true) return 'upstream_stream_error';
  if (kind === 'badRequest') return `upstream_${isHttpFailureStatus(status) ? status : 400}`;
  if (kind === 'upstream') {
    if (isHttpFailureStatus(status)) return `upstream_${status}`;
    // Relay guidance without a usable status (e.g. a 2xx web page): same rule as a stream error.
    if (fields.relayGuidance === true) return 'upstream_stream_error';
  }
  return 'unknown';
}

/**
 * Pure mapping from a normalized chat failure to the `chat_message_failed` drill-down fields.
 * Keys without a value are omitted (never empty strings).
 */
export function chatFailureTelemetry(input: ChatFailureTelemetryInput): ChatFailureTelemetry {
  const fields = fieldsOf(input.error);
  const errorCode = errorCodeOf(fields, input.deviceOnline);
  const out: ChatFailureTelemetry = {
    error_code: errorCode,
    failure_phase: input.outputStarted ? 'after_output' : 'before_output',
    latency_ms: Math.max(0, Math.round(input.latencyMs)),
  };
  if (isHttpFailureStatus(fields.status)) out.http_status = fields.status;
  if (errorCode.startsWith('network_')) out.network_detail = networkDetailOf(fields, input.deviceOnline);
  if (typeof fields.upstreamErrorType === 'string' && fields.upstreamErrorType) {
    const normalized = fields.upstreamErrorType.toLowerCase();
    out.upstream_error_type = UPSTREAM_ERROR_TYPE_ALLOWLIST.has(normalized) ? normalized : 'other';
  }
  const guidance = relayGuidanceOf(fields);
  if (guidance) out.relay_guidance = guidance;
  if (errorCode === 'unknown' && typeof fields.name === 'string' && ERROR_CLASS_PATTERN.test(fields.name)) {
    out.error_class = fields.name;
  }
  return out;
}

/** Shared helper: was output already flowing when this error was thrown (set by stream-runner)? */
export function failureOutputStarted(error: unknown): boolean {
  return fieldsOf(error).outputStarted === true;
}
