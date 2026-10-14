/**
 * Pure computation layer for relay, meaning user-supplied custom endpoints.
 *
 * Pure functions only: body construction for the 4 transports, response parsing, reasoning
 * mapping and direct auth headers. The fetch chain, buildRelayFetchArgs, the applyDirect*
 * helpers that need crypto.randomUUID, resolveRelayAuthMode and the four send* entry points
 * live in apps/app because they do IO or go through the browser proxy.
 * The web and desktop main builds share this one copy; it must not be forked.
 */

import type { ContentPart, StreamEvent, StreamOptions } from './types';
import { sha256Hex } from '../mcp/mcp-pure';
import { codexIdentityUserAgent, relayInjectsCodexIdentity } from './relay-codex-identity';

export { relayInjectsCodexIdentity };
import { requireSecureRelayEndpoint, type RelayConnectionSecurityMode } from '@oriveo/shared/relay/endpoint-policy';
import { isDedicatedImageModel } from '@oriveo/shared/relay/image-models';
import {
  parseUsageAnthropic,
  parseUsageGemini,
  parseUsageOpenAICompatible,
  parseUsageOpenAIResponses,
} from './transport/usage-parsers';

type RelayAuthMode = NonNullable<StreamOptions['relayAuthMode']>;

/* ── baseURL / stream helpers ───────────────────────────── */

/**
 * The message thrown here surfaces on the chat error card, so it has to be human readable
 * (`RELAY_HTTPS_REQUIRED_MESSAGE`) rather than an internal reason enum such as
 * `cleartext_not_allowed`: nothing under apps/ or packages/ maps those reasons back to copy,
 * so throwing one would render a machine string at the user.
 * `requireSecureRelayEndpoint` and `classifyRelayEndpoint` share the same decision chain
 * (classify -> normalizeSecure -> requireSecure) and securityMode is still passed through, so
 * the allow/reject semantics are unchanged and only the message is human readable.
 */
export function normalizeBaseURL(
  baseURL?: string,
  securityMode: RelayConnectionSecurityMode = 'remote_https',
): string {
  return requireSecureRelayEndpoint(baseURL ?? '', securityMode).replace(/\/$/, '');
}

export function shouldRelayStream(options?: StreamOptions): boolean {
  return options?.relayStream !== false;
}

export function buildDirectAuthHeaders(
  apiKey: string,
  authMode: RelayAuthMode,
): Record<string, string> {
  switch (authMode) {
    case 'none':
      return {};
    case 'x_api_key':
      return { 'x-api-key': apiKey };
    case 'x_goog_api_key':
      return { 'x-goog-api-key': apiKey };
    case 'query_key':
      return {};
    case 'bearer':
    default:
      return { Authorization: `Bearer ${apiKey}` };
  }
}

/**
 * Protocol headers a relay transport requires. The verification request and the real chat request
 * must share them, so verification cannot pass while chat goes out missing a header.
 */
export function buildRelayProtocolHeaders(
  transport: NonNullable<StreamOptions['relayTransport']>,
): Record<string, string> {
  if (transport !== 'anthropic_messages') return {};
  return {
    'anthropic-version': '2023-06-01',
    'anthropic-dangerous-direct-browser-access': 'true',
  };
}

/* ── Direct fetch arguments (desktop main, Node SSR, tests: no browser proxy) ─────────── */

/** Direct-connection config, matching the third argument of buildRelayFetchArgs in apps/app. */
export interface RelayDirectFetchConfig {
  apiKey: string;
  transport: NonNullable<StreamOptions['relayTransport']>;
  authMode: RelayAuthMode;
  method?: 'POST' | 'GET';
  codexCompatIdentity?: boolean;
  /** Codex client version delivered by the server (the shell fills it from the runtime config); always pass it through resolveCodexClientVersion before use. */
  codexClientVersion?: string;
  customUserAgent?: string;
  headers?: StreamOptions['relayHeaders'];
  queryParams?: StreamOptions['relayQueryParams'];
  securityMode?: StreamOptions['relaySecurityMode'];
}

/** Direct: append query_key as ?key= plus any custom query params, for URLs that skip the browser proxy. */
export function applyDirectQueryParams(upstreamURL: string, config: RelayDirectFetchConfig): string {
  const url = new URL(upstreamURL);
  if (config.authMode === 'query_key' && config.apiKey && !url.searchParams.has('key')) {
    url.searchParams.set('key', config.apiKey);
  }
  for (const pair of config.authMode === 'none' ? [] : config.queryParams ?? []) {
    const key = pair.key.trim();
    if (!key) continue;
    url.searchParams.set(key, pair.value);
  }
  return url.toString();
}

/** Direct: codex identity headers (session_id from the injected randomUUID, since core must not use global crypto) plus custom UA and headers. */
/**
 * The Responses `prompt_cache_key` (byte-for-byte identical on all three clients):
 * the first 32 lowercase hex characters of SHA-256(UTF-8(model + "\n" + instructions + "\n" + firstUserText)).
 * It uses only the model, the system prompt and the first user text, so the value is the same on every turn of one conversation.
 */
export function relayPromptCacheKey(model: string, instructions: string, firstUserText: string): string {
  return sha256Hex(`${model}\n${instructions}\n${firstUserText}`).slice(0, 32);
}

function relayMessagePlainText(content: string | ContentPart[]): string {
  if (typeof content === 'string') return content;
  let text = '';
  for (const part of content) {
    if (part.type === 'text') text += part.text;
  }
  return text;
}

/**
 * Add `prompt_cache_key` to a Responses body that carries the Codex identity: some relays treat a request
 * without this key as a non-Codex client and return 403 outright. Nothing is added when the identity headers are not
 * injected; a key already in the body (written by the user) is not overwritten.
 * instructions comes from the body's `instructions`, or else from the first system message (on Web the system prompt lives in input).
 */
export function applyRelayPromptCacheKey(
  body: Record<string, unknown>,
  config: Pick<RelayDirectFetchConfig, 'transport' | 'authMode' | 'codexCompatIdentity'>,
  messages: readonly { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
): void {
  if (!relayInjectsCodexIdentity(config)) return;
  if (Object.prototype.hasOwnProperty.call(body, 'prompt_cache_key')) return;
  const model = typeof body.model === 'string' ? body.model : '';
  const system = messages.find((message) => message.role === 'system');
  const instructions = typeof body.instructions === 'string' && body.instructions
    ? body.instructions
    : system ? relayMessagePlainText(system.content) : '';
  const firstUser = messages.find((message) => message.role === 'user');
  body.prompt_cache_key = relayPromptCacheKey(
    model,
    instructions,
    firstUser ? relayMessagePlainText(firstUser.content) : '',
  );
}

export function applyDirectCustomHeaders(
  baseHeaders: Record<string, string>,
  config: RelayDirectFetchConfig,
  randomUUID: () => string,
): Record<string, string> {
  const headers = { ...baseHeaders };
  if (config.authMode === 'none') return headers;
  if (relayInjectsCodexIdentity(config)) {
    headers['User-Agent'] = codexIdentityUserAgent(config.codexClientVersion);
    headers.Originator = 'codex_cli_rs';
    headers.session_id = randomUUID();
    headers['OpenAI-Beta'] = 'responses=experimental';
  }
  if (config.customUserAgent?.trim()) {
    headers['User-Agent'] = config.customUserAgent.trim();
  }
  for (const pair of config.headers ?? []) {
    const key = pair.key.trim();
    if (!key) continue;
    headers[key] = pair.value;
  }
  return headers;
}

/** Relay proxy config shared by the browser-proxy and direct paths: codex identity, UA, custom headers and query, all read from options. */
export function buildRelayProxyConfig(
  apiKey: string,
  transport: NonNullable<StreamOptions['relayTransport']>,
  authMode: RelayAuthMode,
  options?: StreamOptions,
): RelayDirectFetchConfig {
  return {
    apiKey,
    transport,
    authMode,
    method: 'POST',
    codexCompatIdentity: options?.relayCodexCompatIdentity,
    customUserAgent: options?.relayCustomUserAgent,
    headers: options?.relayHeaders,
    queryParams: options?.relayQueryParams,
    securityMode: options?.relaySecurityMode,
  };
}

/* ── Message body construction (4 transports) ───────────────────── */

export function convertToOpenAIChatParts(parts: ContentPart[]) {
  return parts.map((part) => {
    if (part.type === 'text') return part;
    if (part.type === 'image_url') return part;
    if (part.type === 'video_url') return part;
    // PDF is sent as an image_url data URI, which models such as GPT-4o accept.
    return { type: 'image_url' as const, image_url: { url: part.file.file_data } };
  });
}

export function convertToResponsesParts(parts: ContentPart[]) {
  return parts.map((part) => {
    if (part.type === 'text') {
      return { type: 'input_text' as const, text: part.text };
    }
    if (part.type === 'image_url') {
      return { type: 'input_image' as const, image_url: part.image_url.url };
    }
    if (part.type === 'video_url') {
      return { type: 'input_video' as const, video_url: part.video_url.url };
    }
    return { type: 'input_file' as const, file_data: part.file.file_data, filename: part.file.filename };
  });
}

/**
 * The OpenAI Responses API validates role against content type strictly:
 * - user / system / developer -> `input_text` / `input_image` / `input_file`
 * - assistant -> `output_text` (a past answer; assistant turns never carry images or files)
 *
 * Mixing them is rejected outright by the upstream, and by relays that validate the body
 * before forwarding it.
 */
export function buildResponsesContent(
  role: 'user' | 'assistant' | 'system',
  content: string | ContentPart[],
) {
  if (role === 'assistant') {
    if (typeof content === 'string') {
      return [{ type: 'output_text' as const, text: content }];
    }
    return content
      .filter((part): part is Extract<ContentPart, { type: 'text' }> => part.type === 'text')
      .map((part) => ({ type: 'output_text' as const, text: part.text }));
  }
  if (typeof content === 'string') {
    return [{ type: 'input_text' as const, text: content }];
  }
  return convertToResponsesParts(content);
}

export function extractText(parts: ContentPart[]): string {
  return parts
    .filter((part) => part.type === 'text')
    .map((part) => part.text)
    .join('\n');
}

export function convertToAnthropicParts(parts: ContentPart[]) {
  return parts.map((part) => {
    if (part.type === 'text') {
      return { type: 'text' as const, text: part.text };
    }
    if (part.type === 'image_url') {
      const matched = part.image_url.url.match(/^data:([^;]+);base64,(.+)$/);
      if (matched) {
        return {
          type: 'image' as const,
          source: { type: 'base64' as const, media_type: matched[1], data: matched[2] },
        };
      }
    }
    if (part.type === 'video_url') {
      return { type: 'text' as const, text: `[video: ${part.video_url.url}]` };
    }
    if (part.type === 'file') {
      const matched = part.file.file_data.match(/^data:([^;]+);base64,(.+)$/);
      if (matched) {
        return {
          type: 'document' as const,
          source: { type: 'base64' as const, media_type: matched[1] as 'application/pdf', data: matched[2] },
        };
      }
    }
    return { type: 'text' as const, text: '[file]' };
  });
}

export function convertToGeminiParts(parts: ContentPart[]) {
  return parts.map((part) => {
    if (part.type === 'text') {
      return { text: part.text };
    }
    if (part.type === 'image_url') {
      const matched = part.image_url.url.match(/^data:([^;]+);base64,(.+)$/);
      if (matched) {
        return { inlineData: { mimeType: matched[1], data: matched[2] } };
      }
    }
    if (part.type === 'video_url') {
      const matched = part.video_url.url.match(/^data:([^;]+);base64,(.+)$/);
      if (matched) {
        return { inlineData: { mimeType: matched[1], data: matched[2] } };
      }
      return { text: `[video: ${part.video_url.url}]` };
    }
    if (part.type === 'file') {
      const matched = part.file.file_data.match(/^data:([^;]+);base64,(.+)$/);
      if (matched) {
        return { inlineData: { mimeType: matched[1], data: matched[2] } };
      }
    }
    return { text: '[file]' };
  });
}

/* ── Relay reasoning mapping ──────────────────────────────
 * A user-supplied endpoint has no authoritative metadata to consult, so relay gets a
 * conservative local heuristic instead. It applies to relay only: when the upstream rejects it
 * the setting is kept and the error is surfaced, and it must not be reused on official
 * provider paths.
 */

export function mapOpenAIReasoning(mode: NonNullable<StreamOptions['reasoning']>) {
  switch (mode) {
    case 'fast':
      return 'low';
    case 'balanced':
      return 'medium';
    case 'deep':
      return 'high';
    case 'max':
      // 'xhigh' sits above the effort levels OpenAI documents. It is passed through as-is:
      // relays that understand it honour it, and the rest fall back to their own default.
      return 'xhigh';
    default:
      return 'medium';
  }
}

/**
 * reasoning_effort for both OpenAI protocols: mapped only from this turn's ReasoningMode (automatic => omit).
 * The connection-level tier is retired and a stored legacy value takes no part.
 */
export function resolveOpenAIReasoningEffort(
  options: StreamOptions | undefined,
): 'low' | 'medium' | 'high' | 'xhigh' | undefined {
  if (!options?.reasoning || options.reasoning === 'automatic') return undefined;
  return mapOpenAIReasoning(options.reasoning);
}

/**
 * The single mapping for Gemini thinkingBudget: the same values as iOS / Android / Server `gem_budget`.
 * The relay Gemini builder and the transport strategy share this one function; the old 2048 / 8192 would make the same tier send different budgets on the three clients.
 */
export function mapGeminiReasoningBudget(mode: string): number {
  switch (mode) {
    case 'fast':
      return 1024;
    case 'balanced':
      return 4096;
    case 'deep':
      return 16384;
    case 'max':
      // The official upper limit of thinkingBudget for gemini-2.5-pro is 24576.
      return 24576;
    default:
      return 4096;
  }
}

/* ── Non-streaming response parsing (4 transports) ───────────────────── */

export function parseOpenAIChatCompletionsResponse(payload: unknown): StreamEvent[] {
  const chunk = payload as {
    choices?: Array<{
      message?: {
        content?: string | Array<{ type?: string; text?: string }>;
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

  const message = chunk.choices?.[0]?.message;
  const text = typeof message?.content === 'string'
    ? message.content
    : message?.content
      ?.filter((part) => part.type === 'text' && typeof part.text === 'string')
      .map((part) => part.text as string)
      .join('');
  if (text) {
    events.push({ type: 'delta', content: text });
  }
  for (const image of message?.images ?? []) {
    if (image.image_url?.url) {
      events.push({ type: 'image', url: image.image_url.url });
    }
  }
  if (chunk.usage) {
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

  return events;
}

export function parseResponsesResponse(payload: unknown): StreamEvent[] {
  const response = payload as {
    output_text?: string;
    output?: Array<{
      type?: string;
      result?: string;
      content?: Array<{ type?: string; text?: string; result?: string }>;
    }>;
    usage?: {
      input_tokens?: number;
      output_tokens?: number;
    };
  };
  const events: StreamEvent[] = [];
  const text = response.output_text
    || response.output
      ?.flatMap((item) => item.content ?? [])
      .map((part) => (part.type === 'output_text' && typeof part.text === 'string') ? part.text : '')
      .join('');
  if (text) {
    events.push({ type: 'delta', content: text });
  }
  for (const item of response.output ?? []) {
    if (item.type === 'image_generation_call' && item.result) {
      events.push({ type: 'image', url: toImageDataUrl(item.result) });
    }
    for (const part of item.content ?? []) {
      if (part.type === 'output_image' && part.result) {
        events.push({ type: 'image', url: toImageDataUrl(part.result) });
      }
    }
  }
  if (response.usage) {
    events.push({
      type: 'usage',
      usage: {
        prompt_tokens: response.usage.input_tokens ?? 0,
        completion_tokens: response.usage.output_tokens ?? 0,
        total_tokens: (response.usage.input_tokens ?? 0) + (response.usage.output_tokens ?? 0),
        // Responses shape: the breakdown sits in input_tokens_details / output_tokens_details
        // and must be normalised first, or cache reads and reasoning are lost entirely.
        breakdown: parseUsageOpenAIResponses(response.usage as Record<string, unknown>),
      },
    });
  }

  return events;
}

/* ── OpenAI Images endpoint (imagesEndpoint route) ────────── */

/**
 * Use the text of the last user message as the prompt.
 *
 * `/images/generations` has no notion of a conversation and takes a single prompt, so history is
 * dropped on this route. That is why the inline-tool route over Responses exists: it is the one
 * that carries context.
 */
export function extractImagePrompt(
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
): string {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.role !== 'user') continue;
    const text = typeof message.content === 'string'
      ? message.content
      : extractText(message.content);
    if (text.trim()) return text.trim();
  }
  return '';
}

/**
 * Build the `/images/generations` request body.
 *
 * `gpt-image-*` / `chatgpt-image-*` do not accept `response_format` (b64_json is already the
 * default); sending it explicitly comes back as a 400 `Unknown parameter` from OpenAI directly
 * or from a strict relay. See the isDedicatedImageModel notes in
 * `@oriveo/shared/relay/image-models`.
 */
export function buildImagesGenerationsBody(
  modelID: string,
  prompt: string,
  options?: StreamOptions,
): Record<string, unknown> {
  const body: Record<string, unknown> = { model: modelID, prompt };
  if (options?.relayImageCount && options.relayImageCount > 0) {
    body.n = options.relayImageCount;
  }
  if (options?.relayImageSize?.trim()) body.size = options.relayImageSize.trim();
  if (options?.relayImageQuality?.trim()) body.quality = options.relayImageQuality.trim();
  if (options?.relayImageStyle?.trim()) body.style = options.relayImageStyle.trim();
  if (options?.relayImageResponseFormat?.trim() && !isDedicatedImageModel(modelID)) {
    body.response_format = options.relayImageResponseFormat.trim();
  }
  return body;
}

/** Parse an `/images/generations` response: `data[].b64_json | url`, plus optional usage. */
export function parseImagesGenerationsResponse(payload: unknown): StreamEvent[] {
  const response = payload as {
    data?: Array<{ b64_json?: string; url?: string; revised_prompt?: string }>;
    usage?: {
      input_tokens?: number;
      output_tokens?: number;
      total_tokens?: number;
    };
  };
  const events: StreamEvent[] = [];

  for (const item of response.data ?? []) {
    if (item.b64_json) {
      events.push({ type: 'image', url: toImageDataUrl(item.b64_json) });
    } else if (item.url) {
      // A URL is left to the attachment pipeline above to download, as in the chat_completions images branch
      events.push({ type: 'image', url: item.url });
    }
  }

  if (response.usage) {
    const promptTokens = response.usage.input_tokens ?? 0;
    const completionTokens = response.usage.output_tokens ?? 0;
    events.push({
      type: 'usage',
      usage: {
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        total_tokens: response.usage.total_tokens ?? promptTokens + completionTokens,
        // Responses shape: the breakdown sits in input_tokens_details / output_tokens_details
        // and must be normalised first, or cache reads and reasoning are lost entirely.
        breakdown: parseUsageOpenAIResponses(response.usage as Record<string, unknown>),
      },
    });
  }

  return events;
}

export function parseAnthropicResponse(payload: unknown): StreamEvent[] {
  const response = payload as {
    content?: Array<{ type?: string; text?: string }>;
    usage?: {
      input_tokens?: number;
      output_tokens?: number;
    };
  };
  const events: StreamEvent[] = [];
  const text = response.content
    ?.filter((part) => part.type === 'text' && typeof part.text === 'string')
    .map((part) => part.text as string)
    .join('');
  if (text) {
    events.push({ type: 'delta', content: text });
  }
  if (response.usage) {
    events.push({
      type: 'usage',
      usage: {
        prompt_tokens: response.usage.input_tokens ?? 0,
        completion_tokens: response.usage.output_tokens ?? 0,
        total_tokens: (response.usage.input_tokens ?? 0) + (response.usage.output_tokens ?? 0),
        breakdown: parseUsageAnthropic(response.usage as Record<string, unknown>),
      },
    });
  }
  return events;
}

export function parseGeminiResponse(payload: unknown): StreamEvent[] {
  const response = payload as {
    candidates?: Array<{
      content?: {
        parts?: Array<{ text?: string; inlineData?: { mimeType?: string; data?: string } }>;
      };
    }>;
    usageMetadata?: {
      promptTokenCount?: number;
      candidatesTokenCount?: number;
      totalTokenCount?: number;
    };
  };
  const events: StreamEvent[] = [];
  for (const part of response.candidates?.[0]?.content?.parts ?? []) {
    if (part.text) {
      events.push({ type: 'delta', content: part.text });
    }
    if (part.inlineData?.mimeType && part.inlineData.data) {
      events.push({
        type: 'image',
        url: `data:${part.inlineData.mimeType};base64,${part.inlineData.data}`,
      });
    }
  }
  if (response.usageMetadata) {
    events.push({
      type: 'usage',
      usage: {
        prompt_tokens: response.usageMetadata.promptTokenCount ?? 0,
        completion_tokens: response.usageMetadata.candidatesTokenCount ?? 0,
        total_tokens: response.usageMetadata.totalTokenCount ?? 0,
        breakdown: parseUsageGemini(response.usageMetadata as Record<string, unknown>),
      },
    });
  }
  return events;
}

/* ── Responses image event de-duplication ──────────────────────── */

/**
 * The item id carried by a Responses image event, used to de-duplicate across events:
 * - response.output_image.done -> chunk.item_id or chunk.id
 * - response.image_generation_call.completed -> chunk.item_id
 * - response.output_item.done -> chunk.item?.id
 */
export function asImageItemId(chunk: Record<string, unknown>): string | undefined {
  const itemId = chunk.item_id;
  if (typeof itemId === 'string' && itemId) return itemId;
  const id = chunk.id;
  if (typeof id === 'string' && id) return id;
  const item = chunk.item as { id?: string } | undefined;
  if (item && typeof item.id === 'string' && item.id) return item.id;
  return undefined;
}

export function resolveResponsesImageResult(chunk: Record<string, unknown>): string | undefined {
  if (typeof chunk.result === 'string' && chunk.result) {
    return chunk.result;
  }

  const item = chunk.item as {
    result?: string;
    content?: Array<{ type?: string; result?: string }>;
  } | undefined;
  if (item && typeof item.result === 'string' && item.result) {
    return item.result;
  }
  const contentResult = item?.content?.find((part) => part.type === 'output_image' && typeof part.result === 'string')?.result;
  return typeof contentResult === 'string' && contentResult ? contentResult : undefined;
}

export function toImageDataUrl(payload: string): string {
  return payload.startsWith('data:')
    ? payload
    : `data:image/png;base64,${payload}`;
}
