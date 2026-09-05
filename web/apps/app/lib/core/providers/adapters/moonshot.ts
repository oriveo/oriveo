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
  getReasoningProfile,
  getWebSearchProfile,
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
import { applyGenerationParameters } from "@oriveo/core/providers/request-builders/generation-parameters";
import type {
  ContentPart,
  StreamEvent,
  StreamHandle,
  StreamOptions,
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
      tool_calls?: MoonshotToolCallDelta[];
    };
    message?: {
      content?: string;
      reasoning_content?: string;
    };
  }>;
  usage?: Record<string, unknown>;
}

/** Streaming tool_calls delta: id/type/name only appear in the first fragment, and arguments are split across fragments */
interface MoonshotToolCallDelta {
  index?: number;
  id?: string;
  type?: string;
  function?: { name?: string; arguments?: string };
}

interface MoonshotToolCall {
  id?: string;
  type?: string;
  function?: { name?: string; arguments?: string };
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

  const webSearchProfile = options?.supportsWebSearch
    ? getWebSearchProfile(modelProfiles.webSearch)
    : null;
  // Browser-direct Moonshot is the one official Web route that bypasses the
  // proxy/core request dispatcher. Consume the already facade-filtered map via
  // the same shared writer as buildMoonshotRequest; do not reinterpret support
  // or duplicate wire/value validation in this adapter.
  applyGenerationParameters(
    body,
    options?.generationParameters,
    options?.generationProfile,
  );
  if (webSearchProfile) {
    deepMergeMoonshot(body, webSearchProfile.mergeParams);
    return sendWebSearchToolLoopStream(
      apiKey,
      body,
      baseURL,
      controller,
      learningScope,
      webSearchProfile.maxToolLoops,
    );
  }

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
    if (chunk.usage) {
      events.push({
        type: "usage",
        usage: {
          prompt_tokens: typeof chunk.usage.prompt_tokens === "number" ? chunk.usage.prompt_tokens : undefined,
          completion_tokens: typeof chunk.usage.completion_tokens === "number" ? chunk.usage.completion_tokens : undefined,
          total_tokens: typeof chunk.usage.total_tokens === "number" ? chunk.usage.total_tokens : undefined,
          breakdown: parseUsageMoonshot(chunk.usage),
        },
      });
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

  const stream = createMoonshotSelfHealingSSEStream(
    url,
    body,
    { Authorization: `Bearer ${apiKey}` },
    parseChunk,
    controller,
    learningScope,
  );

  return { stream, abort: () => controller.abort() };
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

/** fallback only: keeps the previous ceiling when a profile carries no maxToolLoops, to avoid an unbounded tool loop. */
const DEFAULT_MOONSHOT_MAX_TOOL_LOOPS = 4;

/**
 * Streaming tool loop on the browser side: every leg is a streaming request, so reasoning and delta
 * events reach the stream live. If a leg ends with accumulated tool_calls, the echo plus arguments
 * are fed back into the next leg, otherwise the loop finishes. usage is captured per leg and summed
 * across legs (each leg is billed separately) and emitted once at the end.
 */
function sendWebSearchToolLoopStream(
  apiKey: string,
  body: Record<string, unknown>,
  baseURL: string,
  controller: AbortController,
  learningScope: UnsupportedParamScope,
  maxToolLoops?: number,
): StreamHandle {
  const stream = new ReadableStream<StreamEvent>({
    async start(ctrl) {
      const requestMessages = [...(body.messages as Array<Record<string, unknown>>)];
      const totals = { prompt: 0, completion: 0, cached: 0, seen: false };
      let anyReasoning = false;
      const toolLoopLimit = normalizeToolLoopLimit(maxToolLoops);

      for (let leg = 0; leg <= toolLoopLimit; leg += 1) {
        const legState = {
          text: "",
          reasoning: "",
          builders: new Map<number, { id?: string; type?: string; name?: string; arguments: string }>(),
          failed: false,
        };

        const parseChunk = (
          _eventType: string | null,
          data: string,
        ): StreamEvent | StreamEvent[] | null => {
          const chunk = JSON.parse(data) as MoonshotChunk;
          const events: StreamEvent[] = [];

          if (chunk.model) {
            events.push({ type: "model", modelID: chunk.model });
          }
          if (chunk.usage) {
            // usage is captured rather than forwarded; it is summed across legs and emitted once at the end
            totals.seen = true;
            totals.prompt += numberOrZero(chunk.usage.prompt_tokens);
            totals.completion += numberOrZero(chunk.usage.completion_tokens);
            totals.cached += numberOrZero(chunk.usage.cached_tokens);
          }

          const choice = chunk.choices?.[0];
          for (const toolDelta of choice?.delta?.tool_calls ?? []) {
            const index = toolDelta.index ?? 0;
            const builder = legState.builders.get(index) ?? { arguments: "" };
            if (toolDelta.id) builder.id = toolDelta.id;
            if (toolDelta.type) builder.type = toolDelta.type;
            if (toolDelta.function?.name) builder.name = toolDelta.function.name;
            if (toolDelta.function?.arguments) builder.arguments += toolDelta.function.arguments;
            legState.builders.set(index, builder);
          }

          const reasoning =
            choice?.delta?.reasoning_content ?? choice?.message?.reasoning_content;
          if (reasoning) {
            // Insert a paragraph break between legs so the streamed accumulation matches the final text character for character
            if (!legState.reasoning && anyReasoning) {
              events.push({ type: "reasoning", content: "\n\n" });
            }
            legState.reasoning += reasoning;
            events.push({ type: "reasoning", content: reasoning });
          }

          const content = choice?.delta?.content ?? choice?.message?.content;
          if (content) {
            legState.text += content;
            events.push({ type: "delta", content });
          }

          return events.length > 0 ? events : null;
        };

        const legStream = createMoonshotSelfHealingSSEStream(
          `${baseURL}/chat/completions`,
          { ...body, messages: requestMessages },
          { Authorization: `Bearer ${apiKey}` },
          parseChunk,
          controller,
          learningScope,
        );
        const reader = legStream.getReader();
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          // A leg's done event is handled by the outer wrap-up; an error is forwarded and ends the whole loop
          if (value.type === "done") continue;
          ctrl.enqueue(value);
          if (value.type === "error") legState.failed = true;
        }
        if (legState.failed) {
          ctrl.close();
          return;
        }

        anyReasoning = anyReasoning || legState.reasoning.length > 0;
        const toolCalls = finalizeMoonshotToolCalls(legState.builders);
        if (toolCalls.length === 0) break;

        // Feed back: echo the assistant tool-call message plus the tool result, with arguments
        // passed through unchanged. When thinking is active (enabled by default on k2.5/k2.6) Kimi
        // rejects an assistant tool-call message without reasoning_content with a 400; an empty
        // string is accepted, since the model may search without thinking first.
        requestMessages.push({
          role: "assistant",
          content: legState.text,
          reasoning_content: legState.reasoning,
          tool_calls: toolCalls,
        });
        for (const toolCall of toolCalls) {
          requestMessages.push({
            role: "tool",
            tool_call_id: toolCall.id ?? "",
            name: toolCall.function?.name ?? "$web_search",
            content: toolCall.function?.arguments || "{}",
          });
        }
      }

      if (totals.seen) {
        const rawUsage = {
          prompt_tokens: totals.prompt,
          completion_tokens: totals.completion,
          total_tokens: totals.prompt + totals.completion,
          cached_tokens: totals.cached,
        };
        ctrl.enqueue({
          type: "usage",
          usage: {
            prompt_tokens: totals.prompt,
            completion_tokens: totals.completion,
            total_tokens: totals.prompt + totals.completion,
            breakdown: parseUsageMoonshot(rawUsage),
          },
        });
      }
      ctrl.enqueue({ type: "done" });
      ctrl.close();
    },
    cancel() {
      controller.abort();
    },
  });

  return { stream, abort: () => controller.abort() };
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

function finalizeMoonshotToolCalls(
  builders: Map<number, { id?: string; type?: string; name?: string; arguments: string }>,
): MoonshotToolCall[] {
  return [...builders.entries()]
    .sort(([a], [b]) => a - b)
    .map(([, builder]) => ({
      id: builder.id,
      type: builder.type,
      function: { name: builder.name, arguments: builder.arguments },
    }));
}

function numberOrZero(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function normalizeToolLoopLimit(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0
    ? Math.floor(value)
    : DEFAULT_MOONSHOT_MAX_TOOL_LOOPS;
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

function buildMoonshotMessages(messages: MoonshotMessage[]) {
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
