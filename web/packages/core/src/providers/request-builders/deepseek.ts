// DeepSeek request builder - OpenAI compatible: images go out as image_url, videos / files are flattened to placeholder text
import { resolveProviderBaseURL } from "../url-utils";
import { deepMerge, type ProxyMessage } from "./runtime";
import { STREAM_HEADERS, type ProviderRequest, type RequestParams } from "./types";
import { applyGenerationParameters } from './generation-parameters';
import { attachmentTransportProfile } from "../attachment-transport";

const DEEPSEEK_PROFILE = attachmentTransportProfile("deepseek_chat");

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
      : buildDeepSeekContent(message.content),
  }));
}

/**
 * Images go out as OpenAI Chat `image_url`: every image part that reaches here was judged outbound-capable by the projection (the ones that cannot go out were already replaced with a placeholder line by the outbound sanitizer).
 * With no images the plain-text shape is kept; DeepSeek accepts neither video nor files, which are still written as placeholder text.
 */
function buildDeepSeekContent(parts: Exclude<ProxyMessage["content"], string>) {
  const textOf = (part: (typeof parts)[number]): string => {
    if (part.type === "text") return part.text;
    if (part.type === "video_url") return DEEPSEEK_PROFILE.videoPlaceholderText ?? "";
    if (part.type === "file") return (DEEPSEEK_PROFILE.filePlaceholderText ?? "").replace("{filename}", () => part.file.filename);
    return "";
  };
  if (!parts.some((part) => part.type === "image_url")) {
    return parts.map(textOf).join("\n\n");
  }
  return parts.map((part) => part.type === "image_url"
    ? { type: "image_url" as const, image_url: { url: part.image_url.url } }
    : { type: "text" as const, text: textOf(part) });
}
