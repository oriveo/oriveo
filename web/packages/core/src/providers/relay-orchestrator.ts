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
import { mapRelayStreamError } from '@oriveo/shared/relay/error-mapping';
import { redactRelayCredentials } from '@oriveo/shared/relay/endpoint-policy';
import type { ContentPart, StreamEvent, StreamHandle, StreamOptions } from './types';
import type { RelayRuntimeConfig, UpstreamTransport } from '../ports';
import { buildRelayEndpointURL } from './relay-endpoints';
import { detectGeminiBlockEvent } from './transport/strategies/gemini-generate';
import {
  relayImageRoute,
  relaySensitiveCredentialValues,
  resolveRelayAuthMode,
  resolveRelayTransportRule,
} from './relay-runtime-support';
import {
  parseUsageAnthropic,
  parseUsageGemini,
  parseUsageOpenAICompatible,
  parseUsageOpenAIResponses,
} from './transport/usage-parsers';
import {
  asImageItemId,
  buildDirectAuthHeaders,
  buildRelayProtocolHeaders,
  buildImagesGenerationsBody,
  buildRelayProxyConfig,
  buildResponsesContent,
  convertToAnthropicParts,
  convertToGeminiParts,
  convertToOpenAIChatParts,
  extractImagePrompt,
  extractText,
  mapAnthropicReasoningBudget,
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
import { applyGenerationParameters } from './request-builders/generation-parameters';
import { compileSafeCustomFragment } from './request-builders/safe-custom-fragment';
import { safeCustomOwners } from './request-builders/dispatch';
import {
  createRelayJSONStream,
  createRelayResponsesStreamWithRetry,
  createRelaySSEStream,
  fetchRelayRequest,
  fetchRelayWithFallbacks,
  fetchRelayWithXHighRetry,
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

type RelayMessages = { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[];

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
function applyRelayGenerationParameters(body: Record<string, unknown>, options: StreamOptions | undefined): void {
  applyGenerationParameters(body, options?.generationParameters, options?.generationProfile);
  applyRelaySafeCustomFragments(body, options);
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
      throw new Error('Safe custom fragment rejected: unknown_owned_path');
    }
    const custom = compileSafeCustomFragment(declared.raw.trim(), owner, declaredOwners, body);
    if (!custom.accepted) throw new Error(`Safe custom fragment rejected: ${custom.reason}`);
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

function requestCredentialValues(
  apiKey: string,
  options: StreamOptions | undefined,
  authMode: ReturnType<typeof resolveRelayAuthMode>,
): string[] {
  // The none mode never writes apiKey, custom headers or query into the actual request, so it must not over-redact ordinary body fields that happen to share those names.
  if (authMode === 'none') return [];
  return relaySensitiveCredentialValues({
    apiKey,
    headers: options?.relayHeaders,
    queryParams: options?.relayQueryParams,
  });
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
  const prompt = messages.map((message) => {
    const text = typeof message.content === 'string' ? message.content : extractText(message.content);
    return `${message.role}: ${text}`;
  }).join('\n');
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
    const chunk = JSON.parse(data) as { content?: string; completion?: string; stop?: boolean };
    if (chunk.content ?? chunk.completion) return { type: 'delta', content: chunk.content ?? chunk.completion ?? '' };
    return chunk.stop ? { type: 'done' } : null;
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
          const response = payload as { content?: string; completion?: string };
          return [{ type: 'delta', content: response.content ?? response.completion ?? '' }, { type: 'done' }];
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
  const prompt = extractImagePrompt(messages);

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

  const apiMessages = messages.map((message) => ({
    role: message.role,
    content: typeof message.content === 'string'
      ? message.content
      : convertToOpenAIChatParts(message.content),
  }));

  const buildRequest = (reasoningEffortOverride?: 'high'): RelayRequest => {
    const body: Record<string, unknown> = {
      model: modelID,
      stream: relayStream,
      messages: apiMessages,
    };
    if (options?.relayMaxOutputTokens !== undefined) {
      body.max_tokens = options.relayMaxOutputTokens;
    }
    if (relayStream) {
      body.stream_options = { include_usage: true };
    }

    const reasoningEffort = resolveOpenAIReasoningEffort(options, reasoningEffortOverride);
    if (reasoningEffort) {
      body.reasoning_effort = reasoningEffort;
    }
    applyRelayGenerationParameters(body, options);

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

  const stream = relayStream
    ? createRelaySSEStream(
        (signal) => fetchRelayWithXHighRetry(buildRequest, signal, deps.transport, deps.onUnsupportedParamDropped),
        (_eventType, data): StreamEvent | StreamEvent[] | null => {
          const chunk = JSON.parse(data) as {
            choices?: Array<{
              delta?: {
                content?: string;
                images?: Array<{ image_url?: { url?: string } }>;
              };
            }>;
            usage?: {
              prompt_tokens?: number;
              completion_tokens?: number;
              total_tokens?: number;
            };
          };
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

          return events.length > 0 ? events : null;
        },
        controller.signal,
        sensitiveCredentialValues,
      )
    : createRelayJSONStream(
        (signal) => fetchRelayWithXHighRetry(buildRequest, signal, deps.transport, deps.onUnsupportedParamDropped),
        parseOpenAIChatCompletionsResponse,
        controller.signal,
        sensitiveCredentialValues,
      );

  return { stream, abort: () => controller.abort() };
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

  // Shared across the whole stream: once a retry has fired, a later frame must not fire it again.
  const retryDetector: RelayResponsesRetryDetector = { triggered: false };

  const buildRequest = (hints?: RelayRetryHints): RelayRequest => {
    const body: Record<string, unknown> = {
      model: modelID,
      input: messages.map((message) => ({
        role: message.role,
        content: buildResponsesContent(message.role, message.content),
      })),
      stream: relayStream,
    };

    // The Codex transport always sends the image_generation tool and lets the model decide whether
    // to call it. image_generation and web_search_preview are not mutually exclusive; when both are
    // present the upstream decides the execution order.
    // The hints parameter exists only for the older call signature; the production wrapper never
    // emits a second removeTools leg.
    if (!hints?.removeTools) {
      const tools: Record<string, unknown>[] = [];
      const imageTool: Record<string, unknown> = { type: 'image_generation' };
      const toolModelID = options?.relayImageToolModelID?.trim();
      if (toolModelID) imageTool.model = toolModelID;
      tools.push(imageTool);
      if (options?.supportsWebSearch) {
        // Default to 'web_search' (recommended by OpenAI and used by most relays); custom mode can
        // fall back to the legacy 'web_search_preview', and 'disabled' omits the tool entirely.
        const runtimeConfig = deps.getRelayRuntimeConfig();
        const webSearchToolName = options?.relayWebSearchToolName
          ?? (runtimeConfig
            ? resolveRelayTransportRule('openai_responses', runtimeConfig)?.webSearchToolName
            : undefined)
          ?? 'web_search';
        if (webSearchToolName !== 'disabled') {
          tools.push({ type: webSearchToolName });
        }
      }
      body.tools = tools;
    }
    const reasoningEffort = resolveOpenAIReasoningEffort(options, hints?.reasoningEffortOverride);
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
    body.reasoning = reasoningEffort
      ? { effort: reasoningEffort, summary: 'auto' }
      : { summary: 'auto' };
    if (options?.relayServiceTier && options.relayServiceTier.trim()) {
      body.service_tier = options.relayServiceTier.trim();
    }
    if (options?.relayDisableResponseStorage) {
      body.store = false;
    }
    applyRelayGenerationParameters(body, options);

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

  const stream = relayStream
    ? createRelayResponsesStreamWithRetry(
        buildRequest,
        (eventType, data): StreamEvent | StreamEvent[] | null => {
          const chunk = JSON.parse(data) as Record<string, unknown>;
          const events: StreamEvent[] = [];

          if (eventType === 'response.output_text.delta' && typeof chunk.delta === 'string') {
            events.push({ type: 'delta', content: chunk.delta });
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
            events.push({
              type: 'error',
              error: redactRelayCredentials(mapped.message, sensitiveCredentialValues),
              errorKind: mapped.errorKind,
              source: 'provider',
              ...(mapped.i18nKey ? { i18nKey: mapped.i18nKey } : {}),
            });
          }

          return events.length > 0 ? events : null;
        },
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
  let systemText: string | undefined;

  const apiMessages = messages
    .filter((message) => {
      if (message.role === 'system') {
        systemText = typeof message.content === 'string' ? message.content : extractText(message.content);
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

  const body: Record<string, unknown> = {
    model: modelID,
    // Relay-specific exception / heuristic-allow fallback only: the official Anthropic path resolves this from metadata instead.
    max_tokens: 8192,
    stream: relayStream,
    messages: apiMessages,
  };
  if (systemText) body.system = systemText;
  if (options?.reasoning && options.reasoning !== 'automatic') {
    const budget = mapAnthropicReasoningBudget(options.reasoning);
    body.thinking = { type: 'enabled', budget_tokens: budget };
    body.max_tokens = Math.max(8192, budget + 4096);
  }
  applyRelayGenerationParameters(body, options);

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
  let messageStartUsage: Record<string, unknown> = {};
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
        case 'content_block_delta': {
          const delta = chunk.delta as { type?: string; text?: string } | undefined;
          if (delta?.type === 'text_delta' && delta.text) {
            return { type: 'delta', content: delta.text };
          }
          return null;
        }
        case 'message_delta': {
          // message_delta can carry new cache_read / cache_creation 5m/1h values, especially for
          // reasoning models across multi-turn prompt caching, so merge them into the closure state
          // instead of reading only output_tokens.
          const deltaUsage = chunk.usage as Record<string, unknown> | undefined;
          if (deltaUsage && typeof deltaUsage === 'object') {
            for (const [k, v] of Object.entries(deltaUsage)) {
              if (v !== undefined && v !== null) messageStartUsage[k] = v;
            }
          }
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
        parseStreamChunk,
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
  if (Object.keys(generationConfig).length > 0) {
    body.generationConfig = generationConfig;
  }
  applyRelayGenerationParameters(body, options);

  // The web search tool for the Gemini transport is googleSearch.
  if (options?.supportsWebSearch) {
    body.tools = [{ googleSearch: {} }];
  }

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
        return [{ type: 'error', error: message, errorKind: 'upstream', source: 'provider' }];
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

      return events.length > 0 ? events : null;
    };

  const stream = relayStream
    ? createRelaySSEStream(
        (signal) => fetchRelayRequest(buildRequest(), signal, deps.transport, deps.onUnsupportedParamDropped),
        parseGeminiChunk,
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
