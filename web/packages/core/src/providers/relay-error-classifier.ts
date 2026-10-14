import { inferModelFamily } from '@oriveo/shared/relay/family-heuristics';
import type { RelayAuthMode, RelayKind, RelayTransport } from '@oriveo/shared/pure-types';
import type { ProviderError } from './errors';
import { isRelayClientGateRejection } from './relay-client-gate';

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

  // Everything below is relay-only guidance (the English source sentences match iOS word for word; the 16 languages live under errors.relay.*).
  // Official providers that receive the same payload fall into the generic classification, and are not pointed at entries like "Providers → this connection" that do not exist for them.
  if (!context?.isRelay) return null;

  if (isRelayClientGateRejection(status, detail)) {
    return upstream(status, RELAY_GUIDANCE.clientGated, detail);
  }

  if (status === 403 && isCodexClientIdentityRejection(detail)) {
    // Only suggest changing the protocol when this request is known to use a chat protocol other than Responses. If it is already Responses (the identity headers are injected)
    // or the protocol is unknown (catalog /models, standalone image generation, no URL available), switching protocol is moot and only a custom UA / header is left.
    return upstream(status, isKnownNonResponsesRequest(context, upstreamURL)
      ? RELAY_GUIDANCE.codexIdentityRequiredSwitch
      : RELAY_GUIDANCE.codexIdentityRejected, detail);
  }

  if (status === 404 && upstreamURL && isImagesGenerationsURL(upstreamURL)) {
    return upstream(status, RELAY_GUIDANCE.imageGenerationEndpointUnavailable, detail);
  }

  if (status === 400 && upstreamURL && isImagesGenerationsURL(upstreamURL) && detail.toLowerCase().includes('response_format')) {
    return upstream(status, RELAY_GUIDANCE.imageResponseFormatRejected, detail);
  }

  if (status === 404 && upstreamURL && isChatCompletionsURL(upstreamURL) && isCodexStyleHost(upstreamURL)) {
    return upstream(status, RELAY_GUIDANCE.chatCompletionsRejectedByCodexHost, detail);
  }

  if (status === 502 && isUpstreamRelayError(detail)) {
    return upstream(status, RELAY_GUIDANCE.upstreamUnavailable, detail);
  }

  if ((status === 404 || status === 400) && isUpstreamModelUnavailable(detail)) {
    return upstream(status, RELAY_GUIDANCE.modelUnavailable, detail);
  }

  if (status === 400 && isUpstreamResponsesProtocolMismatch(detail) && isOpenAIChatContext(context)) {
    return upstream(status, RELAY_GUIDANCE.responsesProtocolRequired, detail);
  }

  if (status === 400 && isUnknownStoreParameter(detail)) {
    return upstream(status, RELAY_GUIDANCE.storeRejected, detail);
  }

  if (status === 400 && isInvalidServiceTier(detail)) {
    return upstream(status, RELAY_GUIDANCE.serviceTierRejected, detail);
  }

  if (status === 400 && isMissingMaxTokens(detail) && isAnthropicContext(context)) {
    return upstream(status, RELAY_GUIDANCE.maxTokensRequired, detail);
  }

  if ((status === 401 || status === 403) && isAnthropicAuthMismatch(detail, context)) {
    return {
      kind: 'invalidKey',
      title: 'Invalid API Key',
      message: RELAY_GUIDANCE.anthropicAuthRequired,
      detail,
      relayGuidance: true,
    };
  }

  if (status === 400 && isImageUrlSchemaMismatch(detail) && isLikelyOpenAIModelOnAnthropic(context)) {
    return upstream(status, RELAY_GUIDANCE.imageSchemaMismatch, detail);
  }

  // A 429 produces no relay guidance: it goes back to classifyProviderError's generic 429 classification (quota / rate limit), the same as iOS.
  return null;
}

/**
 * The English source sentences of the relay error guidance, word for word the same as the keys in iOS `Localizable.xcstrings`;
 * apps/app `error-i18n.ts` looks up `errors.relay.*` by the original sentence, so changing anything here must be mirrored in en.json.
 */
export const RELAY_GUIDANCE = {
  codexIdentityRequiredSwitch: 'This connection requires a Codex client identity. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.',
  codexIdentityRejected: 'This connection still rejects Oriveo\'s Codex client identity. Open Providers → this connection → Edit connection → Headers & query params and set a custom User-Agent or header, or switch to another connection.',
  imageGenerationEndpointUnavailable: 'This connection doesn\'t offer a separate image generation API. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses. Oriveo will then generate images inside the chat instead.',
  chatCompletionsRejectedByCodexHost: 'This connection only exposes /v1/responses and rejects /chat/completions. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.',
  imageResponseFormatRejected: 'This image model doesn\'t accept the response_format parameter. Try a different image model ID.',
  upstreamUnavailable: 'This connection could not reach its upstream provider. This is not your configuration — its administrator\'s upstream account may be invalid, out of credits, or rate-limited. Switch to another connection or contact its administrator.',
  modelUnavailable: 'This connection\'s upstream does not offer this model. Open Providers → this connection → Model Library and enable a model it actually offers. You can ask its administrator for the exact list of available model IDs.',
  responsesProtocolRequired: 'This connection requires the OpenAI Responses protocol for this model. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to OpenAI Responses, then retry.',
  storeRejected: 'This connection rejects the “store/disable_response_storage” field. Open Providers → this connection → Edit connection → Compatibility and turn off “Don\'t keep responses in the cloud”, then retry.',
  serviceTierRejected: 'This connection does not accept the current service tier value. Open Providers → this connection → Edit connection → Compatibility and clear “Service Tier”, then retry.',
  maxTokensRequired: 'This connection requires the “max_tokens” parameter. Open Providers → this connection → Parameters and set “Max Tokens” (e.g. 4096), then retry.',
  anthropicAuthRequired: 'This connection expects an Anthropic-style x-api-key header. Open Providers → this connection → Edit connection → Authentication and choose “x-api-key”, then retry.',
  imageSchemaMismatch: 'Image attachments use a schema that doesn\'t match this model\'s protocol. Open Providers → this connection → Model Library → this model → Advanced and set Protocol to one that fits this model, then retry.',
  clientGated: 'This key\'s group only accepts the official Claude CLI. In the account console of the site that issued this key, move the key to a group that allows API access, or create a new key and add it in Providers → this connection → API Keys. Then retry.',
} as const;

function upstream(statusCode: number, message: string, detail: string): ProviderError {
  return {
    kind: 'upstream',
    title: `Relay Error (${statusCode})`,
    message,
    detail,
    relayGuidance: true,
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

/**
 * Whether this request is known to use a chat protocol other than Responses: if a protocol is given, look at it; the streaming chat chain carries only `{ isRelay: true }`,
 * so fall back to the actual request path and recognise only chat-protocol endpoints (Chat / Messages / Gemini generateContent / llama.cpp native /completion);
 * everything else counts as unknown protocol.
 */
function isKnownNonResponsesRequest(context: RelayErrorContext, upstreamURL?: string): boolean {
  if (context.transport && context.transport !== 'auto') return context.transport !== 'openai_responses';
  if (!upstreamURL) return false;
  const pathname = urlPathname(upstreamURL).replace(/\/+$/, '');
  return pathname.endsWith('/chat/completions')
    || pathname.endsWith('/messages')
    || pathname.endsWith('/completion')
    || /:(stream)?generatecontent$/i.test(pathname);
}

function isImagesGenerationsURL(value: string): boolean {
  return urlPathname(value).includes('/images/generations');
}

function urlPathname(value: string): string {
  try {
    return new URL(value).pathname;
  } catch {
    return value.split(/[?#]/)[0] ?? value;
  }
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
