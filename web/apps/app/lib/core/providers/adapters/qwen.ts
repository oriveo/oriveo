/**
 * Qwen adapter - DashScope native mode.
 *
 * Why native rather than the OpenAI-compatible mode:
 *   - the compatible mode cannot return structured search_info citations, and citations come first
 *   - the DashScope native mode exposes output.search_info.search_results[]
 *
 * Endpoint resolution: metadata value -> user-supplied baseURLText override -> built-in default
 *   `https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation`
 *
 * The model catalog truth comes from metadata; this adapter only handles:
 *   1. validateKey, a non-empty check
 *   2. syncModels, building catalog models from the metadata list
 *   3. sendMessageStream, through the DashScope native strategy (funnelled via adapter-helpers)
 *
 * Image generation is not wired into this direct-connection fallback path - it goes through the
 * authoritative route /api/chat/stream, dispatched by request-builders.
 */

import {
  buildModelsFromCatalog,
  type RemoteModel,
} from "./openai-compatible";
import { buildRecommendedModels } from "../catalog-model";
import {
  initMetadata,
  listProviderModelIds,
} from "../../metadata/metadata-client";
import { USE_PROXY, syncModelsProxy } from "../proxy-client";
import { dashscopeNativeStrategy } from "../transport/strategies/dashscope-native";
import { streamWithStrategy } from "../transport/adapter-helpers";
import type {
  ContentPart,
  StreamHandle,
  StreamOptions,
  SyncResult,
} from "../types";

/* -- Key Validation ------------------------------------------------------ */

export async function validateKey(
  apiKey: string,
  _baseURL?: string,
): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
}

/* -- Model Sync ----------------------------------------------------------- */

export async function syncModels(
  apiKey: string,
  baseURL?: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = (await syncModelsProxy("qwen", apiKey, baseURL)) as {
      data?: RemoteModel[];
    };
    return buildQwenSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("qwen");
  return buildQwenSyncResult(metadataModelIds.map((id) => ({ id })));
}

function buildQwenSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "qwen");
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}

/* -- Streaming Chat (DashScope native) ------------------------------------ */

/**
 * Starts a streaming chat in Qwen DashScope native mode.
 *
 * baseURL resolution has three levels, handled by EndpointResolver:
 *   1. provider.baseURLText, e.g. a self-hosted relay
 *   2. `providers.qwen.transport.{baseUrl, endpoints.chat}` from metadata
 *   3. the built-in fallback https://dashscope.aliyuncs.com + /api/v1/.../generation
 *
 * A webSearch profile such as `qwen_web` is injected through the mergeParams metadata carries.
 * DashScope native mode needs the `X-DashScope-SSE: enable` header to stream.
 */
export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: {
    role: 'user' | 'assistant' | 'system';
    content: string | ContentPart[];
  }[],
  baseURL?: string,
  options?: StreamOptions,
  webSearchProfileName?: string,
): StreamHandle {
  return streamWithStrategy({
    strategy: dashscopeNativeStrategy,
    providerKind: 'qwen',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: {
      Authorization: `Bearer ${apiKey}`,
      // DashScope native mode needs this header to stream.
      'X-DashScope-SSE': 'enable',
    },
    webSearchProfileName,
  });
}
