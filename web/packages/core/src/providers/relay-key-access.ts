/**
 * Decides whether a relay key can use this model (fixture-backed contract).
 * Fixture source of truth: `shared/test-fixtures/relay/key-access.v1.json` (signals / classifyCases).
 *
 * Judged only for non-2xx before any output, ahead of the capability-rejection loop. The response body is matched by case-insensitive substring of the original text;
 * bare "model / group / not found" is not a signal (capability rejections and route 404s must land on none), and 5xx is always none.
 */

export type RelayKeyAccessOutcome = 'model_access_denied' | 'key_invalid' | 'key_limited' | 'none';

const MODEL_ACCESS_DENIED_STATUSES: ReadonlySet<number> = new Set([400, 403, 404]);
const MODEL_ACCESS_DENIED_SIGNALS = [
  'model_not_found',
  'key_model_access_denied',
  'team_model_access_denied',
  'user_model_access_denied',
  'token_model_forbidden',
  '无权访问模型',
  '无权使用模型',
  '无权使用分组',
  'is not available for this group',
  'is not supported for current token',
  'unknown provider for model',
  'do not have access to the model',
  'does not have access to model',
  'not allowed to access model',
  'not allowed to use model',
];
const KEY_INVALID_CODES_403 = ['api_key_expired', 'expired_key', 'token_expired'];
const KEY_LIMITED_CODES_403 = [
  'insufficient_user_quota',
  'insufficient_balance',
  'insufficient_quota',
  'budget_exceeded',
  'api_key_quota_exhausted',
  'usage_limit_exceeded',
];

function containsAny(body: string, needles: readonly string[]): boolean {
  return needles.some((needle) => body.includes(needle.toLowerCase()));
}

/** Look at 401 / 402 / 429 first; then a 403 carrying an invalid-key or quota code; then no-access (status listed and carries a code or phrase); everything else none. */
export function classifyRelayKeyAccess(status: number, body: string): RelayKeyAccessOutcome {
  if (status === 401) return 'key_invalid';
  if (status === 402 || status === 429) return 'key_limited';
  const lowered = body.toLowerCase();
  if (status === 403) {
    if (containsAny(lowered, KEY_INVALID_CODES_403)) return 'key_invalid';
    if (containsAny(lowered, KEY_LIMITED_CODES_403)) return 'key_limited';
  }
  if (MODEL_ACCESS_DENIED_STATUSES.has(status) && containsAny(lowered, MODEL_ACCESS_DENIED_SIGNALS)) {
    return 'model_access_denied';
  }
  return 'none';
}

export type RelayGenerationKeyStatus = 'ok' | 'invalid' | 'limited';

/**
 * Conclusion about key status from a generation request (send / 1-token re-verification / lazy verification / capability test), fixture generationCases.
 * 2xx -> ok; judged invalid key / quota -> invalid / limited; everything else (no access, route-level, gating, capability rejection, 5xx, network = null)
 * is always null and leaves the status unchanged: they say nothing about this key.
 */
export function relayGenerationKeyStatus(status: number | null, body: string): RelayGenerationKeyStatus | null {
  if (status === null) return null;
  if (status >= 200 && status < 300) return 'ok';
  const outcome = classifyRelayKeyAccess(status, body);
  if (outcome === 'key_invalid') return 'invalid';
  if (outcome === 'key_limited') return 'limited';
  return null;
}
