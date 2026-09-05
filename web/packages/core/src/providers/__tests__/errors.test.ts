import { describe, expect, it } from 'vitest';
import { toProviderError } from '../errors';

describe('toProviderError', () => {
  it('classifies 402 Payment Required as quotaExceeded', () => {
    // OpenRouter BYOK out of credits is an account condition and must not land in the upstream bucket, which would report to Sentry and wrongly advise a retry
    const err = toProviderError(
      402,
      '{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}',
    );
    expect(err.kind).toBe('quotaExceeded');
  });

  it('classifies 402 with empty body as quotaExceeded', () => {
    expect(toProviderError(402, '').kind).toBe('quotaExceeded');
  });

  it('keeps unknown 4xx fallback as upstream', () => {
    expect(toProviderError(418, '').kind).toBe('upstream');
  });

  it.each(['relay_upstream_timeout', 'relay_upstream_connection_failed'])(
    'classifies Web Relay transport code %s as network noise',
    (code) => {
      const err = toProviderError(502, JSON.stringify({
        error: 'Relay upstream request aborted',
        code,
      }));
      expect(err.kind).toBe('network');
    },
  );

  it('keeps a real relay upstream 502 as operational upstream failure', () => {
    const err = toProviderError(
      502,
      '{"error":{"type":"upstream_error","message":"Upstream authentication failed"}}',
    );
    expect(err.kind).toBe('upstream');
    expect(err.source).toBe('provider');
  });

  // An official Moonshot BYOK connection talks to api.moonshot.cn directly, where a gateway-level
  // 429 arrives with an empty body and no parseable error.message. classifyRelayHTTPError would
  // then unconditionally produce relay wording ("This relay hit a rate limit... switch to another
  // key / relay"), which is the wrong advice for a user on an official provider. The official
  // adapter never passes relayErrorContext, so 422/429 has to fall back to the generic
  // classification in errors.ts.
  it('official Moonshot BYOK 429 with an empty body (no parseable upstream message): generic rateLimited text, never relay wording', () => {
    const err = toProviderError(429, '', 'https://api.moonshot.cn/v1/chat/completions');
    expect(err.kind).toBe('rateLimited');
    expect(err.message).toBe('You have exceeded the rate limit. Please wait a moment and try again.');
    expect(err.message).not.toContain('relay');
  });

  it('relay 429 with an empty body and a confirmed relay context: keeps the relay-specific wording (no regression)', () => {
    const err = toProviderError(429, '', 'https://relay.example.com/v1/chat/completions', { isRelay: true });
    expect(err.kind).toBe('rateLimited');
    expect(err.message).toContain('relay');
  });

  it('official Anthropic 401 with the real upstream authentication_error shape: falls to errors.ts generic 401 handling, never the relay x-api-key branch', () => {
    // The generic 401 branch in errors.ts hits isUnauthorizedError first, because the body contains
    // the substring "authentication", producing unauthorized/Access Expired. That coarseness
    // belongs to the generic classifier itself. This test locks one thing only: the error must not
    // land in the x-api-key branch of classifyRelayHTTPError, whose title and message are the wrong
    // advice for an official provider.
    const err = toProviderError(401, '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}');
    expect(err.kind).toBe('unauthorized');
    expect(err.title).not.toBe('Invalid API Key');
  });

  it('official OpenAI-shaped 404 model_not_found: falls back to the generic 404 classification, not "relay upstream"', () => {
    const err = toProviderError(
      404,
      '{"error":{"message":"The model `gpt-99` does not exist or you do not have access to it.","type":"invalid_request_error","code":"model_not_found"}}',
    );
    expect(err.title).not.toContain('Relay');
  });

  it('Moonshot engine overload: preserves the sanitized upstream text and marks provider ownership', () => {
    const err = toProviderError(
      429,
      JSON.stringify({
        error: {
          type: 'engine_overloaded_error',
          message: 'The engine is currently overloaded, please try again later',
        },
      }),
      'https://api.moonshot.cn/v1/chat/completions',
    );

    expect(err).toMatchObject({
      kind: 'rateLimited',
      source: 'provider',
      status: 429,
      upstreamURL: 'https://api.moonshot.cn/v1/chat/completions',
      message: 'engine_overloaded_error | The engine is currently overloaded, please try again later',
      detail: 'engine_overloaded_error | The engine is currently overloaded, please try again later',
    });
    expect(err.message).not.toContain('relay');
  });

  it('plain-text upstream body is never exposed through the user-facing provider error', () => {
    const err = toProviderError(500, 'gateway failed for Bearer secret-token-value');
    expect(err.message).toBe('The AI provider is experiencing issues. Please try again later.');
    expect(err.detail).toBeUndefined();
    expect(err.source).toBe('provider');
    expect(err.message).not.toContain('secret-token-value');
    expect(err.detail ?? '').not.toContain('secret-token-value');
  });

  describe('BYOK quota classification', () => {
    it('does not treat vendor 429 business codes as a platform free pool', () => {
      expect(toProviderError(
        429,
        '{"code":42920,"message":"busy","data":{"reason":"network_pool","retryAfter":4}}',
      ).kind).toBe('rateLimited');
      expect(toProviderError(
        429,
        '{"code":42930,"message":"limited","data":{"reason":"subject_restricted","restrictionUntil":"2026-08-25T12:00:00Z"}}',
      ).kind).toBe('rateLimited');
    });

    it('403 + quota body → quotaExceeded', () => {
      const err = toProviderError(403, '{"error":{"message":"insufficient quota"}}');
      expect(err.kind).toBe('quotaExceeded');
    });

    it('401 + session body → unauthorized', () => {
      const err = toProviderError(401, '{"error":{"message":"session expired"}}');
      expect(err.kind).toBe('unauthorized');
    });
  });
});
