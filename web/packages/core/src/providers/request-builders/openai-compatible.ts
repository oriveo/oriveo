// Generic OpenAI-compatible builder - shared by Groq, Together AI, Fireworks AI and Relay
import { resolveProviderBaseURL } from "../url-utils";
import { buildOpenAIChatMessages, deepMerge } from "./runtime";
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { applyGenerationParameters, credentialHeader } from './generation-parameters';

export function buildOpenAICompatibleRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
): ProviderRequest {
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
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/chat/completions`,
    headers: {
      ...STREAM_HEADERS,
      ...credentialHeader('Authorization', params.apiKey ? `Bearer ${params.apiKey}` : ''),
    },
    body,
  };
}
