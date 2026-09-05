/**
 * DeepSeek model sync, metadata-only.
 *
 * The model catalog comes from backend metadata, and official providers do not verify the
 * upstream key. The official DeepSeek chat endpoint takes plain-text messages; reasoning
 * parameters are injected by the official request-builders from the metadata profile, so
 * this direct adapter does no local level mapping.
 */

import { createSSEFetchStream } from "../../../infra/sse-parser";
import { buildRecommendedModels } from "../catalog-model";
import {
  initMetadata,
  listProviderModelIds,
  refreshMetadata,
} from "../../metadata/metadata-client";
import {
  buildModelsFromCatalog,
  type RemoteModel,
} from "./openai-compatible";
import { USE_PROXY, syncModelsProxy } from "../proxy-client";
import { parseUsageDeepSeek } from "../transport/usage-parsers";
import type {
  ContentPart,
  StreamEvent,
  StreamHandle,
  StreamOptions,
  SyncResult,
} from "../types";

const DEFAULT_BASE = "https://api.deepseek.com/v1";

function normalizeBaseURL(url: string | undefined): string {
  if (!url) return DEFAULT_BASE;
  const trimmed = url.trim().replace(/\/+$/, "");
  if (!trimmed) return DEFAULT_BASE;
  if (!/^https?:\/\//i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

export async function validateKey(
  apiKey: string,
  _baseURL: string,
): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
}

/**
 * @deprecated The official provider catalog comes from metadata; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy("deepseek", apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    await refreshMetadata().catch(() => initMetadata().catch(() => {}));
    return buildDeepSeekSyncResult(json.data ?? []);
  }

  await refreshMetadata().catch(() => initMetadata().catch(() => {}));
  const modelIds = listProviderModelIds("deepseek");
  return buildDeepSeekSyncResult(modelIds.map((id) => ({ id })));
}

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: { role: "user" | "assistant" | "system"; content: string | ContentPart[] }[],
  baseURL: string,
  options?: StreamOptions,
): StreamHandle {
  const base = normalizeBaseURL(baseURL);
  const controller = new AbortController();
  const body: Record<string, unknown> = {
    model: modelID,
    stream: true,
    stream_options: { include_usage: true },
    messages: messages.map((message) => ({
      role: message.role,
      content: typeof message.content === "string"
        ? message.content
        : flattenContentParts(message.content),
    })),
  };
  void options;

  const parseChunk = (
    _eventType: string | null,
    data: string,
  ): StreamEvent | StreamEvent[] | null => {
    const chunk = JSON.parse(data) as {
      choices?: Array<{
        delta?: { content?: string; reasoning_content?: string };
        message?: { content?: string; reasoning_content?: string };
      }>;
      usage?: Record<string, unknown>;
    };
    const events: StreamEvent[] = [];

    // The breakdown must be injected so that the downstream deriveCostFields recognizes
    // prompt_cache_hit_tokens / prompt_cache_miss_tokens and prices them as cachedInput.
    // Without it the cache discount is lost, and a DeepSeek cache hit costs about 26% of a miss.
    if (chunk.usage) {
      events.push({
        type: "usage",
        usage: {
          prompt_tokens: typeof chunk.usage.prompt_tokens === "number" ? chunk.usage.prompt_tokens : undefined,
          completion_tokens: typeof chunk.usage.completion_tokens === "number" ? chunk.usage.completion_tokens : undefined,
          total_tokens: typeof chunk.usage.total_tokens === "number" ? chunk.usage.total_tokens : undefined,
          breakdown: parseUsageDeepSeek(chunk.usage),
        },
      });
    }

    // The DeepSeek reasoner emits its reasoning through reasoning_content while content is
    // null, then switches to the body in content. The two can interleave, so emit them separately.
    const reasoning =
      chunk.choices?.[0]?.delta?.reasoning_content
      ?? chunk.choices?.[0]?.message?.reasoning_content;
    if (reasoning) {
      events.push({ type: "reasoning", content: reasoning });
    }

    const content =
      chunk.choices?.[0]?.delta?.content
      ?? chunk.choices?.[0]?.message?.content;
    if (content) {
      events.push({ type: "delta", content });
    }

    return events.length > 0 ? events : null;
  };

  const stream = createSSEFetchStream(
    `${base}/chat/completions`,
    { headers: { Authorization: `Bearer ${apiKey}` }, body: JSON.stringify(body) },
    parseChunk,
    { signal: controller.signal },
  );

  return { stream, abort: () => controller.abort() };
}

function buildDeepSeekSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "deepseek");

  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}

function flattenContentParts(parts: ContentPart[]): string {
  // DeepSeek uses the markdown-v1 format; without an ATTACHMENT_FILE block the text is
  // concatenated directly. File attachments are normally already handled by
  // AttachmentInjector inside chat-stream-utils.buildChatHistory, so this is only a safety
  // net for a stray file part or a direct call.
  return parts.map((part) => {
    if (part.type === "text") {
      return part.text;
    }
    if (part.type === "image_url") {
      return "[Image omitted: unsupported by DeepSeek]";
    }
    if (part.type === "video_url") {
      return "[Video omitted: unsupported by DeepSeek]";
    }
    // File part fallback: reaching here means buildChatHistory did not handle it, which is
    // an exceptional path. Emit the documented format so the model never sees raw base64.
    const f = part.file;
    if (f.extractionErrorCode) {
      return `[File: ${f.filename}]\n[ERROR: extraction failed - ${f.extractionErrorCode}]`;
    }
    return `[File: ${f.filename}]`;
  }).join("\n\n");
}
