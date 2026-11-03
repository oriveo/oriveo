/**
 * Image error normalization: map an HTTP status, parsed body, and requested count
 * onto one closed error kind with its handling policy.
 * Fixture: image_error_samples.v1.
 */
import { parseImageResponse, type ImageFetchFailure } from './image-response';

export type ImageErrorKind =
  | 'refused'
  | 'auth'
  | 'insufficient_balance'
  | 'rate_limited'
  | 'invalid_param'
  | 'model_unavailable'
  | 'upstream_error'
  | 'timeout'
  | 'network'
  | 'partial'
  | 'decode_failed'
  | 'storage_full';

// Compile-time mapping: every U5a fetch failure is an error kind of the same name.
const _failureIsKind = (f: ImageFetchFailure): ImageErrorKind => f;
void _failureIsKind;

export interface ImageErrorPolicy {
  consumesFreeQuota: 'none' | 'by_delivered_count' | 'already_settled';
  autoRetry: 'none' | 'once_before_body_sent';
  ui: string;
  report: boolean;
}

function policy(
  ui: string,
  overrides: Partial<Omit<ImageErrorPolicy, 'ui'>> = {},
): ImageErrorPolicy {
  return { consumesFreeQuota: 'none', autoRetry: 'none', ui, report: false, ...overrides };
}

export const IMAGE_ERROR_POLICIES: Readonly<Record<ImageErrorKind, ImageErrorPolicy>> = {
  refused: policy('rewrite_prompt_or_switch_model'),
  auth: policy('check_key'),
  insufficient_balance: policy('top_up_or_switch_model'),
  rate_limited: policy('retry_later'),
  invalid_param: policy('show_raw_and_switch_model', { report: true }),
  model_unavailable: policy('switch_model'),
  upstream_error: policy('retry'),
  timeout: policy('retry'),
  network: policy('retry', { autoRetry: 'once_before_body_sent' }),
  partial: policy('fill_missing', { consumesFreeQuota: 'by_delivered_count' }),
  decode_failed: policy('retry', { report: true }),
  storage_full: policy('free_space_then_retry_save', { consumesFreeQuota: 'already_settled' }),
};

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

// Matches string values only, recursing into objects and arrays; keys are never tested.
const BALANCE_TEXT = /insufficient[_ ](?:quota|balance)|\u4f59\u989d\u4e0d\u8db3|\u989d\u5ea6\u4e0d\u8db3/i;

function hasBalanceText(value: unknown): boolean {
  if (typeof value === 'string') return BALANCE_TEXT.test(value);
  if (Array.isArray(value)) return value.some(hasBalanceText);
  if (isObject(value)) return Object.values(value).some(hasBalanceText);
  return false;
}

const REFUSED_CODES = new Set(['moderation_blocked', 'content_policy_violation']);
const MODEL_GONE_CODES = new Set(['model_not_found', 'model_not_available']);
const BLOCK_FINISH_REASONS = new Set([
  'IMAGE_SAFETY',
  'PROHIBITED_CONTENT',
  'SAFETY',
  'IMAGE_PROHIBITED_CONTENT',
]);

function classifyClientError(body: unknown): ImageErrorKind {
  const error = isObject(body) ? body.error : undefined;
  const code = isObject(error) && typeof error.code === 'string' ? error.code : null;
  if (code !== null && REFUSED_CODES.has(code)) return 'refused';
  if (code !== null && MODEL_GONE_CODES.has(code)) return 'model_unavailable';
  return hasBalanceText(body) ? 'insufficient_balance' : 'invalid_param';
}

function miniMaxStatusKind(code: number): ImageErrorKind {
  switch (code) {
    case 1002:
      return 'rate_limited';
    case 1004:
      return 'auth';
    case 1008:
      return 'insufficient_balance';
    case 1026:
    case 1027:
      return 'refused';
    default:
      return 'invalid_param';
  }
}

function failedCount(body: JsonObject): number {
  const metadata = body.metadata;
  if (!isObject(metadata)) return 0;
  const raw = metadata.failed_count;
  if (typeof raw === 'number' && Number.isFinite(raw)) return raw;
  if (typeof raw === 'string' && /^\d+$/.test(raw)) return Number(raw);
  return 0;
}

function isBlockedWithoutImages(body: unknown): boolean {
  if (!isObject(body)) return false;
  const candidates = body.candidates;
  if (Array.isArray(candidates) && isObject(candidates[0])) {
    const reason = candidates[0].finishReason;
    if (typeof reason === 'string' && BLOCK_FINISH_REASONS.has(reason)) return true;
  }
  return failedCount(body) > 0;
}

function classifySuccess(body: unknown, nRequested: number): ImageErrorKind | 'ok' {
  if (isObject(body)) {
    const baseResp = body.base_resp;
    if (isObject(baseResp) && typeof baseResp.status_code === 'number' && baseResp.status_code !== 0) {
      return miniMaxStatusKind(baseResp.status_code);
    }
    const feedback = body.promptFeedback;
    if (isObject(feedback) && typeof feedback.blockReason === 'string' && feedback.blockReason !== '') {
      return 'refused';
    }
  }
  const delivered = parseImageResponse(body).images.length;
  if (delivered === 0) return isBlockedWithoutImages(body) ? 'refused' : 'decode_failed';
  return delivered < nRequested ? 'partial' : 'ok';
}

/**
 * body: the parsed JSON value; the raw text for a non-JSON reply; null when there is no body.
 * Returns 'ok' when the call delivered at least nRequested images.
 */
export function classifyImageResult(input: {
  http: number;
  body: unknown;
  nRequested: number;
}): ImageErrorKind | 'ok' {
  const { http, body, nRequested } = input;
  if (http === 401 || http === 403) return 'auth';
  if (http === 402) return 'insufficient_balance';
  if (http === 404) return 'model_unavailable';
  if (http === 429) return hasBalanceText(body) ? 'insufficient_balance' : 'rate_limited';
  if (http >= 500 || http < 200 || (http >= 300 && http < 400)) return 'upstream_error';
  if (http >= 400) return classifyClientError(body);
  return classifySuccess(body, nRequested);
}
