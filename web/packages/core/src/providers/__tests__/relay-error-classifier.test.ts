import { describe, expect, it } from 'vitest';

import {
  classifyRelayHTTPError,
  isImageGenerationToolUnsupportedError,
  isReasoningEffortXHighError,
  parseRelayUpstreamErrorPayload,
} from '../relay-error-classifier';

describe('classifyRelayHTTPError', () => {
  it('Rule 1: unknown input parameter points to Codex style Responses', () => {
    const error = classifyRelayHTTPError(400, `{"error":{"message":"Unknown parameter: 'input[0].content[0].image_url.url'"}}`);
    expect(error?.message).toContain('Codex style');
    expect(error?.message).toContain('Responses');
  });

  it('Rule 2: image_url schema mismatch points to Relay type', () => {
    const error = classifyRelayHTTPError(400, `{"error":{"message":"image_url is invalid for this protocol"}}`);
    expect(error?.message).toContain('Relay type');
  });

  it('Rule 3: Anthropic auth mismatch points to x-api-key (relay context required)', () => {
    const error = classifyRelayHTTPError(403, `{"error":{"message":"invalid api key"}}`, undefined, {
      isRelay: true,
      transport: 'anthropic_messages',
      authMode: 'bearer',
      modelID: 'claude-3-5-sonnet',
    });
    expect(error?.kind).toBe('invalidKey');
    expect(error?.message).toContain('x-api-key');
  });

  it('Rule 4: Codex identity rejection first points non-Codex configs to Codex style', () => {
    const error = classifyRelayHTTPError(403, 'Only Codex official clients are allowed.', undefined, {
      transport: 'openai_chat_completions',
      relayKind: 'openai_compatible',
    });
    expect(error?.message).toContain('Codex style');
  });

  it('Rule 4: Codex identity rejection points disabled identity to the identity toggle', () => {
    const error = classifyRelayHTTPError(403, 'Only Codex official clients are allowed.', undefined, {
      transport: 'openai_responses',
      relayKind: 'codex_style',
      codexCompatIdentity: false,
    });
    expect(error?.message).toContain('Codex compatible identity');
  });

  it('Rule 4b: Codex identity rejection after identity injection points to custom User-Agent', () => {
    const error = classifyRelayHTTPError(403, 'Only Codex official clients are allowed.', undefined, {
      transport: 'openai_responses',
      relayKind: 'codex_style',
      codexCompatIdentity: true,
    });
    expect(error?.message).toContain('custom User-Agent');
  });

  it('Rule 5: Codex host 404 on chat completions points to Codex style', () => {
    const error = classifyRelayHTTPError(404, '{"error":"not found"}', 'https://codex.relay.example.com/v1/chat/completions');
    expect(error?.message).toContain('Codex style');
  });

  it('Rule 6: max_tokens missing points to model max_tokens', () => {
    const error = classifyRelayHTTPError(400, 'max_tokens: Field required');
    expect(error?.message).toContain('max_tokens');
  });

  it('Rule 7: invalid service tier points to OpenAI service tier', () => {
    const error = classifyRelayHTTPError(400, 'service_tier is invalid');
    expect(error?.message).toContain('OpenAI service tier');
  });

  it('Rule 8: store parameter rejection points to response storage toggle', () => {
    const error = classifyRelayHTTPError(400, `Unknown parameter: 'store'`);
    expect(error?.message).toContain('cloud');
  });

  it('Rule 9: rate limit keeps a rateLimited action for a confirmed relay request', () => {
    const error = classifyRelayHTTPError(429, 'rate limit exceeded', undefined, { isRelay: true });
    expect(error?.kind).toBe('rateLimited');
    expect(error?.message).toContain('rate limit');
  });

  it('Rule 10: upstream_error points to relay administrator/upstream', () => {
    const error = classifyRelayHTTPError(502, `{"error":{"type":"upstream_error","message":"Upstream authentication failed"}}`);
    expect(error?.message).toContain('relay administrator');
  });

  // A Moonshot BYOK 429 straight from api.moonshot.cn was classified with relay rate-limit copy, because
  // these branches keyed only on the status code and generic upstream error codes and fired unconditionally
  // even with no relay context.
  describe('official providers with no context produce no relay-specific copy', () => {
    it('429 without relay context: returns null so errors.ts falls back to the generic rateLimited classification', () => {
      const error = classifyRelayHTTPError(429, 'rate limit exceeded');
      expect(error).toBeNull();
    });

    it('429 quota-exhaustion body without relay context: still null regardless of isRelay (quota check runs first)', () => {
      const relay = classifyRelayHTTPError(429, 'insufficient quota', undefined, { isRelay: true });
      const official = classifyRelayHTTPError(429, 'insufficient quota');
      expect(relay).toBeNull();
      expect(official).toBeNull();
    });

    it('401 real Anthropic authentication_error/x-api-key body without relay context: returns null, no "This relay expects" wording', () => {
      const error = classifyRelayHTTPError(
        401,
        '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
      );
      expect(error).toBeNull();
    });

    it('404 real OpenAI-shaped model_not_found body without relay context: returns null, no "relay upstream" wording', () => {
      const error = classifyRelayHTTPError(
        404,
        '{"error":{"message":"The model `gpt-99` does not exist or you do not have access to it.","type":"invalid_request_error","code":"model_not_found"}}',
      );
      expect(error).toBeNull();
    });
  });

  describe('relay requests (context.isRelay) keep their relay-specific copy', () => {
    it('401 Anthropic auth mismatch still resolves for a confirmed relay request', () => {
      const error = classifyRelayHTTPError(
        401,
        '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}',
        undefined,
        { isRelay: true },
      );
      expect(error?.kind).toBe('invalidKey');
      expect(error?.message).toContain('relay');
    });

    it('404 model unavailable still resolves for a confirmed relay request', () => {
      const error = classifyRelayHTTPError(404, 'model_not_found: no such model', undefined, { isRelay: true });
      expect(error?.message).toContain('relay upstream does not offer this model');
    });
  });
});

describe('isImageGenerationToolUnsupportedError', () => {
  it('matches param=tools[0].type with image_generation in the message', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { code: 'unknown_parameter', message: 'Unknown parameter: image_generation', param: 'tools[0].type' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(true);
  });

  it('matches param=tools with code=unknown_parameter', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { code: 'unknown_parameter', message: 'Tools parameter rejected', param: 'tools' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(true);
  });

  it('matches code=tool_not_supported on its own, with no param', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { code: 'tool_not_supported', message: 'No tools allowed' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(true);
  });

  it('matches the fallback where the message contains the image_generation phrase', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'image_generation is not enabled in this relay' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(true);
  });

  it('matches an image endpoint that only accepts a dedicated image model', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'unsupported model: gpt-5.5 (only gpt-image-2 is supported on this endpoint)' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(true);
  });

  it('does not match image_url alone (a vision schema mismatch), guarding against false positives', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'Invalid image_url schema for this protocol' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(false);
  });

  it('does not match 5xx status codes, which stay on the upstream failure path', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'image_generation broken' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 502)).toBe(false);
  });

  it('does not match a null payload (an unparsable body)', () => {
    expect(isImageGenerationToolUnsupportedError(null, 400)).toBe(false);
  });

  it('does not match param=tools alone when the code is not allowlisted and the message lacks image_generation', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { code: 'rate_limited', message: 'Too many requests', param: 'tools' },
    }));
    expect(isImageGenerationToolUnsupportedError(payload, 400)).toBe(false);
  });
});

describe('isReasoningEffortXHighError', () => {
  it('matches a message containing xhigh', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'Invalid value for reasoning.effort: xhigh' },
    }));
    expect(isReasoningEffortXHighError(payload, 400)).toBe(true);
  });

  it('matches a message containing reasoning and effort', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'reasoning effort is not supported' },
    }));
    expect(isReasoningEffortXHighError(payload, 400)).toBe(true);
  });

  it('does not match 5xx', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { message: 'xhigh' },
    }));
    expect(isReasoningEffortXHighError(payload, 500)).toBe(false);
  });
});

describe('parseRelayUpstreamErrorPayload', () => {
  it('parses the standard OpenAI error shape', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({
      error: { code: 'x', message: 'y', param: 'z' },
    }));
    expect(payload).toEqual({ code: 'x', message: 'y', param: 'z' });
  });

  it('falls back to the message when error is a string', () => {
    const payload = parseRelayUpstreamErrorPayload(JSON.stringify({ error: 'plain text' }));
    expect(payload).toEqual({ message: 'plain text' });
  });

  it('returns null for a non-JSON body', () => {
    expect(parseRelayUpstreamErrorPayload('not json')).toBeNull();
    expect(parseRelayUpstreamErrorPayload('')).toBeNull();
  });
});
