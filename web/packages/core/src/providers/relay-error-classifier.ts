import { inferModelFamily } from '@oriveo/shared/relay/family-heuristics';
import type { RelayAuthMode, RelayKind, RelayTransport } from '@oriveo/shared/pure-types';
import type { ProviderError } from './errors';

export interface RelayErrorContext {
  /**
   * The only reliable "this is a relay request" signal. The branches below key off status codes and
   * generic error codes only, with no relay-specific body markers, so without this field their
   * checks would fire unconditionally for official providers too: a 429 from a direct Moonshot BYOK
   * connection to api.moonshot.cn would be reported as relay throttling copy, and an official
   * Anthropic 401 invalid-key or an official OpenAI/Moonshot 404 model-not-found matches the real
   * upstream's standard error format just as well. It is set to true only by the relay-specific call
   * chains (the relay branches of relay-stream.ts / ping-relay.ts / proxy-client.ts); official
   * adapters never construct a context, so it is naturally undefined.
   */
  isRelay?: boolean;
  relayKind?: RelayKind;
  transport?: Exclude<RelayTransport, 'auto'> | 'auto';
  authMode?: RelayAuthMode;
  modelID?: string;
  codexCompatIdentity?: boolean;
}

/**
 * Relay upstream error payload, in the OpenAI standard shape `{ error: { code, message, param } }`.
 * Used to recognise retryable fail-closed errors (image_generation tool unsupported, xhigh reasoning
 * unsupported).
 */
export interface RelayUpstreamErrorPayload {
  code?: string;
  message?: string;
  param?: string;
}

/** Parses a 4xx body into the OpenAI standard error shape. Returns null when it cannot be parsed. */
export function parseRelayUpstreamErrorPayload(body: string): RelayUpstreamErrorPayload | null {
  if (!body) return null;
  try {
    const parsed = JSON.parse(body) as { error?: unknown };
    const err = parsed?.error;
    if (err && typeof err === 'object') {
      const obj = err as Record<string, unknown>;
      return {
        code: typeof obj.code === 'string' ? obj.code : undefined,
        message: typeof obj.message === 'string' ? obj.message : undefined,
        param: typeof obj.param === 'string' ? obj.param : undefined,
      };
    }
    if (typeof err === 'string') return { message: err };
  } catch {
    // not JSON
  }
  return null;
}

/**
 * Legacy image_generation error classifier, kept for historical readers and tests.
 * Production dispatch does not use it to strip tools and retry automatically.
 *
 * The rules are deliberately tight so vision and image-attachment errors are not caught:
 * - Main path: param points exactly at tools[*] AND (message contains "image_generation" || code is
 *   on the allowlist)
 * - On its own: code === "tool_not_supported"
 * - Fallback: message strictly contains the underscored "image_generation" phrase
 *
 * Matching the bare word "image" is not enough - vision errors would collide with it.
 */
export function isImageGenerationToolUnsupportedError(
  payload: RelayUpstreamErrorPayload | null,
  status: number,
): boolean {
  if (status < 400 || status >= 500) return false;
  if (!payload) return false;

  const code = payload.code?.toLowerCase() ?? '';
  const message = payload.message ?? '';
  const messageLower = message.toLowerCase();
  const param = payload.param ?? '';

  if (code === 'tool_not_supported') return true;

  const paramTargetsTools = /^tools(\[\d+\](\.[a-z_]+)?)?$/i.test(param) || param.toLowerCase() === 'tools';
  const codeWhitelist = ['unknown_parameter', 'unsupported_parameter', 'invalid_parameter'];
  if (paramTargetsTools && (messageLower.includes('image_generation') || codeWhitelist.includes(code))) {
    return true;
  }

  // Fallback: it must be the underscored "image_generation" or "web_search" phrase, not a bare "image".
  // The web_search case is a compatibility classification for historical readers; production dispatch
  // does not consume this verdict to rewrite the body.
  if (messageLower.includes('image_generation')) return true;
  if (messageLower.includes('web_search')) return true;
  if (isImageEndpointModelMismatch(messageLower)) return true;

  return false;
}

/**
 * Detects "quota or balance exhausted". It lives here rather than in errors.ts because errors.ts
 * depends on this module and importing back would create a cycle; sharing one pattern keeps the two
 * sides from drifting into separate rules over time.
 * No `g` flag, so the same RegExp instance is safe to reuse (lastIndex does not apply).
 */
export const QUOTA_EXHAUSTION_PATTERN =
  /quota|daily limit|used up|insufficient quota|credit|billing hard limit|allowance|\u514d\u8d39\u989d\u5ea6|\u989d\u5ea6\u5df2\u7528\u5b8c|\u989d\u5ea6\u8017\u5c3d|\u914d\u989d\u5df2\u7528\u5b8c/;

export function isQuotaExhaustion(body: string): boolean {
  return QUOTA_EXHAUSTION_PATTERN.test(body.toLowerCase());
}

function isImageEndpointModelMismatch(messageLower: string): boolean {
  return (
    messageLower.includes('unsupported model:') &&
    messageLower.includes('only gpt-image') &&
    messageLower.includes('supported on this endpoint')
  );
}

/** Recognises "reasoning_effort=xhigh is not supported" errors, used by the existing xhigh -> high downgrade. */
export function isReasoningEffortXHighError(
  payload: RelayUpstreamErrorPayload | null,
  status: number,
): boolean {
  if (status < 400 || status >= 500) return false;
  if (!payload) return false;
  const message = (payload.message ?? '').toLowerCase();
  // xhigh is an OpenAI-internal reasoning effort value; some relays answer with "invalid value: xhigh" or "reasoning.effort".
  return (
    message.includes('xhigh') ||
    (message.includes('reasoning') && message.includes('effort'))
  );
}

export function classifyRelayHTTPError(
  status: number,
  body: string,
  upstreamURL?: string,
  context?: RelayErrorContext,
): ProviderError | null {
  const detail = body.trim();

  // Connection failures and response-header timeouts when the Web relay proxies to a user-defined
  // endpoint are transport-layer faults. The machine code is produced by /api/relay/forward so a
  // one-off network blip is not reported as a provider 5xx.
  if (status === 502 && isRelayProxyTransportFailure(detail)) {
    return {
      kind: 'network',
      title: 'Network Error',
      message: 'Unable to connect. Please check your internet connection and try again.',
      detail,
    };
  }

  if (status === 403 && isCodexClientIdentityRejection(detail)) {
    if (!isCodexStyleContext(context)) {
      return upstream(status, 'This relay requires Codex client identity. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.', detail);
    }
    if (context?.codexCompatIdentity === false) {
      return upstream(status, 'This relay requires Codex client identity. Open Settings → Providers → this relay → Edit → Compatibility and turn on “Codex compatible identity”, then retry.', detail);
    }
    return upstream(status, 'This relay still rejects Oriveo\'s Codex client identity. Open Settings → Providers → this relay → Edit → Advanced HTTP and set a custom User-Agent or custom Header, or switch to another relay / contact its administrator.', detail);
  }

  if (status === 404 && upstreamURL && isChatCompletionsURL(upstreamURL) && isCodexStyleHost(upstreamURL)) {
    return upstream(status, 'This relay only exposes /v1/responses and rejects /chat/completions. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.', detail);
  }

  if (status === 502 && isUpstreamRelayError(detail)) {
    return upstream(status, 'The relay could not reach its upstream provider. This is not your configuration — the relay administrator\'s upstream account may be invalid, out of credits, or rate-limited. Switch to another relay or contact its administrator.', detail);
  }

  // Without a relay context, do not emit relay-specific copy: official providers such as
  // OpenAI/Moonshot return the same "model_not_found" / "does not exist" text for a dead model ID,
  // and their users should not be pointed at "relay -> Edit -> Model".
  if ((status === 404 || status === 400) && context?.isRelay && isUpstreamModelUnavailable(detail)) {
    return upstream(status, 'The relay upstream does not offer this model. Open Settings → Providers → this relay → Edit → Model and change it to a model ID your relay supports.', detail);
  }

  if (status === 400 && isUpstreamResponsesProtocolMismatch(detail) && isOpenAIChatContext(context)) {
    return upstream(status, 'This relay requires the OpenAI Responses protocol. Open Settings → Providers → this relay → Edit → Relay type and switch to “Codex style (Responses)”, then retry.', detail);
  }

  if (status === 400 && isUnknownStoreParameter(detail)) {
    return upstream(status, 'This relay rejects the store/disable_response_storage field. Open Settings → Providers → this relay → Edit → Compatibility and turn off “Don\'t keep responses in the cloud”, then retry.', detail);
  }

  if (status === 400 && isInvalidServiceTier(detail)) {
    return upstream(status, 'This relay does not accept the current OpenAI service tier value. Open Settings → Providers → this relay → Edit → Compatibility and clear “OpenAI service tier”, then retry.', detail);
  }

  if (status === 400 && isMissingMaxTokens(detail) && isAnthropicContext(context)) {
    return upstream(status, 'This relay requires the max_tokens parameter. Open the model settings for this relay and set a max_tokens value, then retry.', detail);
  }

  if ((status === 401 || status === 403) && isAnthropicAuthMismatch(detail, context)) {
    return {
      kind: 'invalidKey',
      title: 'Invalid API Key',
      message: 'This relay expects an Anthropic-style x-api-key header. Open Settings → Providers → this relay → Edit → Auth and switch to “x-api-key”, then retry.',
      detail,
    };
  }

  if (status === 400 && isImageUrlSchemaMismatch(detail) && isLikelyOpenAIModelOnAnthropic(context)) {
    return upstream(status, 'Image attachments use the wrong schema for this relay protocol. The model and protocol may not match — open Settings → Providers → this relay → Edit → Relay type and switch to a type that fits your model, then retry.', detail);
  }

  // A 429 whose body explicitly says quota or balance is exhausted goes back to toProviderError and
  // is classified as quotaExceeded - swallowing every 429 here made a relay upstream's "out of quota"
  // always render as "rate limited, try again shortly", and users kept retrying a request that could
  // never succeed.
  //
  // This branch keys off the status code alone and carries no relay-specific body marker, so it used
  // to fire for every provider: a 429 from a direct Moonshot BYOK connection to api.moonshot.cn was
  // answered with "switch to another key / relay", which is the wrong advice for an official provider.
  // Only a confirmed relay request (context.isRelay) produces this relay-specific copy; official
  // providers fall back to classifyProviderError's own generic 429 classification
  // (quota/unavailable/rateLimited).
  if (status === 429 && context?.isRelay && !isQuotaExhaustion(detail)) {
    return {
      kind: 'rateLimited',
      title: 'Rate Limited',
      message: 'This relay hit a rate limit. Wait a moment, lower request volume, or switch to another key / relay.',
      detail,
    };
  }

  return null;
}

function upstream(statusCode: number, message: string, detail: string): ProviderError {
  return {
    kind: 'upstream',
    title: `Relay Error (${statusCode})`,
    message,
    detail,
  };
}

function isRelayProxyTransportFailure(body: string): boolean {
  try {
    const parsed = JSON.parse(body) as { code?: unknown };
    return parsed.code === 'relay_upstream_timeout'
      || parsed.code === 'relay_upstream_connection_failed';
  } catch {
    return false;
  }
}

function isCodexClientIdentityRejection(body: string): boolean {
  return [
    'Codex official clients',
    'Codex \u5b98\u65b9\u5ba2\u6237\u7aef',
    'Codex \u5b98\u65b9\u5ba2\u6236\u7aef',
    'Codex \u516c\u5f0f\u30af\u30e9\u30a4\u30a2\u30f3\u30c8',
    'Codex 공식 클라이언트',
  ].some((needle) => body.toLowerCase().includes(needle.toLowerCase()));
}

function isUpstreamRelayError(body: string): boolean {
  return [
    'upstream_error',
    'Upstream authentication',
    'Upstream timeout',
    'upstream service',
    '\u4e0a\u6e38\u8ba4\u8bc1',
    '\u4e0a\u6e38\u670d\u52a1',
  ].some((needle) => body.toLowerCase().includes(needle.toLowerCase()));
}

function isUpstreamResponsesProtocolMismatch(body: string): boolean {
  const lower = body.toLowerCase();
  return lower.includes('unknown parameter') && body.includes('input[');
}

function isUnknownStoreParameter(body: string): boolean {
  const lower = body.toLowerCase();
  if (!lower.includes('unknown parameter') && !lower.includes('unrecognized parameter')) return false;
  return lower.includes("'store'") || lower.includes('"store"') || lower.includes('disable_response_storage');
}

function isInvalidServiceTier(body: string): boolean {
  const lower = body.toLowerCase();
  if (!lower.includes('service_tier') && !lower.includes('service tier')) return false;
  return lower.includes('invalid') || lower.includes('not allowed') || lower.includes('unsupported');
}

function isMissingMaxTokens(body: string): boolean {
  const lower = body.toLowerCase();
  if (!lower.includes('max_tokens')) return false;
  return lower.includes('required') || lower.includes('must include') || lower.includes('missing') || lower.includes('\u7f3a\u5c11');
}

function isAnthropicAuthMismatch(body: string, context?: RelayErrorContext): boolean {
  // Without a relay context, do not emit relay-specific copy: a direct official Anthropic connection
  // returns the very same
  // `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}` for an
  // invalid key, and the xApiKeyHints && authErrorHints check below matches that real upstream format
  // unconditionally, turning "your key is invalid" into "your relay should switch to x-api-key auth"
  // - a setting official providers do not even have.
  if (!context?.isRelay) return false;
  const lower = body.toLowerCase();
  if (
    context?.authMode === 'bearer' &&
    context.modelID &&
    inferModelFamily(context.modelID) === 'anthropic' &&
    (lower.includes('invalid api key') || lower.includes('unauthorized') || lower.includes('authentication'))
  ) {
    return true;
  }
  const xApiKeyHints = lower.includes('x-api-key') || lower.includes('anthropic-version');
  const authErrorHints = lower.includes('authentication_error') || lower.includes('authentication failed') || lower.includes('required');
  return xApiKeyHints && authErrorHints;
}

function isImageUrlSchemaMismatch(body: string): boolean {
  const lower = body.toLowerCase();
  if (!lower.includes('image_url') && !lower.includes('image content')) return false;
  return lower.includes('invalid') || lower.includes('not allowed') || lower.includes('unknown') || lower.includes('unsupported');
}

function isUpstreamModelUnavailable(body: string): boolean {
  return [
    '\u4e0d\u652f\u6301\u7684\u6a21\u578b',
    'model_not_found',
    'model not found',
    'does not exist',
    'unknown model',
  ].some((needle) => body.toLowerCase().includes(needle.toLowerCase()));
}

function isChatCompletionsURL(value: string): boolean {
  try {
    return new URL(value).pathname.includes('/chat/completions');
  } catch {
    return value.includes('/chat/completions');
  }
}

// Weak hint that a host speaks the OpenAI Responses protocol rather than Chat Completions, used
// only to sharpen the copy on a 404. Relays built for the Codex protocol very often say so in
// their hostname, and that is all this looks for. Both directions of error are cheap: a false
// positive only shows up on a 404 that already came back from a /chat/completions URL, and a
// false negative falls through to the generic "not found" message.
function isCodexStyleHost(value: string): boolean {
  try {
    return new URL(value).host.toLowerCase().includes('codex');
  } catch {
    return value.toLowerCase().includes('codex');
  }
}

function isCodexStyleContext(context?: RelayErrorContext): boolean {
  return context?.relayKind === 'codex_style' || context?.transport === 'openai_responses';
}

// The test is `!context?.transport` rather than `!context`: the live chat stream in relay-stream.ts
// now passes `{ isRelay: true }` with an unknown transport to mark "this is a relay request", and
// with `!context` a non-undefined context that simply omits transport would be read as "known
// transport that does not match", silently disabling a branch that should stay permissive. The two
// spellings behave identically when context is undefined.
function isOpenAIChatContext(context?: RelayErrorContext): boolean {
  return !context?.transport || context.transport === 'openai_chat_completions' || context.transport === 'auto';
}

function isAnthropicContext(context?: RelayErrorContext): boolean {
  return !context?.transport || context.transport === 'anthropic_messages';
}

function isLikelyOpenAIModelOnAnthropic(context?: RelayErrorContext): boolean {
  if (!context?.transport) return true;
  if (context.transport !== 'anthropic_messages') return false;
  return context.modelID ? inferModelFamily(context.modelID) === 'openai' : true;
}
