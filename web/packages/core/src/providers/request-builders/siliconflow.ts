// SiliconFlow chat request builder — OpenAI compatible.
import { resolveProviderBaseURL } from "../url-utils";
import { buildOpenAIChatMessages, deepMerge } from "./runtime";
import {
  STREAM_HEADERS,
  type ProviderRequest,
  type RequestParams,
} from "./types";
import { applyGenerationParameters } from './generation-parameters';

export function buildSiliconFlowRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
): ProviderRequest {
  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);

  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  deepMerge(body, reasoningParams);
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
