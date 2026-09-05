import { isValidProviderKind, type ProviderKind } from '@oriveo/shared';
import type { ProxyMessage } from './runtime';
import type { RequestParams } from './request-builders/types';
import { validateContinuation, type ContinuationIntent } from '@oriveo/core/providers/request-preference/continuation';

/**
 * Runtime validation and size limits for this route's request parameters.
 *
 * Under BYOK a client may supply any apiKey/baseURL, but the server side is still a public endpoint.
 * Without validation a client could push 100MB of JSON to exhaust function memory, send a million
 * messages to trigger an OOM, or pass a baseURL that sends fetch to an unexpected scheme such as
 * file:// or ftp://.
 *
 * Only shape and limits are checked here. Semantic validation of the fields, such as whether the
 * apiKey actually works, is left to the upstream provider.
 */

/** Per-message content cap. Base64 images can be large: 10MB is roughly a seventh of the ~67MB of base64 a 50MB binary produces. */
const MAX_CONTENT_BYTES = 10 * 1024 * 1024; // 10MB / content
/** Cap on the length of the messages array; 100 conversation turns is roughly 200 messages. */
const MAX_MESSAGES_COUNT = 400;
/** API key length cap; a legitimate key never approaches 4KB. */
const MAX_API_KEY_LEN = 4096;
/** Model ID length cap. */
const MAX_MODEL_ID_LEN = 512;
/** baseURL length cap. */
const MAX_BASE_URL_LEN = 2048;
/** Whole request body cap of 50MB, which covers the longest reasonable BYOK request; anything larger already exceeds the model context. */
const MAX_TOTAL_BYTES = 50 * 1024 * 1024;
const MAX_TOOLS_COUNT = 16;
const MAX_TOOL_TEXT_LEN = 16 * 1024;
const LIBRARY_TOOL_NAMES = new Set(['library_search', 'library_list', 'library_read']);
const LIBRARY_TOOL_PARAMETERS: Record<string, { properties: string[]; required: string[] }> = {
  library_search: { properties: ['limit', 'query', 'sources'], required: ['query'] },
  library_list: { properties: ['containerId', 'cursor', 'source'], required: ['source'] },
  library_read: { properties: ['cursor', 'docId', 'section', 'source'], required: ['docId', 'source'] },
};

/**
 * Request parameters after route validation. The shape itself lives in @oriveo/core (RequestParams).
 *
 * `authMode` is consumed only inside this route, where it selects the endpoint and decides whether
 * the subscription headers are required, and is deliberately kept out of the builder parameters:
 * a builder should only see where to send and what to send, while resolving the auth mode is the
 * route's adaptation job.
 */
export type ValidatedRequest = RequestParams & { authMode?: 'apiKey' | 'subscription' };

export type ValidationResult =
  | { ok: true; value: ValidatedRequest }
  | { ok: false; status: number; error: string };

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function approximateByteLength(s: string): number {
  // Blob is too heavy for this. UTF-8 estimate: 1 byte for ASCII, 3 for CJK, 4 for emoji, so length * 4 is a conservative upper bound.
  return s.length * 4;
}

function validateMessageContentSize(content: unknown): boolean {
  if (typeof content === 'string') return approximateByteLength(content) <= MAX_CONTENT_BYTES;
  if (!Array.isArray(content)) return false;
  for (const part of content) {
    if (!isRecord(part)) return false;
    const type = part.type;
    if (typeof type !== 'string') return false;
    if (type === 'text') {
      if (typeof part.text === 'string') {
        if (approximateByteLength(part.text) > MAX_CONTENT_BYTES) return false;
      }
    } else if (type === 'image_url' || type === 'image') {
      // The base64 inside image_url, or inside an anthropic image source, can also be large
      const urlField = (part as { image_url?: unknown }).image_url;
      if (isRecord(urlField) && typeof urlField.url === 'string') {
        if (approximateByteLength(urlField.url) > MAX_CONTENT_BYTES) return false;
      }
      const source = (part as { source?: unknown }).source;
      if (isRecord(source) && typeof source.data === 'string') {
        if (approximateByteLength(source.data) > MAX_CONTENT_BYTES) return false;
      }
    }
  }
  return true;
}

function matchesLibraryToolParameters(name: string, value: Record<string, unknown>): boolean {
  const expected = LIBRARY_TOOL_PARAMETERS[name];
  if (!expected || value.type !== 'object' || value.additionalProperties !== false) return false;
  if (!isRecord(value.properties) || !Array.isArray(value.required)) return false;
  const properties = Object.keys(value.properties).sort();
  const required = value.required.filter((item): item is string => typeof item === 'string').sort();
  return properties.length === expected.properties.length
    && properties.every((item, index) => item === expected.properties[index])
    && required.length === expected.required.length
    && required.every((item, index) => item === expected.required[index]);
}

export function validateChatStreamRequest(body: unknown): ValidationResult {
  if (!isRecord(body)) {
    return { ok: false, status: 400, error: 'Invalid request body' };
  }

  // Rough overall size precheck
  let approxSize = 0;
  try {
    approxSize = JSON.stringify(body).length;
  } catch {
    return { ok: false, status: 400, error: 'Invalid request body' };
  }
  if (approxSize > MAX_TOTAL_BYTES) {
    return { ok: false, status: 413, error: 'Request body too large' };
  }

  // providerKind
  const providerKind = body.providerKind;
  if (typeof providerKind !== 'string' || !isValidProviderKind(providerKind)) {
    return { ok: false, status: 400, error: 'Invalid or missing providerKind' };
  }

  // apiKey
  const apiKey = body.apiKey;
  if (typeof apiKey !== 'string' || apiKey.length === 0) {
    return { ok: false, status: 400, error: 'Missing apiKey' };
  }
  if (apiKey.length > MAX_API_KEY_LEN) {
    return { ok: false, status: 400, error: 'apiKey too long' };
  }

  // modelID
  const modelID = body.modelID;
  if (typeof modelID !== 'string' || modelID.length === 0) {
    return { ok: false, status: 400, error: 'Missing modelID' };
  }
  if (modelID.length > MAX_MODEL_ID_LEN) {
    return { ok: false, status: 400, error: 'modelID too long' };
  }

  // baseURL (optional)
  const baseURL = body.baseURL;
  if (baseURL !== undefined) {
    if (typeof baseURL !== 'string') {
      return { ok: false, status: 400, error: 'baseURL must be a string' };
    }
    if (baseURL.length > MAX_BASE_URL_LEN) {
      return { ok: false, status: 400, error: 'baseURL too long' };
    }
    // Matches the downstream safeBase / resolveProviderBaseURL behavior: a bare host with no scheme
    // (such as 'api.deepseek.com/v1', which storage and sync often store without one) is allowed and
    // gets https:// at runtime. Only an **explicit** non-http/https scheme is rejected, covering
    // file://, ftp://, data: and other SSRF-friendly schemes.
    // (?!\d) separates a scheme like 'data:text/...' from a host:port like 'localhost:8080'.
    const schemeMatch = baseURL.trim().match(/^([a-z][a-z0-9+.-]*):(?!\d)/i);
    if (schemeMatch && !/^https?$/i.test(schemeMatch[1])) {
      return { ok: false, status: 400, error: 'baseURL must be http:// or https://' };
    }
  }

  // messages
  const messages = body.messages;
  if (!Array.isArray(messages)) {
    return { ok: false, status: 400, error: 'messages must be an array' };
  }
  if (messages.length === 0) {
    return { ok: false, status: 400, error: 'messages cannot be empty' };
  }
  if (messages.length > MAX_MESSAGES_COUNT) {
    return { ok: false, status: 400, error: `messages array exceeds ${MAX_MESSAGES_COUNT}` };
  }

  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    if (!isRecord(m)) {
      return { ok: false, status: 400, error: `messages[${i}] must be an object` };
    }
    const role = m.role;
    if (role !== 'user' && role !== 'assistant' && role !== 'system' && role !== 'tool') {
      return { ok: false, status: 400, error: `messages[${i}].role missing` };
    }
    if (!validateMessageContentSize(m.content)) {
      return { ok: false, status: 413, error: `messages[${i}].content exceeds size limit` };
    }
    if (role === 'tool' && (typeof m.tool_call_id !== 'string' || !m.tool_call_id.trim())) {
      return { ok: false, status: 400, error: `messages[${i}].tool_call_id missing` };
    }
    if (m.tool_calls !== undefined) {
      if (role !== 'assistant' || !Array.isArray(m.tool_calls) || m.tool_calls.length === 0) {
        return { ok: false, status: 400, error: `messages[${i}].tool_calls invalid` };
      }
      for (const call of m.tool_calls) {
        if (!isRecord(call) || typeof call.id !== 'string' || call.type !== 'function' || !isRecord(call.function)) {
          return { ok: false, status: 400, error: `messages[${i}].tool_calls invalid` };
        }
        if (typeof call.function.name !== 'string' || typeof call.function.arguments !== 'string') {
          return { ok: false, status: 400, error: `messages[${i}].tool_calls invalid` };
        }
        if (!LIBRARY_TOOL_NAMES.has(call.function.name)) {
          return { ok: false, status: 400, error: `messages[${i}].tool_calls invalid` };
        }
      }
    }
    if (m.providerContinuation !== undefined) {
      if (role !== 'assistant' || !isRecord(m.providerContinuation)
        || !validateContinuation(m.providerContinuation as unknown as ContinuationIntent).accepted) {
        return { ok: false, status: 400, error: `messages[${i}].providerContinuation invalid` };
      }
    }
  }

  const tools = body.tools;
  if (tools !== undefined) {
    if (!Array.isArray(tools) || tools.length !== 3 || tools.length > MAX_TOOLS_COUNT) {
      return { ok: false, status: 400, error: 'tools invalid' };
    }
    const seenToolNames = new Set<string>();
    for (const tool of tools) {
      if (!isRecord(tool) || tool.type !== 'function' || !isRecord(tool.function)) {
        return { ok: false, status: 400, error: 'tools invalid' };
      }
      const fn = tool.function;
      if (
        typeof fn.name !== 'string'
        || !LIBRARY_TOOL_NAMES.has(fn.name)
        || seenToolNames.has(fn.name)
        || typeof fn.description !== 'string'
        || !isRecord(fn.parameters)
        || !matchesLibraryToolParameters(fn.name, fn.parameters)
        || fn.name.length > MAX_TOOL_TEXT_LEN
        || fn.description.length > MAX_TOOL_TEXT_LEN
      ) {
        return { ok: false, status: 400, error: 'tools invalid' };
      }
      seenToolNames.add(fn.name);
    }
  }
  const toolChoice = body.toolChoice;
  if (toolChoice !== undefined && toolChoice !== 'auto' && toolChoice !== 'none' && toolChoice !== 'required') {
    return { ok: false, status: 400, error: 'toolChoice invalid' };
  }
  if (toolChoice !== undefined && tools === undefined) {
    return { ok: false, status: 400, error: 'toolChoice requires tools' };
  }
  const stream = body.stream;
  if (stream !== undefined && typeof stream !== 'boolean') {
    return { ok: false, status: 400, error: 'stream must be a boolean' };
  }

  const authMode = body.authMode;
  if (authMode !== undefined && authMode !== 'apiKey' && authMode !== 'subscription') {
    return { ok: false, status: 400, error: 'authMode invalid' };
  }

  // options (optional)
  const options = body.options;
  if (options !== undefined && !isRecord(options)) {
    return { ok: false, status: 400, error: 'options must be an object' };
  }
  // The client may supply raw JSON only. Owner maps are server/runtime authority and accepting
  // them here would let a caller widen the safe-custom write surface.
  if (isRecord(options) && options.customFragment !== undefined) {
    const fragment = options.customFragment;
    if (!isRecord(fragment) || typeof fragment.raw !== 'string' || Object.keys(fragment).some((key) => key !== 'raw')) {
      return { ok: false, status: 400, error: 'customFragment invalid' };
    }
  }
  if (isRecord(options) && options.customFragments !== undefined) {
    const fragments = options.customFragments;
    const owners = ['web', 'reasoning', 'generation'];
    if (!isRecord(fragments)
      || Object.keys(fragments).some((owner) => !owners.includes(owner))
      || Object.values(fragments).some((fragment) => !isRecord(fragment)
        || typeof fragment.raw !== 'string'
        || Object.keys(fragment).some((key) => key !== 'raw'))) {
      return { ok: false, status: 400, error: 'customFragments invalid' };
    }
  }
  if (isRecord(options) && options.capabilityRecipeOmissions !== undefined) {
    const omissions = options.capabilityRecipeOmissions;
    if (!Array.isArray(omissions) || omissions.length === 0 || omissions.length > 8
      || omissions.some((omission) => !isRecord(omission)
        || Object.keys(omission).some((key) => key !== 'recipeRef' && key !== 'locatedPointers')
        || typeof omission.recipeRef !== 'string' || omission.recipeRef.length === 0 || omission.recipeRef.length > 256
        || !Array.isArray(omission.locatedPointers) || omission.locatedPointers.length === 0 || omission.locatedPointers.length > 16
        || omission.locatedPointers.some((pointer) => typeof pointer !== 'string' || !pointer.startsWith('/') || pointer.length > 256))) {
      return { ok: false, status: 400, error: 'capabilityRecipeOmissions invalid' };
    }
  }
  const continuation = body.continuation;
  if (continuation !== undefined) {
    if (!isRecord(continuation)
      || typeof continuation.kind !== 'string'
      || (continuation.variant !== undefined && typeof continuation.variant !== 'string')
      || typeof continuation.step !== 'number'
      || !isRecord(continuation.state)
      || !validateContinuation(continuation as unknown as ContinuationIntent).accepted) {
      return { ok: false, status: 400, error: 'continuation invalid' };
    }
  }

  return {
    ok: true,
    value: {
      providerKind: providerKind as ProviderKind,
      apiKey,
      modelID,
      messages: messages as ProxyMessage[],
      stream: stream as boolean | undefined,
      baseURL: typeof baseURL === 'string' ? baseURL : undefined,
      tools: tools as ValidatedRequest['tools'],
      toolChoice: toolChoice as ValidatedRequest['toolChoice'],
      options: options as ValidatedRequest['options'],
      continuation: continuation as ValidatedRequest['continuation'],
      ...(authMode ? { authMode: authMode as 'apiKey' | 'subscription' } : {}),
    },
  };
}

export const VALIDATION_LIMITS = {
  MAX_CONTENT_BYTES,
  MAX_MESSAGES_COUNT,
  MAX_API_KEY_LEN,
  MAX_MODEL_ID_LEN,
  MAX_BASE_URL_LEN,
  MAX_TOTAL_BYTES,
  MAX_TOOLS_COUNT,
} as const;
