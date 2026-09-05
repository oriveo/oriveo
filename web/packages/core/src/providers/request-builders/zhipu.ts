// Zhipu GLM request builder - OpenAI-compatible for chat and vision, OpenAI DALL-E format for images
import { resolveProviderBaseURL } from "../url-utils";
import { buildOpenAIChatMessages, deepMerge } from "./runtime";
import {
  STREAM_HEADERS,
  type ProviderRequest,
  type RequestParams,
} from "./types";
import { applyGenerationParameters } from './generation-parameters';

export function buildZhipuRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
): ProviderRequest {
  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);

  // Chat, including vision: standard OpenAI-compatible shape
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  deepMerge(body, reasoningParams);
  // Web search: inject the GLM web_search tool into the chat completions tools array; deepMerge copies arrays and leaves messages intact.
  if (params.options?.supportsWebSearch) {
    deepMerge(body, webSearchProfile?.mergeParams);
  }
  // Generation parameters go in last, so explicit user values win over the merged profile (same order as openai-compatible and anthropic).
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
  );

  return {
    url: `${baseURL}/chat/completions`,
    headers: {
      ...STREAM_HEADERS,
      Authorization: `Bearer ${params.apiKey}`,
    },
    body,
  };
}
