// Grok (xAI) request builder -- OpenAI-compatible Chat Completions plus selective
// reasoning_effort. Web search goes through the xAI Responses API and Agent Tools
// (grok_responses_web); the older search_parameters returns 410 Gone as of 2026-01-12.
import { resolveProviderBaseURL } from "../url-utils";
import { buildOpenAIChatMessages, buildOpenAIResponsesInput, deepMerge } from "./runtime";
import {
  STREAM_HEADERS,
  type ProviderRequest,
  type RequestParams,
} from "./types";
import { isResponsesWebSearchProfile } from "./openai";
import { applyGenerationParameters, credentialHeader } from './generation-parameters';

export function buildGrokRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  transport?: string,
): ProviderRequest {
  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);

  // Web search: grok-4.1+ enables web_search through the Responses API and Agent Tools
  // (grok_responses_web). The profile's tools[0].type==='web_search' is Responses schema and is
  // incompatible with Chat Completions, so a match switches wholesale to the /responses endpoint
  // and the Responses input format.
  const webSearchIsResponses =
    params.options?.supportsWebSearch &&
    webSearchProfile?.mergeParams &&
    isResponsesWebSearchProfile(webSearchProfile.mergeParams);

  // Model-level transport pinned to Responses: xAI does not allow grok-4.20-multi-agent on chat
  // completions (a direct call answers 400), so the backend sends defaultTransport
  // openai_responses and the endpoint is switched on that signal alone. Keeping it as the single
  // source of truth avoids branching locally on model id, which drifts from the backend.
  const useResponses = webSearchIsResponses || transport === "openai_responses";

  if (useResponses) {
    const body: Record<string, unknown> = {
      model: params.modelID,
      stream: params.stream !== false,
      input: buildOpenAIResponsesInput(params.messages),
    };
    // Inject the web_search tool, including the filters / enable_image_understanding sent by the server profile.
    deepMerge(body, webSearchProfile?.mergeParams);

    // reasoning_effort: the Responses parameter means the same as in Chat Completions and is driven by the server reasoning profile.
    if (reasoningParams) {
      deepMerge(body, reasoningParams);
    }
    applyGenerationParameters(
      body,
      params.options?.generationParameters,
      params.options?.generationProfile,
    );

    return {
      url: `${baseURL}/responses`,
      headers: {
        ...STREAM_HEADERS,
        ...credentialHeader('Authorization', params.apiKey ? `Bearer ${params.apiKey}` : ''),
      },
      body,
    };
  }

  // Without web search the existing Chat Completions path is unchanged.
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  // reasoning_effort injection is driven entirely by the reasoning profile the server sends,
  // which is the single source of truth: the backend assigns a profile only to the grok models
  // measured to accept the parameter, and reasoningParams is null for the rest. No local model
  // allowlist is kept -- it drifts from the backend, and newer xAI generations
  // (grok-4.20+/build/code) reject unknown parameters with a hard 400, so acceptance cannot be
  // inferred from the model id.
  if (reasoningParams) {
    deepMerge(body, reasoningParams);
  }
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
  );

  return {
    url: `${baseURL}/chat/completions`,
    headers: {
      ...STREAM_HEADERS,
      ...credentialHeader('Authorization', params.apiKey ? `Bearer ${params.apiKey}` : ''),
    },
    body,
  };
}
