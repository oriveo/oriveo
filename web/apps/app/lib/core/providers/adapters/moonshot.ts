/**
 * Kimi / Moonshot adapter.
 *
 * Catalog truth comes from backend metadata. This adapter only handles model
 * sync compatibility and the browser-direct China Mainland runtime path used
 * when the production server cannot reach api.moonshot.cn.
 */

import {
  buildModelsFromCatalog,
  type RemoteModel,
} from "./openai-compatible";
import { buildRecommendedModels } from "../catalog-model";
import { createSSEStream, type ParseChunkFn } from "../../../infra/sse-parser";
import {
  browserOfficialMetadata,
  getReasoningProfile,
  initMetadata,
  listProviderModelIds,
  resolveCatalogModel,
} from "../../metadata/metadata-client";
import { USE_PROXY, syncModelsProxy } from "../proxy-client";
import { reportUnsupportedParamDropped } from "../unsupported-param-telemetry";
import { parseUsageMoonshot } from "../transport/usage-parsers";
import {
  executeWithUnsupportedParamSelfHeal,
  type UnsupportedParamScope,
} from "@oriveo/core/providers/unsupported-param";
// The relay prefix only says where this originated: it is a generic irreversible origin+path fingerprint and applies to official endpoints too.
import { relayEndpointFingerprint } from "@oriveo/core/providers/relay-stream";
import type { UpstreamTransport } from "@oriveo/core";
import { createProxyChunkParser } from "@oriveo/core/providers/proxy-chunk-parser";
import { buildProviderRequest } from "@oriveo/core/providers/request-builders/dispatch";
import type { ProviderRequest, RequestParams } from "@oriveo/core/providers/request-builders/types";
import {
  adaptMoonshotFormulaFiberResponse,
  prepareMoonshotFormulaRequest,
} from "@oriveo/core/providers/response-adapters/moonshot-formula-fiber-loop";
import { applyGenerationParameters } from "@oriveo/core/providers/request-builders/generation-parameters";
import type {
  ContentPart,
  StreamEvent,
  StreamHandle,
  StreamOptions,
  StreamUsage,
  SyncResult,
} from "../types";

type MoonshotMessage = {
  role: "user" | "assistant" | "system";
  content: string | ContentPart[];
};

interface MoonshotChunk {
  model?: string;
  choices?: Array<{
    delta?: {
      content?: string;
      reasoning_content?: string;
    };
    message?: {
      content?: string;
      reasoning_content?: string;
    };
    /** The Kimi stream sometimes puts usage inside choices[0] (seen in the recorded moonshot*.sse streams). */
    usage?: Record<string, unknown>;
  }>;
  usage?: Record<string, unknown>;
}

/** Usage of this frame: top level first, falling back to choices[0].usage when the top level is missing. */
function moonshotChunkUsage(chunk: MoonshotChunk): Record<string, unknown> | undefined {
  if (chunk.usage && typeof chunk.usage === "object") return chunk.usage;
  const nested = chunk.choices?.[0]?.usage;
  return nested && typeof nested === "object" && !Array.isArray(nested) ? nested : undefined;
}

export async function validateKey(
  apiKey: string,
  _baseURL: string,
): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
}

export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = (await syncModelsProxy("moonshot", apiKey, baseURL)) as {
      data?: RemoteModel[];
    };
    return buildMoonshotSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("moonshot");
  return buildMoonshotSyncResult(metadataModelIds.map((id) => ({ id })));
}

function buildMoonshotSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "moonshot");
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: MoonshotMessage[],
  baseURL: string,
  options?: StreamOptions,
): StreamHandle {
  const controller = new AbortController();
  const body: Record<string, unknown> = {
    model: modelID,
    stream: true,
    stream_options: { include_usage: true },
    messages: buildMoonshotMessages(messages),
  };
  const catalogModel = resolveCatalogModel(modelID, "moonshot");
  const modelProfiles = catalogModel?.profiles ?? {};
  const url = `${baseURL}/chat/completions`;
  const learningScope = moonshotLearningScope(modelID, url, options, catalogModel?.transport);

  const reasoningProfile = getReasoningProfile(modelProfiles.reasoning);
  if (options?.reasoning && options.reasoning !== "automatic") {
    deepMergeMoonshot(body, reasoningProfile?.params?.[options.reasoning]);
  }

  // Browser-direct Moonshot is the one official Web route that bypasses the
  // proxy/core request dispatcher. Consume the already facade-filtered map via
  // the same shared writer as buildMoonshotRequest; do not reinterpret support
  // or duplicate wire/value validation in this adapter.
  applyGenerationParameters(
    body,
    options?.generationParameters,
    options?.generationProfile,
  );

  const stream = options?.supportsWebSearch
    ? createMoonshotWebSearchStream(
      { apiKey, modelID, messages, baseURL, options },
      () => createMoonshotPlainStream(url, body, apiKey, controller, learningScope),
      controller,
    )
    : createMoonshotPlainStream(url, body, apiKey, controller, learningScope);

  return { stream, abort: () => controller.abort() };
}

/** Plain single-leg stream: Moonshot chunk to model / usage / reasoning / delta. */
function createMoonshotPlainStream(
  url: string,
  body: Record<string, unknown>,
  apiKey: string,
  controller: AbortController,
  learningScope: UnsupportedParamScope,
): ReadableStream<StreamEvent> {
  const parseChunk = (
    _eventType: string | null,
    data: string,
  ): StreamEvent | StreamEvent[] | null => {
    const chunk = JSON.parse(data) as MoonshotChunk;
    const events: StreamEvent[] = [];

    if (chunk.model) {
      events.push({ type: "model", modelID: chunk.model });
    }
    // The breakdown has to be injected, or Moonshot's top-level `cached_tokens` field is never
    // picked up: the OpenAI template reads prompt_tokens_details.cached_tokens and always finds 0,
    // so the cache discount is lost.
    const usage = moonshotChunkUsage(chunk);
    if (usage) {
      events.push({ type: "usage", usage: moonshotStreamUsage(usage) });
    }

    const choice = chunk.choices?.[0];
    const reasoning =
      choice?.delta?.reasoning_content ?? choice?.message?.reasoning_content;
    if (reasoning) {
      events.push({ type: "reasoning", content: reasoning });
    }

    const content = choice?.delta?.content ?? choice?.message?.content;
    if (content) {
      events.push({ type: "delta", content });
    }

    return events.length > 0 ? events : null;
  };

  return createMoonshotSelfHealingSSEStream(
    url,
    body,
    { Authorization: `Bearer ${apiKey}` },
    parseChunk,
    controller,
    learningScope,
  );
}

/** Browser fetch flavour of UpstreamTransport: the Formula GET, each chat leg and the Fiber POST all go straight to api.moonshot.cn through it. */
const browserUpstreamTransport: UpstreamTransport = {
  fetch: (url, init) => fetch(url, init),
};

interface MoonshotWebSearchInput {
  apiKey: string;
  modelID: string;
  messages: MoonshotMessage[];
  baseURL: string;
  options: StreamOptions;
}

/**
 * Web search on: the outbound shape is decided by the metadata recipe alone, through the same
 * builder as the proxy route. If the recipe is the official Formula (`moonshot_formula_fiber_loop`),
 * run core's Formula/Fiber loop; its output has the same shape as the proxy route and is decoded
 * by the same proxy chunk parser. Otherwise this turn runs without web search as a plain
 * single-leg stream (the legacy webSearch profile is no longer read to build the retired built-in tool).
 */
function createMoonshotWebSearchStream(
  input: MoonshotWebSearchInput,
  createPlainStream: () => ReadableStream<StreamEvent>,
  controller: AbortController,
): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      let inner: ReadableStream<StreamEvent>;
      try {
        const request = await buildProviderRequest(
          {
            providerKind: "moonshot",
            apiKey: input.apiKey,
            modelID: input.modelID,
            messages: input.messages,
            baseURL: input.baseURL,
            options: moonshotRecipeOptions(input.options),
          },
          () => browserOfficialMetadata("moonshot"),
        );
        inner = request.responseAdapter === "moonshot_formula_fiber_loop"
          // Keep the message shape of the existing browser-direct buildMoonshotMessages (file parts become text), same as the plain leg.
          ? await openMoonshotFormulaStream(
            { ...request, body: { ...request.body, messages: buildMoonshotMessages(input.messages) } },
            controller.signal,
          )
          : createPlainStream();
      } catch (error) {
        if (!controller.signal.aborted) ctrl.enqueue(moonshotRequestError(error));
        ctrl.close();
        return;
      }

      const reader = inner.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          ctrl.enqueue(value);
        }
      } finally {
        try { reader.releaseLock(); } catch { /* noop */ }
      }
      ctrl.close();
    },
    cancel() {
      controller.abort();
    },
  });
}

/** Same order as the proxy route: prepare, first leg, adapt. A non-2xx first leg goes to the SSE parser's HTTP error branch (status code and error classification unchanged). */
async function openMoonshotFormulaStream(
  request: ProviderRequest,
  signal: AbortSignal,
): Promise<ReadableStream<StreamEvent>> {
  const prepared = await prepareMoonshotFormulaRequest(request, browserUpstreamTransport, signal);
  const upstream = await browserUpstreamTransport.fetch(prepared.url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...prepared.headers },
    body: JSON.stringify(prepared.body),
    signal,
  });
  const response = upstream.ok
    ? await adaptMoonshotFormulaFiberResponse(upstream, prepared, browserUpstreamTransport, signal)
    : upstream;
  return createSSEStream(response, createProxyChunkParser("moonshot"), { signal });
}

/** Options handed to the builder on the browser-direct path: the same set the proxy route receives (local identity fields stay out of the builder). */
function moonshotRecipeOptions(options: StreamOptions): NonNullable<RequestParams["options"]> {
  return {
    supportsWebSearch: true,
    ...(options.reasoning !== undefined ? { reasoning: options.reasoning } : {}),
    ...(options.capabilityPreferences ? { capabilityPreferences: options.capabilityPreferences } : {}),
    ...(options.capabilityRecipeOmissions ? { capabilityRecipeOmissions: options.capabilityRecipeOmissions } : {}),
    ...(options.generationParameters ? { generationParameters: options.generationParameters } : {}),
    ...(options.generationProfile ? { generationProfile: options.generationProfile } : {}),
    ...(options.maxOutputTokens !== undefined ? { maxOutputTokens: options.maxOutputTokens } : {}),
    ...(options.dynamicText !== undefined ? { dynamicText: options.dynamicText } : {}),
    ...(options.customFragment ? { customFragment: options.customFragment } : {}),
    ...(options.customFragments ? { customFragments: options.customFragments } : {}),
    ...(options.additionalBody ? { additionalBody: options.additionalBody } : {}),
  };
}

/** A failed Formula GET / Fiber carries source=provider (core FormulaError); anything else (fetch throwing, etc.) counts as a network error. */
function moonshotRequestError(error: unknown): StreamEvent {
  const providerFailure = isPlainRecord(error) && error.source === "provider";
  return {
    type: "error",
    error: error instanceof Error ? error.message : "Network error",
    errorKind: providerFailure ? "upstream" : "network",
    source: providerFailure ? "provider" : "network",
  };
}


/**
 * Scope for parameter-rejection self-healing on a direct browser connection to Moonshot.
 *
 * The connection identity comes from StreamOptions (only the renderer has the partition, connection
 * epoch and metadata ETag), the transport is the protocol kind sent in metadata, and the endpoint
 * fingerprint is computed from the real request URL. This legacy scope does not drive error body
 * scanning, automatic parameter removal or cross-request learning; the fields are kept only for
 * reader compatibility.
 */
function moonshotLearningScope(
  modelID: string,
  url: string,
  options: StreamOptions | undefined,
  transport: string | undefined,
): UnsupportedParamScope {
  return {
    providerKind: "moonshot",
    modelID,
    ...(transport ? { transport } : {}),
    endpointFingerprint: relayEndpointFingerprint(url),
    ...(options?.capabilityIdentity ?? {}),
  };
}

function createMoonshotSelfHealingSSEStream(
  url: string,
  body: Record<string, unknown>,
  headers: Record<string, string>,
  parseChunk: ParseChunkFn,
  controller: AbortController,
  scope: UnsupportedParamScope,
): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    async start(ctrl) {
      let response: Response;
      try {
        const executed = await executeWithUnsupportedParamSelfHeal(
          { url, headers, body },
          {
            scope,
            signal: controller.signal,
            onUnsupportedParamDropped: reportUnsupportedParamDropped,
            execute: (request) => fetchMoonshotLeg(
              request.url,
              request.headers,
              request.body,
              controller.signal,
            ),
          },
        );
        response = executed.response;
      } catch (error) {
        if (!controller.signal.aborted) {
          ctrl.enqueue({
            type: "error",
            error: error instanceof Error ? error.message : "Network error",
            errorKind: "network",
            source: "network",
          });
        }
        ctrl.close();
        return;
      }

      const inner = createSSEStream(response, parseChunk, { signal: controller.signal });
      const reader = inner.getReader();
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          ctrl.enqueue(value);
        }
      } finally {
        try { reader.releaseLock(); } catch { /* noop */ }
      }
      ctrl.close();
    },
    cancel() {
      controller.abort();
    },
  });
}

async function fetchMoonshotLeg(
  url: string,
  headers: Record<string, string>,
  body: Record<string, unknown>,
  signal: AbortSignal,
): Promise<Response> {
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
    signal,
  });
}

/** Usage of a single leg: same parser as regular chat (top-level cached_tokens goes into the cache bucket). */
function moonshotStreamUsage(raw: Record<string, unknown>): StreamUsage {
  return {
    prompt_tokens: typeof raw.prompt_tokens === "number" ? raw.prompt_tokens : undefined,
    completion_tokens: typeof raw.completion_tokens === "number" ? raw.completion_tokens : undefined,
    total_tokens: typeof raw.total_tokens === "number" ? raw.total_tokens : undefined,
    breakdown: parseUsageMoonshot(raw),
  };
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function deepMergeMoonshot(
  target: Record<string, unknown>,
  source: Record<string, unknown> | undefined | null,
): Record<string, unknown> {
  if (!source) return target;
  for (const [key, value] of Object.entries(source)) {
    if (isPlainRecord(value) && isPlainRecord(target[key])) {
      deepMergeMoonshot(target[key] as Record<string, unknown>, value);
    } else if (Array.isArray(value)) {
      target[key] = [...value];
    } else {
      target[key] = value;
    }
  }
  return target;
}

export function isMoonshotChinaBaseURL(baseURL?: string): boolean {
  if (!baseURL) return false;
  try {
    return new URL(normalizeBaseURL(baseURL)).hostname.toLowerCase() === "api.moonshot.cn";
  } catch {
    return baseURL.toLowerCase().includes("api.moonshot.cn");
  }
}

function normalizeBaseURL(url: string): string {
  const trimmed = url.trim().replace(/\/+$/, "");
  if (!/^https?:\/\//i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

/** @internal Exported only so the line contrast test can read how this line actually handles each kind of part. */
export function buildMoonshotMessages(messages: MoonshotMessage[]) {
  return messages.map((message) => ({
    role: message.role,
    content: typeof message.content === "string"
      ? message.content
      : message.content.map((part) => {
        if (part.type === "file") {
          return { type: "text" as const, text: `[File: ${part.file.filename}]\n${part.file.file_data}` };
        }
        // Kimi multimodal does accept video_url, so it is passed through
        return part;
      }),
  }));
}
