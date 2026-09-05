// OpenAI / OpenRouter request builders (Responses API, Images API and plain Chat Completions).
import { brand } from "@oriveo/config";

import { resolveProviderBaseURL } from "../url-utils";
import {
  buildOpenAIChatMessages,
  buildOpenAIResponsesInput,
  deepMerge,
  resolveReasoningParams,
  usesOfficialOpenAIAPI,
  type RuntimeMetadataResponse,
} from "./runtime";
import {
  STREAM_HEADERS,
  type ProviderRequest,
  type RequestParams,
} from "./types";
import { applyGenerationParameters } from './generation-parameters';

export function buildOpenRouterRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  imageGenProfile: {
    route?: string;
    mergeParams?: Record<string, unknown>;
    requestDefaults?: Record<string, unknown>;
  } | null,
  maxOutputTokens?: number,
): ProviderRequest {
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };
  if (typeof maxOutputTokens === "number" && Number.isFinite(maxOutputTokens) && maxOutputTokens > 0) {
    body.max_tokens = maxOutputTokens;
  }

  deepMerge(body, reasoningParams);
  // The openrouter:web_search server tool rides in the same tools array as ordinary tools.
  if (params.options?.supportsWebSearch) {
    deepMerge(body, webSearchProfile?.mergeParams);
  }
  if (imageGenProfile?.route === "chat_api") {
    deepMerge(body, imageGenProfile.mergeParams);
  }
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
    { toolsActive: Boolean(params.tools?.length) },
  );

  return {
    url: `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/chat/completions`,
    headers: {
      ...STREAM_HEADERS,
      Authorization: `Bearer ${params.apiKey}`,
      // OpenRouter attributes usage on its public leaderboards to this pair. It has to be the
      // origin this deployment actually runs on, not a hardcoded dev port.
      "HTTP-Referer": brand.appUrl,
      "X-Title": brand.name,
    },
    body,
  };
}

export function buildOpenAIRequest(
  params: RequestParams,
  metadata: RuntimeMetadataResponse | null,
  reasoningProfile: { transport?: string; fallbackProfile?: string } | null,
  reasoningParams: Record<string, unknown> | null,
  imageGenProfile: {
    route?: string;
    mergeParams?: Record<string, unknown>;
    requestDefaults?: Record<string, unknown>;
  } | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  recipeEndpointClass?: string,
  modelTransport?: string,
): ProviderRequest {
  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);
  const official = usesOfficialOpenAIAPI(params.baseURL);

  // Web search is only supported on the official endpoints; the profile's tools schema decides
  // between Responses and Chat Completions.
  // oai_responses_web (preferred for gpt-4o/4.1/5) has tools[0].type==='web_search' -> Responses API.
  // oai_web_tool (gpt-5-search-api only) has tools[0].type==='web_search_preview' -> Chat Completions.
  const webSearchActive = official && params.options?.supportsWebSearch && webSearchProfile?.mergeParams;
  const webSearchIsResponses = webSearchActive && isResponsesWebSearchProfile(webSearchProfile?.mergeParams);

  const authoritativeResponsesTransport = modelTransport === 'openai_responses';
  const useResponsesAPI =
    (official || authoritativeResponsesTransport || recipeEndpointClass === 'responses') &&
    (recipeEndpointClass === 'chat_completions'
      ? false
      : recipeEndpointClass === 'responses'
        ? true
        : authoritativeResponsesTransport || reasoningProfile?.transport === "responses_api" ||
          imageGenProfile?.route === "responses_api" ||
          webSearchIsResponses);

  if (useResponsesAPI) {
    const body: Record<string, unknown> = {
      model: params.modelID,
      stream: params.stream !== false,
      input: buildOpenAIResponsesInput(params.messages),
    };

    // The official OpenAI Responses path deliberately does not set `reasoning.summary='auto'`.
    //
    // Observed with o4-mini and `reasoning:{effort:'medium', summary:'auto'}`:
    //   HTTP 400 "Your organization must be verified to generate reasoning summaries"
    // The same request without summary returns 200. Most individual BYOK users are on an
    // unverified organization, so always sending summary would make OpenAI reasoning tiers
    // unusable for nearly all of them.
    //
    // The cost is explicit: summary is a precondition for `response.reasoning_summary_text.delta`
    // (parsed in `transport/strategies/openai-responses.ts` and `proxy-chunk-parser.ts`), so the
    // official Responses path emits no reasoning events and there is no reasoning summary stream.
    // A working request beats a summary that cannot be requested. While there is no content the
    // TypingIndicator still fills the gap, so the bubble is never empty - see isWaitingForResponse
    // in `components/chat/MessageBubble.tsx`.
    //
    // Organization verification cannot be probed from the client, so "inject only when verified"
    // is not possible; restoring summaries needs a new official recipe plus an explicit
    // rejection-recovery semantic.
    // Relay custom endpoints are outside this rule (they target the user's own relay, not an
    // OpenAI organization) and keep summary in `transport/strategies/openai-responses.ts`.

    deepMerge(body, reasoningParams);
    deepMerge(body, imageGenProfile?.mergeParams);
    // Web search over Responses: inject the web_search server tool with tool_choice:"auto".
    if (webSearchIsResponses) {
      deepMerge(body, webSearchProfile?.mergeParams);
    }
    applyGenerationParameters(
      body,
      params.options?.generationParameters,
      params.options?.generationProfile,
      { toolsActive: Boolean(params.tools?.length) },
    );

    const fallbackProfileName = reasoningProfile?.fallbackProfile;
    const fallbackReasoningParams = fallbackProfileName
      ? resolveReasoningParams(
          metadata,
          fallbackProfileName,
          params.options?.reasoning,
        )
      : null;

    const headers = {
      ...STREAM_HEADERS,
      Authorization: `Bearer ${params.apiKey}`,
    };

    const primary: ProviderRequest = {
      url: `${baseURL}/responses`,
      headers,
      body,
    };

    if (!fallbackReasoningParams) {
      return primary;
    }

    const fallbackBody: Record<string, unknown> = {
      model: params.modelID,
      stream: params.stream !== false,
      ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
      messages: buildOpenAIChatMessages(params.messages),
    };
    deepMerge(fallbackBody, fallbackReasoningParams);
    applyGenerationParameters(
      fallbackBody,
      params.options?.generationParameters,
      params.options?.generationProfile,
      { toolsActive: Boolean(params.tools?.length) },
    );

    primary.fallback = {
      url: `${baseURL}/chat/completions`,
      headers,
      body: fallbackBody,
    };
    return primary;
  }

  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  deepMerge(body, reasoningParams);
  // Web search over Chat Completions (oai_web_tool, gpt-5-search-api only): inject the
  // web_search_preview tool. Responses-style web search is handled in the useResponsesAPI branch
  // above, so anything reaching here uses a chat schema profile.
  if (webSearchActive && !webSearchIsResponses) {
    deepMerge(body, webSearchProfile?.mergeParams);
  }
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
    { toolsActive: Boolean(params.tools?.length) },
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

/**
 * Whether a web-search profile uses the Responses API schema (tools[0].type === 'web_search').
 * oai_responses_web / grok_responses_web use Responses; oai_web_tool (web_search_preview) uses
 * Chat Completions.
 */
export function isResponsesWebSearchProfile(
  mergeParams: Record<string, unknown> | undefined,
): boolean {
  const tools = mergeParams?.tools;
  if (!Array.isArray(tools) || tools.length === 0) return false;
  const first = tools[0];
  return (
    typeof first === "object" &&
    first !== null &&
    (first as { type?: unknown }).type === "web_search"
  );
}
