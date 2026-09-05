// Gemini request builder — generateContent streamGenerateContent SSE
import { resolveProviderBaseURL } from "../url-utils";
import { buildGeminiRequestPayload, deepMerge } from "./runtime";
import { JSON_HEADERS, STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { applyGenerationParameters, credentialHeader } from './generation-parameters';

export function buildGeminiRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  webSearchProfile: { mergeParams?: Record<string, unknown> } | null,
  imageGenProfile: {
    route?: string;
    mergeParams?: Record<string, unknown>;
  } | null,
): ProviderRequest {
  const stream = params.stream !== false;
  const payload = buildGeminiRequestPayload(params.messages);
  const body: Record<string, unknown> = {
    contents: payload.contents,
  };

  if (payload.systemInstruction) {
    body.systemInstruction = payload.systemInstruction;
  }

  // Web search: inject the google_search tool into the generateContent tools array. deepMerge
  // copies arrays, so contents is left intact.
  if (params.options?.supportsWebSearch) {
    deepMerge(body, webSearchProfile?.mergeParams);
  }
  if (imageGenProfile?.route === "chat_api") {
    deepMerge(body, imageGenProfile.mergeParams);
  }
  deepMerge(body, reasoningParams);
  applyGenerationParameters(
    body,
    params.options?.generationParameters,
    params.options?.generationProfile,
    { toolsActive: Boolean(params.tools?.length) },
  );

  return {
    // The API key must travel in the `x-goog-api-key` header and must never be appended to the
    // URL query: the Sentry HTTP integration records the URL of a server-side fetch as a span
    // attribute, and no default PII scrubber masks a `key=` query parameter, which would leak the
    // BYOK key into Sentry.
    url: stream
      ? `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/models/${params.modelID}:streamGenerateContent?alt=sse`
      : `${resolveProviderBaseURL(params.providerKind, params.baseURL)}/models/${params.modelID}:generateContent`,
    headers: { ...(stream ? STREAM_HEADERS : JSON_HEADERS), ...credentialHeader('x-goog-api-key', params.apiKey) },
    body,
  };
}
