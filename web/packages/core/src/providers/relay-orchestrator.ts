/**
 * Relay send* orchestration layer.
 *
 * Streaming orchestration for the four transports: a buildRequest closure plus an inline chunk
 * parser, with retry/fallback handled by core relay-stream. Pure logic (body building, response
 * parsing, reasoning, direct auth, proxy config) is reused from relay-adapter.
 *
 * The upstream transport, buildFetchArgs and getRelayRuntimeConfig are injected by the host, so
 * this module never touches window/fetch/crypto directly. signal is passed through so that
 * cancellation keeps working.
 */
import { StopReasonResolver } from '../context/stop-reason';
import type { StreamFinish } from '../context/stream-finish';
import { attachmentTransportProfile } from './attachment-transport';
import { mapRelayStreamError } from '@oriveo/shared/relay/error-mapping';
import { redactRelayCredentials } from '@oriveo/shared/relay/endpoint-policy';
import { isRelayWebTransport, mergeRelayWebFragment } from '@oriveo/shared/relay/web-fragments';
import type { ContentPart, StreamEvent, StreamHandle, StreamOptions } from './types';
import type { RelayRuntimeConfig, UpstreamTransport } from '../ports';
import { buildRelayEndpointURL } from './relay-endpoints';
import {
  DEFAULT_CITATIONS_PATH as GEMINI_CITATIONS_PATH,
  DEFAULT_TITLE_FIELD as GEMINI_CITATION_TITLE_FIELD,
  DEFAULT_URL_FIELD as GEMINI_CITATION_URL_FIELD,
  detectGeminiBlockEvent,
} from './transport/strategies/gemini-generate';
import { emitAnnotationCitations } from './transport/strategies/openai-chat';
import { handleContentBlock as handleAnthropicCitationBlock } from './transport/strategies/anthropic-messages';
import { citationFromRaw, mergeCitation, readPath } from './transport/citation-utils';
import type { Citation } from '@oriveo/shared/pure-types';
import {
  relayImageRoute,
  relaySensitiveCredentialValues,
  resolveRelayAuthMode,
} from './relay-runtime-support';
import {
  parseUsageAnthropic,
  parseUsageGemini,
  parseUsageOpenAICompatible,
  parseUsageOpenAIResponses,
} from './transport/usage-parsers';
import {
  applyRelayPromptCacheKey,
  asImageItemId,
  buildDirectAuthHeaders,
  buildRelayProtocolHeaders,
  buildImagesGenerationsBody,
  buildRelayProxyConfig,
  buildResponsesContent,
  convertToAnthropicParts,
  markAnthropicCacheBreakpoint,
  convertToGeminiParts,
  convertToOpenAIChatParts,
  extractImagePrompt,
  extractText,
  mapGeminiReasoningBudget,
  normalizeBaseURL,
  parseAnthropicResponse,
  parseGeminiResponse,
  parseImagesGenerationsResponse,
  parseOpenAIChatCompletionsResponse,
  parseResponsesResponse,
  resolveOpenAIReasoningEffort,
  resolveResponsesImageResult,
  shouldRelayStream,
  toImageDataUrl,
  type RelayDirectFetchConfig,
} from './relay-adapter';
import { writeGenerationParameters } from './request-builders/generation-parameters';
import { functionToolsForProtocol } from './request-builders/tool-call-wire-adapter';
import { nativeToolCallEvents, type ToolCallProtocol } from './tool-call-protocol';
import { generationWriteFacts } from './generation-rejection-facts';
import { additionalBodyHasContent, applyAdditionalBodyInPlace, assertAdditionalBodyAccepted } from './request-builders/additional-body';
import { readTopLevelErrorFrame } from './upstream-error-text';
import { classifyInStreamProviderErrorKind, normalizeUpstreamErrorType, providerErrorRawBody, upstreamErrorTypeValue, withProviderErrorRawBody } from './errors';
import { ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS } from './protocol-implementations';
import { chatMaxOutputTokens, guardAnthropicThinking, resolveRelayAnthropicThinking } from './request-builders/anthropic-thinking';
import { compileSafeCustomFragment, rejectSafeCustomFragment, SafeCustomFragmentRejectedError } from './request-builders/safe-custom-fragment';
import { safeCustomOwners } from './request-builders/generation-parameters';
import {
  createRelayJSONStream,
  createRelayResponsesStreamWithRetry,
  createRelaySSEStream,
  fetchRelayRequest,
  fetchRelayWithFallbacks,
  relayEndpointFingerprint,
  type RelayRequest,
  type RelayResponsesRetryDetector,
  type RelayRetryHints,
} from './relay-stream';
import type { UnsupportedParamDroppedReporter } from './unsupported-param';

type RelayTransport = NonNullable<StreamOptions['relayTransport']>;

function relayGenerationUpstreamURL(
  baseURL: string,
  modelID: string,
  transport: RelayTransport,
  options: StreamOptions | undefined,
  runtimeConfig: RelayRuntimeConfig | null = null,
): string {
  if (
    options?.supportsImageGen
    && relayImageRoute(transport, runtimeConfig) === 'images_endpoint'
  ) {
    // sendRelayImagesGeneration always applies the OpenAI Chat auth and version rules when hitting the images endpoint.
    return buildRelayEndpointURL({
      baseURL,
      transport: 'openai_chat_completions',
      endpoint: 'imagesGenerations',
      exactBaseURL: options?.relayResolvedAPIBaseURLIsExact === true,
      securityMode: options?.relaySecurityMode,
    });
  }
  switch (transport) {
    case 'llamacpp_native':
      return buildRelayEndpointURL({
        baseURL,
        transport,
        endpoint: 'llamaCompletion',
        exactBaseURL: options?.relayResolvedAPIBaseURLIsExact === true,
        securityMode: options?.relaySecurityMode,
      });
    case 'openai_responses':
      return `${baseURL}/responses`;
    case 'anthropic_messages':
      return buildRelayEndpointURL({
        baseURL,
        transport,
        endpoint: 'messages',
        exactBaseURL: options?.relayResolvedAPIBaseURLIsExact === true,
        securityMode: options?.relaySecurityMode,
      });
    case 'gemini_generate_content':
      return buildRelayEndpointURL({
        baseURL,
        transport,
        endpoint: shouldRelayStream(options) ? 'geminiStreamGenerateContent' : 'geminiGenerateContent',
        modelID,
        exactBaseURL: options?.relayResolvedAPIBaseURLIsExact === true,
        securityMode: options?.relaySecurityMode,
      });
    case 'openai_chat_completions':
    default:
      return `${baseURL}/chat/completions`;
  }
}

/**
 * The chat endpoint by protocol (pure logic): apiRoot is the final API root (version segment included), and the endpoint is appended as is, without adding a version again.
 * Used when an official family goes through a non-native protocol, sharing one endpoint mapping with the Relay streaming orchestration.
 */
export function relayProtocolUpstreamURL(
  apiRoot: string,
  modelID: string,
  transport: Exclude<RelayTransport, 'llamacpp_native'>,
  options: StreamOptions | undefined,
): string {
  return relayGenerationUpstreamURL(
    apiRoot,
    modelID,
    transport,
    { ...options, supportsImageGen: false, relayResolvedAPIBaseURLIsExact: true },
  );
}

/**
 * Shared endpoint partition key for generation-parameter self-healing and "clear learned
 * capabilities". It assembles the final upstream URL from the resolved base / transport / stream
 * actually used when sending, rather than the `/api/relay/forward` proxy path.
 */
export function relayGenerationEndpointFingerprint(
  baseURL: string | undefined,
  modelID: string,
  options: StreamOptions | undefined,
  runtimeConfig: RelayRuntimeConfig | null = null,
): string | undefined {
  const resolvedBaseURL = normalizeBaseURL(
    options?.relayResolvedBaseURLText ?? baseURL,
    options?.relaySecurityMode,
  );
  const transport = options?.relayTransport ?? 'openai_chat_completions';
  return relayEndpointFingerprint(
    relayGenerationUpstreamURL(resolvedBaseURL, modelID, transport, options, runtimeConfig),
  );
}

/**
 * The two parts of the negative-cache partition that do not come from the URL: the transport
 * protocol and the injected connection identity. This module never fabricates an identity - when
 * none is injected the field is simply absent, and the write side fails closed on that.
 */
function relayLearningScopeFields(
  transport: RelayTransport,
  options: StreamOptions | undefined,
): Pick<RelayRequest, 'transport' | 'capabilityIdentity'> {
  return {
    transport,
    ...(options?.capabilityIdentity ? { capabilityIdentity: options.capabilityIdentity } : {}),
  };
}

function buildScopedFetchArgs(
  deps: RelayOrchestratorDeps,
  upstreamURL: string,
  directHeaders: Record<string, string>,
  config: RelayDirectFetchConfig,
): { url: string; headers: Record<string, string>; endpointFingerprint?: string } {
  return {
    ...deps.buildFetchArgs(upstreamURL, directHeaders, config),
    endpointFingerprint: relayEndpointFingerprint(upstreamURL),
  };
}

/** Injected orchestration dependencies: upstream transport, fetch argument construction (proxied or direct) and relay runtime config lookup. */
export interface RelayOrchestratorDeps {
  transport: UpstreamTransport;
  onUnsupportedParamDropped?: UnsupportedParamDroppedReporter;
  buildFetchArgs(
    upstreamURL: string,
    directHeaders: Record<string, string>,
    config: RelayDirectFetchConfig,
  ): { url: string; headers: Record<string, string> };
  getRelayRuntimeConfig(): RelayRuntimeConfig | null;
}

export type RelayMessages = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[];

/**
 * The final chat body boundary for relay: typed generation parameters have been written, JSON
 * serialization has not started yet.
 *
 * Every transport's `buildRequest` passes through here, so custom request fields can only be
 * applied at this point - hooking them onto a single branch would silently drop the user's fields
 * on the other four.
 *
 * Image generation does not call this (`buildImagesGenerationsBody` has its own serialization):
 * `/images/generations` does not accept these chat-protocol fields.
 */
function applyRelayGenerationParameters(
  body: Record<string, unknown>,
  options: StreamOptions | undefined,
  transport?: RelayTransport,
): void {
  const builderDefaultMaxTokens = body.max_tokens;
  const { written } = writeGenerationParameters(body, options?.generationParameters, options?.generationProfile);
  // The linkage guard keys off the connection protocol only: the builder has already written the thinking fields, so it is evaluated again after the generation parameters are written.
  if (transport === 'anthropic_messages') {
    guardAnthropicThinking(body, { profile: options?.generationProfile, written, builderDefaultMaxTokens });
  }
  applyRelaySafeCustomFragments(body, options);
  // Connection-level web search fragment: after the builder output and before the additional request body; only a chat request's options carry it.
  if (options?.relayWebFragment && isRelayWebTransport(transport)) {
    mergeRelayWebFragment(transport, body, options.relayWebFragment);
  }
  // Additional request body: the last step, merged after panel parameters and custom fragments; on a name clash it wins.
  applyAdditionalBodyInPlace(body, options?.additionalBody);
}

/**
 * The only authority for relay custom fields is the generation profile parsed locally: relay has
 * no server-provided recipe keyed by model id, so the only thing that can declare writable leaves
 * is its own exact transport profile. Every other owner (web / reasoning) and a missing profile
 * fail closed rather than guessing a compatible body shape.
 *
 * Failing closed includes an empty draft: reaching this layer means the user explicitly chose
 * "custom", so empty or invalid JSON is rejected by the compiler and this throws immediately.
 * Degrading silently would turn the "message will fail to send" warning into a lie.
 */
function applyRelaySafeCustomFragments(body: Record<string, unknown>, options: StreamOptions | undefined): void {
  const fragments = options?.customFragments;
  if (!fragments) return;
  const declaredOwners = safeCustomOwners(options?.generationProfile);
  for (const owner of ['web', 'reasoning', 'generation'] as const) {
    const declared = fragments[owner];
    if (declared === undefined) continue;
    if (owner !== 'generation' || Object.keys(declaredOwners).length === 0) {
      throw new SafeCustomFragmentRejectedError(owner, 'unknown_owned_path');
    }
    const custom = compileSafeCustomFragment(declared.raw.trim(), owner, declaredOwners, body);
    if (!custom.accepted) throw rejectSafeCustomFragment(owner, declared.raw, custom);
    mergeRelayBodyDelta(body, custom.delta);
  }
}

/** Deep-merge into the already assembled body (`applyGenerationParameters` also writes in place). */
function mergeRelayBodyDelta(body: Record<string, unknown>, delta: Readonly<Record<string, unknown>>): void {
  for (const [key, value] of Object.entries(delta)) {
    const current = body[key];
    if (isPlainRelayObject(value) && isPlainRelayObject(current)) {
      const nested = { ...current };
      mergeRelayBodyDelta(nested, value);
      body[key] = nested;
    } else {
      body[key] = value;
    }
  }
}

function isPlainRelayObject(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === 'object' && !Array.isArray(value);
}

/** Top-level in-stream `error` frame of Relay Chat / llama.cpp native; credentials are scrubbed centrally by createRelaySSEStream. */
function relayTopLevelErrorFrame(chunk: unknown): StreamEvent | null {
  const frame = readTopLevelErrorFrame(chunk);
  if (!frame) return null;
  // The raw frame is used only for local overflow detection (an overflow after body text is recorded as context_window_exceeded); it is non-enumerable and never leaves the device.
  return withProviderErrorRawBody<StreamEvent>({
    type: 'error',
    error: frame.message,
    errorKind: classifyInStreamProviderErrorKind(frame.message, frame.typeOrCode),
    source: 'provider',
    streamErrorFrame: true,
    ...(normalizeUpstreamErrorType(frame.typeOrCode) ? { upstreamErrorType: normalizeUpstreamErrorType(frame.typeOrCode) } : {}),
  }, providerErrorRawBody(JSON.stringify(chunk)));
}

function requestCredentialValues(
  apiKey: string,
  options: StreamOptions | undefined,
  authMode: ReturnType<typeof resolveRelayAuthMode>,
): string[] {
  // The none mode never writes apiKey, custom headers or query into the actual request, so it must not over-redact ordinary body fields that happen to share those names.
  if (authMode === 'none') return [];
  return [
    ...relaySensitiveCredentialValues({
      apiKey,
      headers: options?.relayHeaders,
      queryParams: options?.relayQueryParams,
    }),
    // The redaction list holds all of the connection's keys; they are never sent out anyway, so masking only guards against an upstream echo.
    ...(options?.relayConnectionKeySecrets ?? []).filter((value) => value.trim().length > 0),
  ];
}

/**
 * When the request carries the test-capability function tool (relayFunctionTool, carried only by the tool item), also produce native tool call events on the same parse:
 * the same nativeToolCallEvents as direct chat. Ordinary relay chat does not carry this tool, so parsing is unchanged.
 */
function withRelayFunctionToolCalls(
  protocol: ToolCallProtocol,
  options: StreamOptions | undefined,
  parse: (eventType: string | null, data: string) => StreamEvent | StreamEvent[] | null,
): (eventType: string | null, data: string) => StreamEvent | StreamEvent[] | null {
  if (!options?.relayFunctionTool) return parse;
  const state: Record<string, unknown> = {};
  return (eventType, data) => {
    const parsed = parse(eventType, data);
    let payload: unknown;
    try {
      payload = JSON.parse(data);
    } catch {
      return parsed;
    }
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return parsed;
    const toolEvents = nativeToolCallEvents(protocol, eventType, payload as Record<string, unknown>, state)
      .filter((event) => event.type === 'tool_calls');
    if (toolEvents.length === 0) return parsed;
    const base = parsed == null ? [] : Array.isArray(parsed) ? parsed : [parsed];
    return [...base, ...toolEvents];
  };
}

export function sendRelayStream(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string | undefined,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const resolvedBaseURL = normalizeBaseURL(
    options?.relayResolvedBaseURLText ?? baseURL,
    options?.relaySecurityMode,
  );
  const transport = options?.relayTransport ?? 'openai_chat_completions';

  // Image routing split: for an image model routed to images_endpoint, skip the chat protocol and
  // POST `/images/generations` directly. Deliberately not a new RelayTransport value - that enum is
  // a user-visible protocol choice, and the images endpoint is another path under the same transport.
  if (
    options?.supportsImageGen
    && relayImageRoute(transport, deps.getRelayRuntimeConfig()) === 'images_endpoint'
  ) {
    return sendRelayImagesGeneration(apiKey, modelID, messages, resolvedBaseURL, options, deps);
  }
  // Local rejection of the additional request body: some of the five transports assemble the body inside the
  // buildRequest closure (where an exception would turn into an in-stream error), so validate synchronously
  // here first and every protocol throws a standalone error before the request is sent.
  assertAdditionalBodyAccepted(options?.additionalBody);
  // All five transports' bodies go through the merger at the end of applyRelayGenerationParameters; the same check decides here whether it was really included.
  const additionalBodyApplied = additionalBodyHasContent(options?.additionalBody);
  const handle = sendRelayTransportStream(transport, apiKey, modelID, messages, resolvedBaseURL, options, deps);
  const generationWrite = generationWriteFacts(options);
  return { ...handle, getAdditionalBodyApplied: () => additionalBodyApplied, getGenerationWrite: () => generationWrite };
}

/** The wire shape of one Relay chat request: URL, headers (Content-Type included) and the serialized body. */
export interface RelayWireRequest {
  url: string;
  method: 'POST';
  headers: Record<string, string>;
  body: string;
}

/**
 * Pure construction of the first ordinary chat request (no send, no retry, no fallback, no self-heal): it uses the same primitives as the
 * `buildRequest` of the five streaming orchestrations - base URL normalization, protocol endpoint, auth and protocol headers, direct / proxy parameters, the four body builders -
 * and then assembles the headers and JSON body in the same shape as `fetchRelayRequest`. The Relay test capability sends only this one request.
 * Only the four chat protocols are accepted; llama.cpp native and the image generation endpoint are not, and throw. An address that fails the security policy also throws.
 */
export function buildRelayStreamRequest(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string | undefined,
  options: StreamOptions | undefined,
  deps: Pick<RelayOrchestratorDeps, 'buildFetchArgs' | 'getRelayRuntimeConfig'>,
): RelayWireRequest {
  const resolvedBaseURL = normalizeBaseURL(
    options?.relayResolvedBaseURLText ?? baseURL,
    options?.relaySecurityMode,
  );
  const transport = options?.relayTransport ?? 'openai_chat_completions';
  if (transport === 'llamacpp_native') throw new Error(`Unsupported relay transport ${transport}`);
  assertAdditionalBodyAccepted(options?.additionalBody);
  const runtimeConfig = deps.getRelayRuntimeConfig();
  const authMode = resolveRelayAuthMode(options, transport, runtimeConfig);
  let body: Record<string, unknown>;
  switch (transport) {
    case 'openai_responses':
      body = buildRelayResponsesBody(modelID, messages, options, runtimeConfig).body;
      break;
    case 'anthropic_messages':
      body = buildRelayAnthropicMessagesBody(modelID, messages, options);
      break;
    case 'gemini_generate_content':
      body = buildRelayGeminiGenerateContentBody(messages, options);
      break;
    case 'openai_chat_completions':
    default:
      body = buildRelayChatCompletionsBody(modelID, messages, options).body;
      break;
  }
  const directHeaders: Record<string, string> = transport === 'anthropic_messages'
    ? { ...buildDirectAuthHeaders(apiKey, authMode), ...buildRelayProtocolHeaders(transport) }
    : buildDirectAuthHeaders(apiKey, authMode);
  const proxyConfig = buildRelayProxyConfig(apiKey, transport, authMode, options);
  applyRelayPromptCacheKey(body, proxyConfig, messages);
  const { url, headers } = deps.buildFetchArgs(
    relayGenerationUpstreamURL(resolvedBaseURL, modelID, transport, options),
    directHeaders,
    proxyConfig,
  );
  return {
    url,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body: JSON.stringify(body),
  };
}

function sendRelayTransportStream(
  transport: RelayTransport,
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  resolvedBaseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  switch (transport) {
    case 'anthropic_messages':
      return sendAnthropicMessagesStream(apiKey, modelID, messages, resolvedBaseURL, options, deps);
    case 'gemini_generate_content':
      return sendGeminiGenerateContentStream(apiKey, modelID, messages, resolvedBaseURL, options, deps);
    case 'llamacpp_native':
      return sendLlamaCppNativeStream(apiKey, modelID, messages, resolvedBaseURL, options, deps);
    case 'openai_responses':
      return sendOpenAIResponsesStream(apiKey, modelID, messages, resolvedBaseURL, options, deps);
    case 'openai_chat_completions':
    default:
      return sendOpenAIChatCompletionsStream(apiKey, modelID, messages, resolvedBaseURL, options, deps);
  }
}

/**
 * llama.cpp native folds the whole conversation into one prompt, which can only carry text. Images cannot
 * be delivered, so the placeholder text from the line declaration stands in for them and tells the model
 * that this turn had an image that did not arrive (otherwise the user attaches an image, the model never
 * sees it, and nothing in the UI says so). Files never reach this point: this line has no native file
 * block, and the client has already injected files into the text.
 */
export function buildLlamaCppNativePrompt(messages: RelayMessages): string {
  const imagePlaceholder = attachmentTransportProfile('relay_llamacpp_native').imagePlaceholderText;
  return messages.map((message) => {
    const text = typeof message.content === 'string'
      ? message.content
      : message.content
        .map((part) => part.type === 'text'
          ? part.text
          : part.type === 'image_url' ? imagePlaceholder : undefined)
        .filter((line): line is string => line !== undefined)
        .join('\n');
    return `${message.role}: ${text}`;
  }).join('\n');
}

interface LlamaCppCompletionChunk {
  content?: string;
  completion?: string;
  stop?: boolean;
  stop_type?: unknown;
  stopped_eos?: unknown;
  stopped_word?: unknown;
  stopped_limit?: unknown;
}

function llamaCppFinish(chunk: LlamaCppCompletionChunk): StreamFinish {
  return { family: 'llama_cpp', ended: 'clean', finishRaw: StopReasonResolver.llamaCppFinishRaw(chunk) };
}

/** Native llama.cpp server `/completion`. The model and chat template are managed by the engine, so it must not be disguised as OpenAI Chat. */
function sendLlamaCppNativeStream(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const controller = new AbortController();
  const relayStream = shouldRelayStream(options);
  const prompt = buildLlamaCppNativePrompt(messages);
  const transport: RelayTransport = 'llamacpp_native';
  const authMode = resolveRelayAuthMode(options, transport, deps.getRelayRuntimeConfig());
  const sensitiveCredentialValues = requestCredentialValues(apiKey, options, authMode);
  const body: Record<string, unknown> = { prompt, stream: relayStream };
  applyRelayGenerationParameters(body, options);
  const buildRequest = (): RelayRequest => {
    const upstreamURL = relayGenerationUpstreamURL(baseURL, modelID, transport, options);
    const { url, headers, endpointFingerprint } = buildScopedFetchArgs(
      deps,
      upstreamURL,
      buildDirectAuthHeaders(apiKey, authMode),
      buildRelayProxyConfig(apiKey, transport, authMode, options),
    );
    return { url, headers, body, modelID, endpointFingerprint, ...relayLearningScopeFields(transport, options) };
  };
  const parseCompletion = (_eventType: string | null, data: string): StreamEvent | null => {
    const chunk = JSON.parse(data) as LlamaCppCompletionChunk;
    const errorFrame = relayTopLevelErrorFrame(chunk);
    if (errorFrame) return errorFrame;
    if (chunk.content ?? chunk.completion) return { type: 'delta', content: chunk.content ?? chunk.completion ?? '' };
    // stop:true is the llama.cpp terminal frame; finishRaw takes stop_type (older servers derive it from the stopped_* booleans).
    return chunk.stop ? { type: 'done', finish: llamaCppFinish(chunk) } : null;
  };
  const stream = relayStream
    ? createRelaySSEStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        parseCompletion,
        controller.signal,
        sensitiveCredentialValues,
      )
    : createRelayJSONStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        (payload) => {
          const response = (payload ?? {}) as LlamaCppCompletionChunk;
          return [
            { type: 'delta', content: response.content ?? response.completion ?? '' },
            { type: 'done', finish: llamaCppFinish(response) },
          ];
        },
        controller.signal,
        sensitiveCredentialValues,
      );
  return { stream, abort: () => controller.abort() };
}

/**
 * One-shot image generation via `/images/generations` (imagesEndpoint routing).
 *
 * Unlike the chat protocol there is no conversation context and no streaming - a single POST
 * returns `data[].b64_json`. Measured much faster than the inline Responses tool (21s vs 62s),
 * and the `model` parameter actually takes effect.
 */
function sendRelayImagesGeneration(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const controller = new AbortController();
  const transport: RelayTransport = 'openai_chat_completions';
  const prompt = options?.relayImagePrompt?.trim() || extractImagePrompt(messages);

  if (!prompt) {
    // Fail before opening a connection: an image request with no prompt has nothing to send.
    return {
      stream: new ReadableStream<StreamEvent>({
        start(ctrl) {
          ctrl.enqueue({
            type: 'error',
            error: 'Image generation requires a text prompt.',
            errorKind: 'badRequest',
            source: 'oriveo',
          });
          ctrl.enqueue({ type: 'done' });
          ctrl.close();
        },
      }),
      abort: () => controller.abort(),
    };
  }

  const authMode = resolveRelayAuthMode(options, transport, deps.getRelayRuntimeConfig());
  const sensitiveCredentialValues = requestCredentialValues(apiKey, options, authMode);
  const { url, headers } = deps.buildFetchArgs(
    relayGenerationUpstreamURL(
      baseURL,
      modelID,
      transport,
      options,
      deps.getRelayRuntimeConfig(),
    ),
    buildDirectAuthHeaders(apiKey, authMode),
    buildRelayProxyConfig(apiKey, transport, authMode, options),
  );
  const body = buildImagesGenerationsBody(modelID, prompt, options);

  const stream = createRelayJSONStream(
    (signal) => deps.transport.fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers },
      body: JSON.stringify(body),
      signal,
    }),
    parseImagesGenerationsResponse,
    controller.signal,
    sensitiveCredentialValues,
  );

  return { stream, abort: () => controller.abort() };
}

/** The Relay Chat Completions request body (pure logic; shared by the streaming orchestration and an official family on a non-native protocol). */
export function buildRelayChatCompletionsBody(
  modelID: string,
  messages: RelayMessages,
  options: StreamOptions | undefined,
): { body: Record<string, unknown>; reasoningEffort: ReturnType<typeof resolveOpenAIReasoningEffort> } {
  const relayStream = shouldRelayStream(options);
  const body: Record<string, unknown> = {
    model: modelID,
    stream: relayStream,
    messages: messages.map((message) => ({
      role: message.role,
      content: typeof message.content === 'string'
        ? message.content
        : convertToOpenAIChatParts(message.content),
    })),
  };
  if (options?.relayMaxOutputTokens !== undefined) {
    body.max_tokens = options.relayMaxOutputTokens;
  }
  if (relayStream) {
    body.stream_options = { include_usage: true };
  }
  if (options?.relayFunctionTool) {
    body.tools = functionToolsForProtocol('openai_chat', [options.relayFunctionTool]);
  }

  const reasoningEffort = resolveOpenAIReasoningEffort(options);
  if (reasoningEffort) {
    body.reasoning_effort = reasoningEffort;
  }
  applyRelayGenerationParameters(body, options, 'openai_chat_completions');
  return { body, reasoningEffort };
}

function sendOpenAIChatCompletionsStream(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const controller = new AbortController();
  const relayStream = shouldRelayStream(options);
  const transport: RelayTransport = 'openai_chat_completions';
  const authMode = resolveRelayAuthMode(options, transport, deps.getRelayRuntimeConfig());
  const sensitiveCredentialValues = requestCredentialValues(apiKey, options, authMode);

  const buildRequest = (): RelayRequest => {
    const { body, reasoningEffort } = buildRelayChatCompletionsBody(modelID, messages, options);

    const upstreamURL = relayGenerationUpstreamURL(baseURL, modelID, transport, options);
    const { url, headers, endpointFingerprint } = buildScopedFetchArgs(
      deps,
      upstreamURL,
      buildDirectAuthHeaders(apiKey, authMode),
      buildRelayProxyConfig(apiKey, transport, authMode, options),
    );

    return {
      url, headers, body, modelID, endpointFingerprint, reasoningEffort,
      ...relayLearningScopeFields(transport, options),
    };
  };

  // The same citations event as direct openai-chat: send the accumulated full set whenever there is a new citation.
  const chatCitations: { citations: Citation[] } = { citations: [] };
  const stream = relayStream
    ? createRelaySSEStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        withRelayFunctionToolCalls('openai_chat', options, (_eventType, data): StreamEvent | StreamEvent[] | null => {
          const chunk = JSON.parse(data) as {
            choices?: Array<{
              delta?: {
                content?: string;
                images?: Array<{ image_url?: { url?: string } }>;
                annotations?: unknown;
              };
              message?: { annotations?: unknown };
            }>;
            usage?: {
              prompt_tokens?: number;
              completion_tokens?: number;
              total_tokens?: number;
            };
          };
          const errorFrame = relayTopLevelErrorFrame(chunk);
          if (errorFrame) return errorFrame;
          const events: StreamEvent[] = [];

          if (chunk.usage) {
            // Inject a UsageBreakdown so deriveCostFields takes the calcCost path; the estimateCost
            // fallback loses the cache/reasoning split (the OpenAI-compatible template covers most upstreams).
            events.push({
              type: 'usage',
              usage: {
                prompt_tokens: chunk.usage.prompt_tokens ?? 0,
                completion_tokens: chunk.usage.completion_tokens ?? 0,
                total_tokens: chunk.usage.total_tokens ?? 0,
                breakdown: parseUsageOpenAICompatible(chunk.usage as Record<string, unknown>),
              },
            });
          }
          const choice = chunk.choices?.[0];
          if (choice?.delta?.content) {
            events.push({ type: 'delta', content: choice.delta.content });
          }
          if (choice?.delta?.images) {
            for (const image of choice.delta.images) {
              if (image.image_url?.url) {
                events.push({ type: 'image', url: image.image_url.url });
              }
            }
          }
          // A url_citation missing start_index / end_index (such as new-api relaying from Claude) still counts as a citation.
          let citationChanged = emitAnnotationCitations(choice?.delta?.annotations, chatCitations, null);
          if (emitAnnotationCitations(choice?.message?.annotations, chatCitations, null)) citationChanged = true;
          if (citationChanged) {
            events.push({ type: 'citations', citations: chatCitations.citations.slice() });
          }

          return events.length > 0 ? events : null;
        }),
        controller.signal,
        sensitiveCredentialValues,
      )
    : createRelayJSONStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        parseOpenAIChatCompletionsResponse,
        controller.signal,
        sensitiveCredentialValues,
      );

  return { stream, abort: () => controller.abort() };
}

/**
 * The Relay Responses request body (pure logic). The streaming orchestration and an official family moving to a non-native protocol (dispatch)
 * share this one copy, so the body shapes of the two paths never diverge.
 */
export function buildRelayResponsesBody(
  modelID: string,
  messages: RelayMessages,
  options: StreamOptions | undefined,
  // Kept only for call-signature compatibility: the web search tool name is no longer resolved here.
  _runtimeConfig: RelayRuntimeConfig | null,
  hints?: RelayRetryHints,
): { body: Record<string, unknown>; reasoningEffort: ReturnType<typeof resolveOpenAIReasoningEffort> } {
  const body: Record<string, unknown> = {
    model: modelID,
    input: messages.map((message) => ({
      role: message.role,
      content: buildResponsesContent(message.role, message.content),
    })),
    stream: shouldRelayStream(options),
  };

  // The Codex transport always sends the image_generation tool and lets the model decide whether
  // to call it. image_generation and web_search_preview are not mutually exclusive; when both are
  // present the upstream decides the execution order.
  // The hints parameter exists only for the older call signature; the production wrapper never
  // emits a second removeTools leg.
  if (options?.relayFunctionTool) {
    // The test capability's tool item: tools holds only this one function tool, and built-in tools are not merged in.
    body.tools = functionToolsForProtocol('openai_responses', [options.relayFunctionTool]);
  } else if (!hints?.removeTools && !options?.relayOmitDefaultToolsAndReasoning) {
    const tools: Record<string, unknown>[] = [];
    const imageTool: Record<string, unknown> = { type: 'image_generation' };
    const toolModelID = options?.relayImageToolModelID?.trim();
    if (toolModelID) imageTool.model = toolModelID;
    tools.push(imageTool);
    // The web search tool is no longer added automatically from the chat web search preference: relay web search comes only from the connection-level fragment;
    // when an official family moves to this builder, official-protocol adds it itself.
    body.tools = tools;
  }
  const reasoningEffort = resolveOpenAIReasoningEffort(options);
  // summary is always requested:
  //  1. It is a precondition for the upstream emitting `response.reasoning_summary_text.delta`;
  //     without it relay users never see the reasoning trace at all.
  //  2. The 400 `Your organization must be verified to generate reasoning summaries` is OpenAI's
  //     verification policy for its own organizations. A relay request lands on the relay
  //     operator's account, often not OpenAI at all, so it usually does not apply - assuming the
  //     official provider's constraints is the top source of relay regressions.
  //  3. If a relay really does reject summary, the original preference is kept and the error is
  //     raised; the body is not scanned and the parameter is not silently stripped for a retry.
  // In automatic mode reasoningEffort is undefined, so only summary is sent and the model picks its own effort.
  // The probe carries no reasoning fields.
  if (!options?.relayOmitDefaultToolsAndReasoning) {
    body.reasoning = reasoningEffort
      ? { effort: reasoningEffort, summary: 'auto' }
      : { summary: 'auto' };
  }
  if (options?.relayServiceTier && options.relayServiceTier.trim()) {
    body.service_tier = options.relayServiceTier.trim();
  }
  if (options?.relayDisableResponseStorage) {
    body.store = false;
  }
  if (options?.relayMaxOutputTokens !== undefined) {
    body.max_output_tokens = options.relayMaxOutputTokens;
  }
  applyRelayGenerationParameters(body, options, 'openai_responses');
  return { body, reasoningEffort };
}

function sendOpenAIResponsesStream(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const controller = new AbortController();
  const relayStream = shouldRelayStream(options);
  const transport: RelayTransport = 'openai_responses';
  const authMode = resolveRelayAuthMode(options, transport, deps.getRelayRuntimeConfig());
  const sensitiveCredentialValues = requestCredentialValues(apiKey, options, authMode);

  // Several events can describe the same image (response.output_image.done /
  // image_generation_call.completed / output_item.done); dedupe by item id so each id lands once.
  const emittedImageIds = new Set<string>();
  const pendingPartialImages = new Map<string, string>();
  const responsesCitations: Citation[] = [];

  // Shared across the whole stream: once a retry has fired, a later frame must not fire it again.
  const retryDetector: RelayResponsesRetryDetector = { triggered: false };

  const buildRequest = (hints?: RelayRetryHints): RelayRequest => {
    const { body, reasoningEffort } = buildRelayResponsesBody(modelID, messages, options, deps.getRelayRuntimeConfig(), hints);
    // Not put inside buildRelayResponsesBody: an official family moving to Responses uses that builder too, and its request body does not carry this key.
    const proxyConfig = buildRelayProxyConfig(apiKey, transport, authMode, options);
    applyRelayPromptCacheKey(body, proxyConfig, messages);

    const upstreamURL = relayGenerationUpstreamURL(baseURL, modelID, transport, options);
    const { url, headers, endpointFingerprint } = buildScopedFetchArgs(
      deps,
      upstreamURL,
      buildDirectAuthHeaders(apiKey, authMode),
      proxyConfig,
    );

    return {
      url, headers, body, modelID, endpointFingerprint, reasoningEffort,
      ...relayLearningScopeFields(transport, options),
    };
  };
  const stream = relayStream
    ? createRelayResponsesStreamWithRetry(
        buildRequest,
        withRelayFunctionToolCalls('openai_responses', options, (eventType, data): StreamEvent | StreamEvent[] | null => {
          const chunk = JSON.parse(data) as Record<string, unknown>;
          const events: StreamEvent[] = [];

          if (eventType === 'response.output_text.delta' && typeof chunk.delta === 'string') {
            events.push({ type: 'delta', content: chunk.delta });
          }
          // Same shape as direct openai-responses: a url_citation in an annotation event produces an accumulated citations event.
          if (
            eventType === 'response.output_text.annotation.added' ||
            eventType === 'response.output_text.annotations.added'
          ) {
            const ann = chunk.annotation as Record<string, unknown> | undefined;
            if (ann && ann.type === 'url_citation') {
              const changed = mergeCitation(responsesCitations, {
                url: typeof ann.url === 'string' ? ann.url : '',
                title: typeof ann.title === 'string' ? ann.title : undefined,
                startIndex: typeof ann.start_index === 'number' ? ann.start_index : undefined,
                endIndex: typeof ann.end_index === 'number' ? ann.end_index : undefined,
              });
              if (changed) events.push({ type: 'citations', citations: responsesCitations.slice() });
            }
          }
          // Web search probe evidence exit: a completed web_search_call means the search ran, even with no citations.
          if (eventType === 'response.output_item.done') {
            const item = chunk.item as Record<string, unknown> | undefined;
            if (item?.type === 'web_search_call' && item.status === 'completed') {
              events.push({ type: 'citations', citations: responsesCitations.slice(), searchRan: true });
            }
          }
          if (
            eventType === 'response.image_generation_call.partial_image' &&
            typeof chunk.partial_image_b64 === 'string'
          ) {
            const itemId = typeof chunk.item_id === 'string' && chunk.item_id ? chunk.item_id : undefined;
            const dataUrl = toImageDataUrl(chunk.partial_image_b64);
            if (itemId) {
              pendingPartialImages.set(itemId, dataUrl);
            } else {
              events.push({ type: 'image', url: dataUrl });
            }
          }
          if (
            (eventType === 'response.output_image.done' || eventType === 'response.image_generation_call.completed')
          ) {
            const result = resolveResponsesImageResult(chunk);
            const itemId = asImageItemId(chunk);
            if (itemId) pendingPartialImages.delete(itemId);
            if (!result) {
              return events.length > 0 ? events : null;
            }
            if (!itemId || !emittedImageIds.has(itemId)) {
              if (itemId) emittedImageIds.add(itemId);
              events.push({ type: 'image', url: toImageDataUrl(result) });
            }
          }
          // response.output_item.done fallback: some relays emit images only through output_item.done.
          if (eventType === 'response.output_item.done') {
            const item = chunk.item as { id?: string; type?: string } | undefined;
            const result = resolveResponsesImageResult(chunk);
            if (item && item.type === 'image_generation_call' && result) {
              const itemId = item.id ?? asImageItemId(chunk);
              if (itemId) pendingPartialImages.delete(itemId);
              if (!itemId || !emittedImageIds.has(itemId)) {
                if (itemId) emittedImageIds.add(itemId);
                events.push({ type: 'image', url: toImageDataUrl(result) });
              }
            }
          }

          // Must be unknown rather than number: in the Responses usage object `input_tokens_details` /
          // `output_tokens_details` are nested objects, and Record<string, number> cannot express that
          // in the type system - which is exactly why the cache breakdown kept being dropped.
          const usage = (chunk.usage ?? (chunk.response as { usage?: Record<string, unknown> } | undefined)?.usage) as
            | Record<string, unknown>
            | undefined;
          if (eventType === 'response.completed') {
            for (const [itemId, url] of pendingPartialImages.entries()) {
              if (!emittedImageIds.has(itemId)) {
                emittedImageIds.add(itemId);
                events.push({ type: 'image', url });
              }
            }
            pendingPartialImages.clear();
            if (usage) {
              // A relay's responses envelope has the same shape as the official one: the breakdown
              // lives in input_tokens_details / output_tokens_details. Treating input_tokens as
              // promptTokens throws away the cached_tokens the upstream did report.
              const inputTokens = typeof usage.input_tokens === 'number' ? usage.input_tokens : 0;
              const outputTokens = typeof usage.output_tokens === 'number' ? usage.output_tokens : 0;
              events.push({
                type: 'usage',
                usage: {
                  prompt_tokens: inputTokens,
                  completion_tokens: outputTokens,
                  total_tokens: inputTokens + outputTokens,
                  breakdown: parseUsageOpenAIResponses(usage),
                },
              });
            }
          }
          // In-stream Responses API errors: HTTP 200, but the run failed.
          // - `event: error` -> moderation_blocked / image_generation_user_error / other
          // - `event: response.failed` -> response.error
          // Ignoring these leaves the user with an empty message, so map the code to a friendly
          // message that names an actionable next step.
          if (eventType === 'response.failed' || eventType === 'error') {
            const envelope = chunk as {
              error?: { code?: string; message?: string; param?: string } | string;
              response?: { error?: { code?: string; message?: string; param?: string } };
            };
            const upstreamError =
              (typeof envelope.error === 'object' ? envelope.error : undefined)
              ?? envelope.response?.error;
            const code = upstreamError?.code;
            const message = typeof envelope.error === 'string'
              ? envelope.error
              : upstreamError?.message;
            const mapped = mapRelayStreamError(code, message);
            // Only JSON fields (error.type / code / status) are read; the allowlist is applied on the telemetry side.
            const upstreamErrorType = upstreamError
              ? upstreamErrorTypeValue(upstreamError as Record<string, unknown>)
              : undefined;
            events.push({
              type: 'error',
              error: redactRelayCredentials(mapped.message, sensitiveCredentialValues),
              errorKind: mapped.errorKind,
              source: 'provider',
              ...(mapped.i18nKey ? { i18nKey: mapped.i18nKey } : {}),
              streamErrorFrame: true,
              ...(upstreamErrorType ? { upstreamErrorType } : {}),
            });
          }

          return events.length > 0 ? events : null;
        }),
        retryDetector,
        controller.signal,
        deps.transport,
        deps.onUnsupportedParamDropped,
        sensitiveCredentialValues,
      )
    : createRelayJSONStream(
        (signal) => fetchRelayWithFallbacks(buildRequest, undefined, signal, deps.transport, deps.onUnsupportedParamDropped),
        parseResponsesResponse,
        controller.signal,
        sensitiveCredentialValues,
      );

  return { stream, abort: () => controller.abort() };
}

/** The Relay Anthropic Messages request body (pure logic; shared by the streaming orchestration and an official family on a non-native protocol). */
export function buildRelayAnthropicMessagesBody(
  modelID: string,
  messages: RelayMessages,
  options: StreamOptions | undefined,
): Record<string, unknown> {
  // Join every system message into the top-level system with a blank line; never keep only the last one.
  const systemTexts: string[] = [];

  const apiMessages = messages
    .filter((message) => {
      if (message.role === 'system') {
        const text = typeof message.content === 'string' ? message.content : extractText(message.content);
        if (text) systemTexts.push(text);
        return false;
      }
      return true;
    })
    .map((message) => ({
      role: message.role as 'user' | 'assistant',
      content: typeof message.content === 'string'
        ? [{ type: 'text', text: message.content }]
        : convertToAnthropicParts(message.content),
    }));

  // Anthropic allows at most 4 cache breakpoints: [D] is split into a standalone last block, and the single breakpoint goes on the last non-[D] block of the last user message.
  markAnthropicCacheBreakpoint(apiMessages, options?.dynamicText);

  const chatOutputLimit = chatMaxOutputTokens(options?.maxOutputTokens);
  const body: Record<string, unknown> = {
    model: modelID,
    // The main chat path uses the wire limit; other paths keep the 8192 default as a Relay-specific exception / heuristic-allow fallback (the official Anthropic path resolves this from metadata).
    max_tokens: options?.relayMaxOutputTokens ?? chatOutputLimit ?? ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS,
    stream: shouldRelayStream(options),
    messages: apiMessages,
  };
  if (systemTexts.length > 0) body.system = systemTexts.join('\n\n');
  const thinking = resolveRelayAnthropicThinking(options?.reasoning, chatOutputLimit);
  if (thinking) {
    body.thinking = { type: 'enabled', budget_tokens: thinking.budgetTokens };
    body.max_tokens = thinking.maxTokens;
  }
  if (options?.relayFunctionTool) {
    body.tools = functionToolsForProtocol('anthropic_messages', [options.relayFunctionTool]);
  }
  applyRelayGenerationParameters(body, options, 'anthropic_messages');
  return body;
}

function sendAnthropicMessagesStream(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const controller = new AbortController();
  const relayStream = shouldRelayStream(options);
  const body = buildRelayAnthropicMessagesBody(modelID, messages, options);
  const transport: RelayTransport = 'anthropic_messages';

  const authMode = resolveRelayAuthMode(options, transport, deps.getRelayRuntimeConfig());
  const sensitiveCredentialValues = requestCredentialValues(apiKey, options, authMode);
  const directHeaders: Record<string, string> = {
    ...buildDirectAuthHeaders(apiKey, authMode),
    ...buildRelayProtocolHeaders(transport),
  };

  let inputTokens = 0;
  // Cache the full usage object from message_start (including cache_read_input_tokens /
  // cache_creation) so that, once output_tokens from message_delta is merged in, parseUsageAnthropic
  // can rebuild the complete breakdown. Reading only input_tokens dropped every cache field.
  let messageStartUsage: Record<string, unknown> | undefined;
  const messagesCitations: { citations: Citation[] } = { citations: [] };
  const buildRequest = (): RelayRequest => {
    const upstreamURL = relayGenerationUpstreamURL(baseURL, modelID, transport, options);
    const { url, headers: resolvedHeaders, endpointFingerprint } = buildScopedFetchArgs(
      deps,
      upstreamURL,
      directHeaders,
      buildRelayProxyConfig(apiKey, transport, authMode, options),
    );
    return {
      url, headers: resolvedHeaders, body, modelID, endpointFingerprint,
      ...relayLearningScopeFields(transport, options),
    };
  };

  const parseStreamChunk = (eventType: string | null, data: string): StreamEvent | null => {
      const chunk = JSON.parse(data) as Record<string, unknown>;
      switch (eventType ?? chunk.type) {
        case 'message_start': {
          const usage = (chunk.message as { usage?: Record<string, unknown> } | undefined)?.usage;
          if (usage && typeof usage === 'object') {
            messageStartUsage = usage;
            const input = usage.input_tokens;
            inputTokens = typeof input === 'number' ? input : 0;
          }
          return null;
        }
        case 'content_block_start': {
          // The same path as direct anthropic-messages: the result entries of a web_search_tool_result are the citations;
          // a web_search_tool_result_error (content not an array) produces no citation.
          const block = chunk.content_block as Record<string, unknown> | undefined;
          if (!block) return null;
          const changed = handleAnthropicCitationBlock(block, messagesCitations, null);
          // Web search probe evidence exit: a result that is an array (an empty array counts) = the search ran.
          const searchRan = block.type === 'web_search_tool_result' && Array.isArray(block.content);
          if (changed || searchRan) {
            return {
              type: 'citations',
              citations: messagesCitations.citations.slice(),
              ...(searchRan ? { searchRan: true as const } : {}),
            };
          }
          return null;
        }
        case 'content_block_delta': {
          const delta = chunk.delta as { type?: string; text?: string; thinking?: string } | undefined;
          if (delta?.type === 'text_delta' && delta.text) {
            return { type: 'delta', content: delta.text };
          }
          // Aligned with the official parser (proxy-chunk-parser / anthropic-messages strategy): thinking is already enabled on the request,
          // and thinking_delta is emitted as reasoning; signature_delta likewise produces no UI event on the official streaming path.
          if (delta?.type === 'thinking_delta' && typeof delta.thinking === 'string' && delta.thinking) {
            return { type: 'reasoning', content: delta.thinking };
          }
          return null;
        }
        case 'message_delta': {
          // message_delta can carry new cache_read / cache_creation 5m/1h values, especially for
          // reasoning models across multi-turn prompt caching, so merge them into the closure state
          // instead of reading only output_tokens.
          const deltaUsage = chunk.usage as Record<string, unknown> | undefined;
          if (deltaUsage && typeof deltaUsage === 'object') {
            const mergedUsage: Record<string, unknown> = { ...messageStartUsage };
            for (const [k, v] of Object.entries(deltaUsage)) {
              if (v !== undefined && v !== null) mergedUsage[k] = v;
            }
            messageStartUsage = mergedUsage;
          }
          // When both message_start.usage and the delta usage are missing, upstream reported no usage: no usage event is
          // sent, so downstream records unknown instead of an estimated 0.
          if (!messageStartUsage) return null;
          const outputTokens = typeof deltaUsage?.output_tokens === 'number'
            ? deltaUsage.output_tokens
            : 0;
          const breakdown = parseUsageAnthropic({
            ...messageStartUsage,
            output_tokens: outputTokens,
          });
          // The totalPrompt formula used for display, which includes the cache portion.
          const totalPromptTokens =
            breakdown.promptTokens
            + breakdown.cachedInputTokens
            + breakdown.cacheCreation5mTokens
            + breakdown.cacheCreation1hTokens;
          return {
            type: 'usage',
            usage: {
              prompt_tokens: totalPromptTokens,
              completion_tokens: outputTokens,
              breakdown,
              total_tokens: totalPromptTokens + outputTokens,
            },
          };
        }
        default:
          return null;
      }
    };

  const stream = relayStream
    ? createRelaySSEStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        withRelayFunctionToolCalls('anthropic_messages', options, parseStreamChunk),
        controller.signal,
        sensitiveCredentialValues,
      )
    : createRelayJSONStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        parseAnthropicResponse,
        controller.signal,
        sensitiveCredentialValues,
      );

  return { stream, abort: () => controller.abort() };
}

/** The Relay Gemini generateContent request body (pure logic; shared by the streaming orchestration and an official family on a non-native protocol). */
export function buildRelayGeminiGenerateContentBody(
  messages: RelayMessages,
  options: StreamOptions | undefined,
): Record<string, unknown> {
  const systemTexts = messages
    .filter((message) => message.role === 'system')
    .map((message) => typeof message.content === 'string' ? message.content : extractText(message.content))
    .filter(Boolean);

  const body: Record<string, unknown> = {
    contents: messages
      .filter((message) => message.role !== 'system')
      .map((message) => ({
        role: message.role === 'assistant' ? 'model' : 'user',
        parts: typeof message.content === 'string'
          ? [{ text: message.content }]
          : convertToGeminiParts(message.content),
      })),
  };
  if (systemTexts.length > 0) {
    body.systemInstruction = { parts: [{ text: systemTexts.join('\n\n') }] };
  }

  const generationConfig: Record<string, unknown> = {};
  if (options?.reasoning && options.reasoning !== 'automatic') {
    generationConfig.thinkingConfig = { thinkingBudget: mapGeminiReasoningBudget(options.reasoning) };
  }
  if (options?.supportsImageGen) {
    // Relay-specific exception / heuristic-allow: for the official Gemini provider this is injected by the imageGen profile mergeParams.
    generationConfig.responseModalities = ['TEXT', 'IMAGE'];
  }
  if (options?.relayMaxOutputTokens !== undefined) {
    generationConfig.maxOutputTokens = options.relayMaxOutputTokens;
  }
  if (Object.keys(generationConfig).length > 0) {
    body.generationConfig = generationConfig;
  }
  applyRelayGenerationParameters(body, options, 'gemini_generate_content');

  if (options?.relayFunctionTool) {
    // The test capability's tool item: tools holds only this one function tool.
    body.tools = functionToolsForProtocol('gemini_generate', [options.relayFunctionTool]);
  }
  // googleSearch is no longer added automatically from the chat web search preference: relay web search comes only from the connection-level fragment.
  return body;
}

function sendGeminiGenerateContentStream(
  apiKey: string,
  modelID: string,
  messages: RelayMessages,
  baseURL: string,
  options: StreamOptions | undefined,
  deps: RelayOrchestratorDeps,
): StreamHandle {
  const controller = new AbortController();
  const relayStream = shouldRelayStream(options);
  const body = buildRelayGeminiGenerateContentBody(messages, options);

  const transport: RelayTransport = 'gemini_generate_content';
  const authMode = resolveRelayAuthMode(options, transport, deps.getRelayRuntimeConfig());
  const sensitiveCredentialValues = requestCredentialValues(apiKey, options, authMode);
  const requestURL = relayGenerationUpstreamURL(baseURL, modelID, transport, options);

  const buildRequest = (): RelayRequest => {
    const { url, headers, endpointFingerprint } = buildScopedFetchArgs(
      deps,
      requestURL,
      buildDirectAuthHeaders(apiKey, authMode),
      buildRelayProxyConfig(apiKey, transport, authMode, options),
    );
    return { url, headers, body, modelID, endpointFingerprint, ...relayLearningScopeFields(transport, options) };
  };

  const geminiCitations: Citation[] = [];
  const parseGeminiChunk = (_eventType: string | null, data: string): StreamEvent | StreamEvent[] | null => {
      const chunk = JSON.parse(data) as {
        error?: string | { message?: string };
        candidates?: Array<{ content?: { parts?: Array<{ text?: string; inlineData?: { mimeType: string; data: string } }> } }>;
        usageMetadata?: {
          promptTokenCount?: number;
          candidatesTokenCount?: number;
          totalTokenCount?: number;
        };
      };
      const events: StreamEvent[] = [];

      if (chunk.error) {
        const message = typeof chunk.error === 'string'
          ? chunk.error
          : chunk.error.message || 'Gemini stream error';
        const upstreamErrorType = typeof chunk.error === 'object' && chunk.error
          ? upstreamErrorTypeValue(chunk.error as Record<string, unknown>)
          : undefined;
        return [{
          type: 'error', error: message, errorKind: 'upstream', source: 'provider', streamErrorFrame: true,
          ...(upstreamErrorType ? { upstreamErrorType } : {}),
        }];
      }
      const blocked = detectGeminiBlockEvent(chunk as Record<string, unknown>);
      if (blocked) return [blocked];

      for (const part of chunk.candidates?.[0]?.content?.parts ?? []) {
        if (part.text) {
          events.push({ type: 'delta', content: part.text });
        }
        if (part.inlineData) {
          events.push({
            type: 'image',
            url: `data:${part.inlineData.mimeType};base64,${part.inlineData.data}`,
          });
        }
      }
      if (chunk.usageMetadata) {
        events.push({
          type: 'usage',
          usage: {
            prompt_tokens: chunk.usageMetadata.promptTokenCount || 0,
            completion_tokens: chunk.usageMetadata.candidatesTokenCount || 0,
            total_tokens: chunk.usageMetadata.totalTokenCount || 0,
            // Includes the thoughtsTokenCount / cachedContentTokenCount split.
            breakdown: parseUsageGemini(chunk.usageMetadata as Record<string, unknown>),
          },
        });
      }
      // The same default path as direct gemini-generate: groundingMetadata.groundingChunks[].web.uri.
      const groundingChunks = readPath(chunk, GEMINI_CITATIONS_PATH);
      if (Array.isArray(groundingChunks)) {
        let citationChanged = false;
        for (const raw of groundingChunks) {
          const c = citationFromRaw(raw, null, {
            urlField: GEMINI_CITATION_URL_FIELD,
            titleField: GEMINI_CITATION_TITLE_FIELD,
            snippetField: 'snippet',
          });
          if (mergeCitation(geminiCitations, c)) citationChanged = true;
        }
        if (citationChanged) events.push({ type: 'citations', citations: geminiCitations.slice() });
      }
      // Web search probe evidence exit: a non-empty groundingMetadata.webSearchQueries = the search ran (groundingChunks may be absent).
      const searchQueries = (chunk.candidates?.[0] as { groundingMetadata?: { webSearchQueries?: unknown } } | undefined)
        ?.groundingMetadata?.webSearchQueries;
      if (Array.isArray(searchQueries) && searchQueries.length > 0) {
        events.push({ type: 'citations', citations: geminiCitations.slice(), searchRan: true });
      }

      return events.length > 0 ? events : null;
    };

  const stream = relayStream
    ? createRelaySSEStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        withRelayFunctionToolCalls('gemini_generate_content', options, parseGeminiChunk),
        controller.signal,
        sensitiveCredentialValues,
      )
    : createRelayJSONStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        parseGeminiResponse,
        controller.signal,
        sensitiveCredentialValues,
      );

  return { stream, abort: () => controller.abort() };
}
