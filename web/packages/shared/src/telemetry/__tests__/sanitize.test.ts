import { describe, expect, it } from 'vitest';
import { sanitizeProperties, sanitizeTelemetryPath } from '../sanitize';

describe('sanitizeProperties', () => {
  it('returns undefined unchanged', () => {
    expect(sanitizeProperties(undefined)).toBeUndefined();
  });

  it('drops blacklisted PII keys but keeps email (ProductAnalytics person display)', () => {
    const result = sanitizeProperties({
      provider_id: 'openai',
      apiKey: 'sk-xxx',
      api_key: 'sk-xxx',
      Authorization: 'Bearer xxx',
      email: 'a@b.com',
      message_content: 'hi',
      content: 'hi',
      prompt: 'hi',
      bearer: 'xxx',
      token: 'xxx',
    });
    expect(result).toEqual({ provider_id: 'openai', email: 'a@b.com' });
  });

  it('keeps safe keys including hashed identifiers', () => {
    const result = sanitizeProperties({
      provider_id: 'openai',
      model_id: 'gpt-4',
      email_hash: 'abcd1234',
      latency_ms: 320,
      success: true,
      attachment_types: ['image', 'pdf'],
    });
    expect(result).toEqual({
      provider_id: 'openai',
      model_id: 'gpt-4',
      email_hash: 'abcd1234',
      latency_ms: 320,
      success: true,
      attachment_types: ['image', 'pdf'],
    });
  });

  it('keeps audited diagnostic and aggregate keys while credential variants stay blocked', () => {
    const result = sanitizeProperties({
      error_code: 'network_timeout',
      last_error_code: 'invalid_key',
      prompt_tokens: 10,
      completion_tokens: 20,
      input_tokens: 30,
      output_tokens: 40,
      message_count: 2,
      message_length: 100,
      has_image_output: false,
      is_authenticated: true,
      oob_code: 'secret-code',
      provider_api_key: 'sk-secret',
    });

    expect(result).toEqual({
      error_code: 'network_timeout',
      last_error_code: 'invalid_key',
      prompt_tokens: 10,
      completion_tokens: 20,
      input_tokens: 30,
      output_tokens: 40,
      message_count: 2,
      message_length: 100,
      has_image_output: false,
      is_authenticated: true,
    });
  });

  it('truncates oversized strings', () => {
    const big = 'x'.repeat(2000);
    const result = sanitizeProperties({ note: big }, 10);
    expect(result?.note).toBe(`${'x'.repeat(10)}…`);
  });

  it('is case-insensitive on PII matching', () => {
    const result = sanitizeProperties({
      APIKEY: 'sk-xxx',
      Password: 'pw',
      keep_me: 1,
    });
    expect(result).toEqual({ keep_me: 1 });
  });

  it('drops sensitive key variants and nested payloads', () => {
    const result = sanitizeProperties({
      accessToken: 'access-token',
      refresh_token: 'refresh-token',
      provider_api_key: 'sk-provider',
      message: 'hello',
      input: 'raw prompt',
      output: 'raw completion',
      safe_count: 2,
      metadata: {
        Authorization: 'Bearer nested',
        display_plan: 'pro',
        messages: [{ content: 'nested message' }],
      },
      tags: ['safe', 'values'],
    } as never);

    expect(result).toEqual({
      safe_count: 2,
      metadata: {
        display_plan: 'pro',
      },
      tags: ['safe', 'values'],
    });
  });

  it('keeps auth_mode, which names a connection mode rather than a credential', () => {
    // The name contains the fragment "auth", so without an exact allowlist entry the substring
    // scrubber silently drops it: 450 provider_key_validated events in a row carried no such field,
    // which made the whole subscription path invisible on the dashboard.
    expect(sanitizeProperties({
      auth_mode: 'subscription',
      authorization: 'Bearer sk-secret',
      accessToken: 'sk-secret',
    })).toEqual({ auth_mode: 'subscription' });
  });

  it('redacts sensitive query params from telemetry paths', () => {
    expect(
      sanitizeTelemetryPath('/auth/email-link?oobCode=secret&mode=signIn&continueUrl=/settings'),
    ).toBe('/auth/email-link?mode=signIn&continueUrl=%2Fsettings');
    expect(sanitizeTelemetryPath('/providers?apiKey=sk-xxx&provider=openai')).toBe(
      '/providers?provider=openai',
    );
  });
});
