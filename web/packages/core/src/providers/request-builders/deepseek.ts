// DeepSeek request builder - OpenAI compatible, but non-text parts are flattened to placeholder text
import { resolveProviderBaseURL } from "../url-utils";
import { deepMerge, type ProxyMessage } from "./runtime";
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { applyGenerationParameters } from './generation-parameters';

export function buildDeepSeekRequest(
  params: RequestParams,
  reasoningParams: Record<string, unknown> | null,
  includeUsage: boolean,
): ProviderRequest {
  const body: Record<string, unknown> = {
    model: params.modelID,
    stream: params.stream !== false,
    messages: buildDeepSeekMessages(params.messages),
  };
  if (includeUsage) {
    body.stream_options = { include_usage: true };
  }

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
      Authorization: `Bearer ${params.apiKey}`,
    },
    body,
  };
}

export function buildDeepSeekMessages(messages: ProxyMessage[]) {
  return messages.map((message) => ({
    role: message.role,
    content: typeof message.content === "string"
      ? message.content
      : message.content
        .map((part) => {
          if (part.type === "text") {
            return part.text;
          }
          if (part.type === "image_url") {
            return "[Image omitted: unsupported by DeepSeek]";
          }
          if (part.type === "video_url") {
            return "[Video omitted: unsupported by DeepSeek]";
          }
          return `[File omitted: ${part.file.filename}]`;
        })
        .join("\n\n"),
  }));
}
