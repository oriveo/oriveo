// MiniMax request builder - OpenAI compatible for chat, with a dedicated /image_generation endpoint for images
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

export function buildMiniMaxRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  imageGenProfile: { route?: string; requestDefaults?: Record<string, unknown> } | null,
): ProviderRequest {
  const baseURL = resolveProviderBaseURL(params.providerKind, params.baseURL);

  // Image generation goes to the MiniMax-specific /v1/image_generation endpoint.
  // The route token is the single value minimax_image_generation; this heterogeneous wire is listed
  // separately so the generic images_api executor does not pick it up by mistake.
  if (imageGenProfile?.route === "minimax_image_generation") {
    const prompt = extractLatestUserPrompt(params.messages);
    if (!prompt) {
      throw new Error("Image generation requires a text prompt");
    }

    return {
      url: `${baseURL}/image_generation`,
      headers: {
        ...JSON_HEADERS,
        Authorization: `Bearer ${params.apiKey}`,
      },
      body: {
        response_format: "base64",
        n: 1,
        ...imageGenProfile.requestDefaults,
        model: params.modelID,
        prompt,
      },
      responseAdapter: "minimax_images_api",
    };
  }

  // Chat: standard OpenAI-compatible format
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    ...(params.stream !== false ? { stream_options: { include_usage: true } } : {}),
    messages: buildOpenAIChatMessages(params.messages),
  };

  deepMerge(body, reasoningParams);
  // MiniMax OpenAI fallback separates opaque reasoning only when this flag is
  // present. Keep it builder-owned so every stream/non-stream chat request uses
  // the same parser/replay shape; image generation never reaches this branch.
  body.reasoning_split = true;
  // Injected on the chat branch only: /image_generation is a heterogeneous endpoint and rejects chat sampling parameters
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
    responseAdapter: "minimax_chat_stream",
  };
}
