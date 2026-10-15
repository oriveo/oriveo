// Web mapping of chat failure attribution: the nine error_code tiers, the drill-down fields, and "no value, no key".
import { describe, expect, it } from 'vitest';
import type { ProviderErrorKind } from '@oriveo/core/providers/errors';
import { networkError, toProviderError, transportNetworkDetail } from '@oriveo/core/providers/errors';
import { RELAY_GUIDANCE, relayGuidanceStableKey } from '@oriveo/core/providers/relay-error-classifier';
import { RELAY_HTML_PAGE_ERROR } from '@oriveo/core/providers/relay-stream';
import { createProxyChunkParser } from '@oriveo/core/providers/proxy-chunk-parser';
import { chatFailureTelemetry, KIND_ERROR_CODES } from './chat-failure';

function codeOf(error: unknown, extra: { outputStarted?: boolean; deviceOnline?: boolean } = {}) {
  return chatFailureTelemetry({ error, outputStarted: extra.outputStarted ?? false, latencyMs: 1234, ...extra });
}

describe('chatFailureTelemetry error_code mapping', () => {
  it.each([
    // Tier 2: Local / configuration
    ['invalid key', { kind: 'invalidKey', status: 401 }, 'invalid_key'],
    ['session expired', { kind: 'unauthorized', status: 401 }, 'sign_in_required'],
    ['attachment over limit', { kind: 'attachment_text_over_limit' }, 'attachment_text_over_limit'],
    ['custom fields rejected locally', { kind: 'customRequestFieldsRejected' }, 'local_request_rejected'],
    ['subscription lane', { kind: 'openAISubscriptionExpired', status: 401 }, 'subscription_openai_expired'],
    ['library', { kind: 'library_reauth_required' }, 'library_reauth_required'],
    // Tier 3: HTTP non-2xx with an existing semantic class
    ['429 rate limit', { kind: 'rateLimited', status: 429 }, 'rate_limited'],
    ['402 quota', { kind: 'quotaExceeded', status: 402 }, 'quota_exceeded'],
    ['model unavailable', { kind: 'unavailable', status: 503 }, 'model_unavailable'],
    // Tier 4: Remaining HTTP non-2xx
    ['500 fallback', { kind: 'upstream', status: 500 }, 'upstream_500'],
    ['badRequest', { kind: 'badRequest', status: 413 }, 'upstream_413'],
    ['relay guidance without a status code', { kind: 'upstream', relayGuidance: true, message: RELAY_GUIDANCE.upstreamUnavailable }, 'upstream_stream_error'],
    // Tier 5: 2xx in-stream error frame: no longer upstream_200, and an in-stream inferred rate limit does not pose as an HTTP class
    ['in-stream error frame', { kind: 'upstream', streamErrorFrame: true }, 'upstream_stream_error'],
    ['in-stream frame with a semantic class: rate limit', { kind: 'rateLimited', streamErrorFrame: true }, 'rate_limited'],
    ['in-stream frame with a semantic class: quota', { kind: 'quotaExceeded', streamErrorFrame: true }, 'quota_exceeded'],
    ['in-stream frame with a semantic class: unavailable', { kind: 'unavailable', streamErrorFrame: true }, 'model_unavailable'],
    ['in-stream frame with a semantic class: key', { kind: 'invalidKey', streamErrorFrame: true }, 'invalid_key'],
    ['empty model catalog', { kind: 'emptyModelCatalog' }, 'empty_catalog'],
    // Tier 6: Safety block
    ['safety block', { kind: 'moderation', i18nKey: 'moderation' }, 'content_filtered'],
    // Tier 7: 2xx without content
    ['empty response', { kind: 'emptyResponse', status: 200 }, 'empty_response'],
    // Tier 8: Transport layer
    ['timeout', { kind: 'network', networkDetail: 'timeout' }, 'network_timeout'],
    ['other network failure', { kind: 'network', networkDetail: 'fetch_failed' }, 'network_error'],
    // Tier 9: Fallback
    ['unknown exception', new RangeError('boom'), 'unknown'],
  ])('%s', (_label, error, expected) => {
    expect(codeOf(error).error_code).toBe(expected);
  });

  it('any network failure while the device is offline is recorded as network_offline + offline', () => {
    const out = codeOf(networkError(new TypeError('Failed to fetch')), { deviceOnline: false });
    expect(out).toMatchObject({ error_code: 'network_offline', network_detail: 'offline' });
  });

  it('all values are snake_case (camelCase is retired)', () => {
    for (const code of Object.values(KIND_ERROR_CODES)) expect(code).toMatch(/^[a-z][a-z0-9_]*$/);
  });

  it('covers every ProviderErrorKind: each kind maps to a non-unknown snake value', () => {
    const kinds: Record<ProviderErrorKind, true> = {
      invalidKey: true, unauthorized: true, badRequest: true, quotaExceeded: true, rateLimited: true,
      unavailable: true, network: true, emptyResponse: true, upstream: true, emptyModelCatalog: true,
      grokSubscriptionUnavailable: true, grokSubscriptionIneligible: true, grokSubscriptionExpired: true,
      grokSubscriptionQuotaExhausted: true, openAISubscriptionUnavailable: true, openAISubscriptionIneligible: true,
      openAISubscriptionExpired: true, openAISubscriptionQuotaExhausted: true,
    };
    for (const kind of Object.keys(kinds)) {
      const code = codeOf({ kind, status: 500 }).error_code;
      expect(code, kind).not.toBe('unknown');
      expect(code, kind).toMatch(/^[a-z][a-z0-9_]*$/);
    }
  });
});

describe('chatFailureTelemetry drill-down fields', () => {
  it('failure_phase: before_output before the first byte, after_output once output exists', () => {
    expect(codeOf({ kind: 'upstream', status: 500 }).failure_phase).toBe('before_output');
    expect(codeOf({ kind: 'upstream', status: 500 }, { outputStarted: true }).failure_phase).toBe('after_output');
  });

  it('http_status is present only for non-2xx (429 included), and absent keys stay absent', () => {
    expect(codeOf({ kind: 'rateLimited', status: 429 }).http_status).toBe(429);
    const frame = codeOf({ kind: 'upstream', streamErrorFrame: true, status: 200 });
    expect('http_status' in frame).toBe(false);
    expect('network_detail' in frame).toBe(false);
    expect('upstream_error_type' in frame).toBe(false);
    expect('relay_guidance' in frame).toBe(false);
    expect('error_class' in frame).toBe(false);
  });

  it.each([
    ['offline', networkError(new Error('navigator.onLine === false'), 'offline'), 'network_offline'],
    ['timeout', networkError(Object.assign(new Error('t'), { name: 'TimeoutError' })), 'network_timeout'],
    ['proxy', networkError('Failed to connect to provider', 'proxy'), 'network_error'],
    ['fetch_failed', networkError(new TypeError('Failed to fetch')), 'network_error'],
    ['reset', { kind: 'network', networkDetail: transportNetworkDetail(new Error('socket closed'), 'read') }, 'network_error'],
    ['connect', toProviderError(502, '{"code":"relay_upstream_connection_failed"}', undefined, { isRelay: true }), 'network_error'],
    ['other', networkError(Object.assign(new Error('aborted'), { name: 'AbortError' })), 'network_error'],
  ])('network_detail=%s', (detail, error, code) => {
    expect(codeOf(error)).toMatchObject({ error_code: code, network_detail: detail });
  });

  it('upstream_error_type: allowlisted values from the HTTP error body JSON pass through, others become other, non-JSON is omitted', () => {
    const inList = toProviderError(429, '{"error":{"code":429,"message":"x","status":"RESOURCE_EXHAUSTED"}}');
    expect(codeOf(inList).upstream_error_type).toBe('resource_exhausted');
    const outOfList = toProviderError(500, '{"error":{"type":"weird_vendor_thing","message":"x"}}');
    expect(codeOf(outOfList).upstream_error_type).toBe('other');
    const plain = toProviderError(500, 'upstream overloaded_error happened');
    expect('upstream_error_type' in codeOf(plain)).toBe(false);
  });

  it('upstream_error_type: in-stream error frame (output of the production parser)', () => {
    const events = createProxyChunkParser('openAI')(null, '{"error":{"type":"overloaded_error","message":"Overloaded"}}');
    const frame = (Array.isArray(events) ? events : [events]).find((event) => event?.type === 'error');
    expect(frame).toMatchObject({ streamErrorFrame: true, upstreamErrorType: 'overloaded_error' });
    expect(codeOf({ kind: frame?.type === 'error' ? frame.errorKind : undefined, ...frame })).toMatchObject({
      error_code: 'rate_limited',
      upstream_error_type: 'overloaded_error',
    });
  });

  it('relay_guidance reports the stable key', () => {
    // Guidance object produced by the production classifier
    const guided = toProviderError(404, '{"error":{"code":"model_not_found","message":"model not found"}}', undefined, { isRelay: true });
    expect(codeOf(guided)).toMatchObject({
      error_code: 'upstream_404', http_status: 404, relay_guidance: 'model_not_offered', upstream_error_type: 'model_not_found',
    });
    expect(codeOf({ kind: 'upstream', status: 502, relayGuidance: true, message: RELAY_GUIDANCE.upstreamUnavailable }))
      .toMatchObject({ error_code: 'upstream_502', relay_guidance: 'upstream_unreachable' });
    expect(codeOf({ kind: 'upstream', status: 200, relayGuidance: true, message: RELAY_HTML_PAGE_ERROR }).relay_guidance)
      .toBe('web_page_returned');
  });

  it.each([
    ['codexIdentityRequiredSwitch', 'codex_identity_switch_type'],
    ['codexIdentityRejected', 'codex_identity_still_rejected'],
    ['chatCompletionsRejectedByCodexHost', 'responses_only_endpoint'],
    ['upstreamUnavailable', 'upstream_unreachable'],
    ['modelUnavailable', 'model_not_offered'],
    ['responsesProtocolRequired', 'responses_protocol_required'],
    ['storeRejected', 'store_param_rejected'],
    ['serviceTierRejected', 'service_tier_invalid'],
    ['maxTokensRequired', 'max_tokens_required'],
    ['anthropicAuthRequired', 'anthropic_auth_header'],
    ['imageSchemaMismatch', 'image_schema_mismatch'],
    ['imageGenerationEndpointUnavailable', 'images_endpoint_unavailable'],
    ['imageResponseFormatRejected', 'image_response_format_rejected'],
    ['clientGated', 'client_gated'],
  ] as const)('relay_guidance key table (keyed by the stableKey): %s -> %s', (guidance, stableKey) => {
    expect(relayGuidanceStableKey(RELAY_GUIDANCE[guidance])).toBe(stableKey);
    // An older object carrying only relayGuidance:true is looked up by its source sentence and gives the same result
    expect(codeOf({ kind: 'upstream', status: 400, relayGuidance: true, message: RELAY_GUIDANCE[guidance] }).relay_guidance)
      .toBe(stableKey);
  });

  it('the key table has exactly 14 entries, one per RELAY_GUIDANCE entry', () => {
    expect(Object.keys(RELAY_GUIDANCE)).toHaveLength(14);
  });

  it('the production classifier attaches the specific key to the ProviderError', () => {
    const upstream = toProviderError(502, 'upstream_error: Upstream authentication failed', undefined, { isRelay: true });
    expect(upstream.relayGuidanceKey).toBe('upstream_unreachable');
    expect(codeOf(upstream)).toMatchObject({ error_code: 'upstream_502', relay_guidance: 'upstream_unreachable' });
  });

  it('error_class is present only for unknown, and must match the safe shape', () => {
    expect(codeOf(new RangeError('boom')).error_class).toBe('RangeError');
    expect('error_class' in codeOf({ name: 'has space' })).toBe(false);
    expect('error_class' in codeOf(Object.assign(new Error('x'), { kind: 'rateLimited', status: 429 }))).toBe(false);
  });

  it('latency_ms passes through unchanged and never carries error text', () => {
    const out = codeOf(Object.assign(new Error('secret upstream body'), { kind: 'upstream', status: 500, detail: 'secret' }));
    expect(out.latency_ms).toBe(1234);
    expect(JSON.stringify(out)).not.toMatch(/secret/);
  });
});
