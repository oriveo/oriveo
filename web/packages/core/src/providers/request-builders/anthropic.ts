// Anthropic Messages API request builder
import { resolveProviderBaseURL } from "../url-utils";
import { buildAnthropicRequestPayload, deepMerge } from "./runtime";
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { applyGenerationParameters, credentialHeader } from './generation-parameters';
import { toAnthropicTool } from './tool-call-wire-adapter';

export function buildAnthropicRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  maxOutputTokens?: number,
): ProviderRequest {
  const payload = buildAnthropicRequestPayload(params.messages);
  // fallback only: authoritative max output comes from metadata S1; 8192 is
  // kept only for stale/missing snapshots so non-thinking calls still run.
  const defaultMaxTokens =
    typeof maxOutputTokens === "number" && Number.isFinite(maxOutputTokens) && maxOutputTokens > 0
      ? maxOutputTokens
      : 8192;
  const body: Record<string, unknown> = {
    model: params.modelID,
    max_tokens: defaultMaxTokens,
    stream: params.stream !== false,
    cache_control: { type: "ephemeral" },
    messages: payload.messages,
  };

  if (payload.systemText) {
    body.system = payload.systemText;
  }
  if (params.tools?.length) body.tools = params.tools.map(toAnthropicTool);
  deepMerge(body, reasoningParams);
  // Web search: inject the web_search_20250305 tool into the Messages API tools array; deepMerge copies the array without breaking the existing structure.
  if (params.options?.supportsWebSearch) {
    deepMerge(body, webSearchProfile?.mergeParams);
  }
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
    { toolsActive: Boolean(params.tools?.length) },
  );

  return {
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/messages`,
    headers: {
      ...STREAM_HEADERS,
      ...credentialHeader('x-api-key', params.apiKey),
      "anthropic-version": "2023-06-01",
    },
    body,
  };
}
