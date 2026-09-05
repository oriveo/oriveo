// Qwen / DashScope request builder
//   - Text chat: OpenAI-compatible endpoint /compatible-mode/v1/chat/completions (standard OpenAI SSE, passthrough)
//   - Image generation: native DashScope multimodal generation endpoint
//
// Why text does not use the native DashScope text-generation endpoint: the qwen3.x models (3.5/3.6/3.7)
// exist only on the compatible endpoint, and the native one returns a url error for them. The cost is that
// the compatible protocol returns no structured search_info citations (an Alibaba Cloud limitation, they
// exist only on the native endpoint), but enable_search still lets the model search and fold the results
// into its answer, and working beats citation chips.
// In-stream error passthrough is handled by the client proxy parser (parseProxyChunk recognizes OpenAI-style error chunks).
import { resolveProviderBaseURL } from "../url-utils";
import { buildOpenAIChatMessages, deepMerge } from "./runtime";
import {
  JSON_HEADERS,
  STREAM_HEADERS,
  type ProviderRequest,
  type RequestParams,
} from "./types";
import { extractLatestUserPrompt } from "./response-utils";
import { applyGenerationParameters } from './generation-parameters';

export function buildQwenRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  imageGenProfile: { route?: string; requestDefaults?: Record<string, unknown> } | null,
): ProviderRequest {
  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);

  // Image generation: native DashScope multimodal generation endpoint
  if (imageGenProfile?.route === "dashscope_multimodal") {
    const prompt = extractLatestUserPrompt(params.messages);
    if (!prompt) {
      throw new Error("Image generation requires a text prompt");
    }

    const imageURL = `${resolveDashScopeNativeBaseURL(baseURL)}/api/v1/services/aigc/multimodal-generation/generation`;

    return {
      url: imageURL,
      headers: {
        ...JSON_HEADERS,
        Authorization: `Bearer ${params.apiKey}`,
        "X-DashScope-Async": "disable",
      },
      body: {
        model: params.modelID,
        input: {
          messages: [{ role: "user", content: [{ text: prompt }] }],
        },
        parameters: {
          ...imageGenProfile.requestDefaults,
        },
      },
      responseAdapter: "qwen_images_api",
    };
  }

  // Text chat: standard OpenAI-compatible request body (passthrough, same as groq / openai).
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  // reasoning (enable_thinking / thinking_budget) is read as a **top-level** extension parameter on the compatible endpoint.
  deepMerge(body, flattenParameters(reasoningParams));
  // Web search (enable_search / search_options) is injected at the top level as well.
  if (params.options?.supportsWebSearch) {
    deepMerge(body, flattenParameters(webSearchProfile?.mergeParams ?? null));
  }
  // Generation parameters follow the catalog template wire path (openai_chat_completions) and are already
  // top-level fields, so flattenParameters is not needed here; that only corrects the native DashScope
  // nesting used by reasoning/webSearch profiles.
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
  );

  return {
    url: resolveDashScopeCompatibleChatURL(baseURL),
    headers: {
      ...STREAM_HEADERS,
      Authorization: `Bearer ${params.apiKey}`,
    },
    body,
  };
}

/** Normalizes any base form to the DashScope OpenAI-compatible chat endpoint. */
export function resolveDashScopeCompatibleChatURL(baseURL: string): string {
  let base = baseURL.replace(/\/+$/, "");
  if (base.endsWith("/chat/completions")) return base;
  // Strip any leftover native generation path and compatible suffix to recover the origin/base segment
  base = base.replace(/\/api\/v1\/services\/aigc\/text-generation\/generation$/, "");
  base = base.replace(/\/compatible-mode\/v1$/, "").replace(/\/+$/, "");
  const lower = base.toLowerCase();
  // Official DashScope host -> canonical compatible endpoint; custom proxies -> the standard OpenAI-compatible path
  if (lower.includes("dashscope") || lower.includes("aliyuncs")) {
    return `${base}/compatible-mode/v1/chat/completions`;
  }
  return `${base}/chat/completions`;
}

export function resolveDashScopeNativeBaseURL(baseURL: string): string {
  return baseURL.replace(/\/compatible-mode\/v1$/, "");
}

/**
 * Flattens the mergeParams of reasoning / webSearch profiles to the top level: the compatible endpoint
 * reads enable_thinking / enable_search as top-level extension parameters and does not understand the
 * native DashScope `parameters` nesting. This bridges the window where the catalog still ships the nested shape.
 */
function flattenParameters(
  params: Record<string, unknown> | null | undefined,
): Record<string, unknown> | null {
  if (!params) return null;
  const { parameters, ...rest } = params;
  if (parameters && typeof parameters === "object" && !Array.isArray(parameters)) {
    return { ...rest, ...(parameters as Record<string, unknown>) };
  }
  return rest;
}
