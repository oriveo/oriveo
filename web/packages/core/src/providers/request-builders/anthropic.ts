// Anthropic Messages API request builder
import { resolveProviderBaseURL } from "../url-utils";
import { buildAnthropicRequestPayload, deepMerge } from "./runtime";
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { guardAnthropicThinking } from './anthropic-thinking';
import { credentialHeader, mergeDroppedGenerationParameters, writeGenerationParameters } from './generation-parameters';
import { moveHostMemoryToolsLast, toAnthropicTool } from './tool-call-wire-adapter';
import { markAnthropicCacheBreakpoint } from '../relay-adapter';
import { resolveAnthropicMaxTokens, usesAnthropicExplicitPromptCache } from '../protocol-implementations';

export function buildAnthropicRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  maxOutputTokens?: number,
  /** Model catalog promptCache.policyRef; only anthropic.explicit gets a cache_control breakpoint. */
  promptCachePolicyRef?: string,
): ProviderRequest {
  const payload = buildAnthropicRequestPayload(params.messages);
  // Single block-level breakpoint: [D] is split off as its own last block, the breakpoint goes on the last non-[D] block before it, and there is no top-level cache_control.
  // Only added when the catalog verdict promptCache.policyRef is anthropic.explicit; a missing policyRef means no breakpoint.
  const messages = payload.messages as Array<Record<string, unknown>>;
  const explicitPromptCache = usesAnthropicExplicitPromptCache(promptCachePolicyRef);
  if (explicitPromptCache) markAnthropicCacheBreakpoint(messages, params.options?.dynamicText);
  // Explicit value > the model maxOutputTokens (dispatch synthesizes one input); only if neither exists is the protocol default used.
  const defaultMaxTokens = resolveAnthropicMaxTokens(maxOutputTokens);
  const body: Record<string, unknown> = {
    model: params.modelID,
    max_tokens: defaultMaxTokens,
    stream: params.stream !== false,
    messages,
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
  moveHostMemoryToolsLast('anthropic_messages', body, params.tools);
  const builderDefaultMaxTokens = body.max_tokens;
  const { written, dropped: writeDropped } = writeGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
    { toolsActive: Boolean(params.tools?.length) },
  );
  // The thinking fields were already written by reasoningParams, so the linkage guard must be evaluated again after the generation parameters.
  const thinkingDropped = guardAnthropicThinking(body, {
    profile: params.options?.generationProfile,
    written,
    builderDefaultMaxTokens,
  });

  return {
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/messages`,
    headers: {
      ...STREAM_HEADERS,
      ...credentialHeader('x-api-key', params.apiKey),
      "anthropic-version": "2023-06-01",
    },
    body,
    droppedGenerationParameters: mergeDroppedGenerationParameters(writeDropped, thinkingDropped),
    generationWrite: { written, builderDefaultMaxTokens },
    ...(promptCachePolicyRef ? { promptCachePolicyRef } : {}),
  };
}
