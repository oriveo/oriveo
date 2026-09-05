/* ── Provider-agnostic types (re-exported from types.ts) ── */

export type { ContentPart, StreamEvent, StreamUsage } from "../types";
// Backwards compatible alias.
export type { StreamUsage as OpenRouterUsage } from "../types";

/* ── OpenRouter API types ─────────────────────────────── */

import type { ContentPart } from "../types";
import type { StreamUsage } from "../types";

/** Chat completion request */
export interface OpenRouterChatRequest {
  model: string;
  stream?: boolean;
  stream_options?: { include_usage: boolean };
  max_tokens?: number;
  messages: OpenRouterMessage[];
  modalities?: string[];
  reasoning?: { effort: string };
  tools?: Array<{ type: string }>;
}

export interface OpenRouterMessage {
  role: "user" | "assistant" | "system";
  content: string | ContentPart[];
}

/** Content part in a streaming response (image generation models) */
export interface ContentPartResponse {
  type: string;
  text?: string;
  image_url?: { url: string };
}

/** SSE chunk from streaming chat completions */
export interface OpenRouterStreamChunk {
  id?: string;
  model?: string;
  choices?: {
    index: number;
    delta?: {
      role?: string;
      content?: string | ContentPartResponse[];
      // OpenRouter normalizes reasoning content from every upstream model into delta.reasoning as
      // a plain string increment; some OpenAI-compatible services use reasoning_content instead,
      // so both are checked.
      reasoning?: string;
      reasoning_content?: string;
      annotations?: Array<Record<string, unknown>>;
      images?: ContentPartResponse[];
    };
    /** Image generation models may return a complete message rather than a delta in a single SSE event. */
    message?: {
      role?: string;
      content?: string | ContentPartResponse[];
      reasoning?: string;
      reasoning_content?: string;
      annotations?: Array<Record<string, unknown>>;
      images?: ContentPartResponse[];
    };
    finish_reason?: string | null;
  }[];
  usage?: StreamUsage;
}

/* --- Vendor name mapping -------------------------------------- */

const VENDOR_NAMES: Record<string, string> = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  google: "Google",
  meta: "Meta",
  "meta-llama": "Meta",
  mistralai: "Mistral",
  deepseek: "DeepSeek",
  cohere: "Cohere",
  "x-ai": "xAI",
  qwen: "Qwen",
  "deepseek-ai": "DeepSeek",
  zai: "Z.ai / GLM",
  "z-ai": "Z.ai / GLM",
  "zai-org": "Z.ai / GLM",
  thudm: "Z.ai / GLM",
  stepfun: "StepFun",
  "stepfun-ai": "StepFun",
  tencent: "Tencent",
  "kwai-kolors": "Kwai",
  "nex-agi": "NEX",
  nvidia: "NVIDIA",
  perplexity: "Perplexity",
  moonshotai: "Moonshot AI",
  microsoft: "Microsoft",
  "bytedance-seed": "ByteDance Seed",
};

export function vendorInfo(modelId: string): {
  groupKey: string;
  groupName: string;
  modelName: string;
} {
  const slash = modelId.indexOf("/");
  if (slash === -1)
    return { groupKey: modelId, groupName: modelId, modelName: modelId };
  let rawGroupKey = modelId.slice(0, slash);
  let groupKey = rawGroupKey.toLowerCase();
  let modelName = modelId.slice(slash + 1);
  // The "Pro/" prefix is a SiliconFlow pricing tier, so the second segment is the real vendor.
  if (groupKey === "pro" && modelName.includes("/")) {
    rawGroupKey = modelName.slice(0, modelName.indexOf("/"));
    groupKey = rawGroupKey.toLowerCase();
    modelName = modelName.slice(modelName.indexOf("/") + 1);
  }
  // Normalize SiliconFlow aliases (thudm -> zai-org).
  if (groupKey === "thudm" || groupKey === "zai" || groupKey === "z-ai") {
    groupKey = "zai-org";
  }
  return {
    groupKey,
    groupName: VENDOR_NAMES[groupKey] ?? humanizeVendorName(rawGroupKey),
    modelName,
  };
}

function humanizeVendorName(groupKey: string): string {
  return groupKey
    .replace(/-/g, " ")
    .split(" ")
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ");
}
