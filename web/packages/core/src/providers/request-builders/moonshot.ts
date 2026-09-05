// Moonshot (Kimi) request builder - supports the built-in $web_search tool loop (streaming per leg, plus the tool loop adapter)
import { resolveProviderBaseURL } from "../url-utils";
import { buildOpenAIChatMessages, deepMerge } from "./runtime";
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { applyGenerationParameters } from './generation-parameters';

export function buildMoonshotRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown>; maxToolLoops?: number } | null,
): ProviderRequest {
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  deepMerge(body, reasoningParams);
  if (params.options?.supportsWebSearch) {
    deepMerge(body, webSearchProfile?.mergeParams);
  }
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
  );

  return {
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/chat/completions`,
    headers: {
      ...STREAM_HEADERS,
      Authorization: `Bearer ${params.apiKey}`,
    },
    body,
    responseAdapter: params.options?.supportsWebSearch ? "moonshot_tool_loop" : undefined,
    moonshotMaxToolLoops: webSearchProfile?.maxToolLoops,
  };
}
