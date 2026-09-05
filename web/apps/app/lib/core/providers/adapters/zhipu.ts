/**
 * Zhipu adapter.
 *
 * The catalog truth for official providers comes from backend metadata, including Zhipu's image
 * generation models (cogview / glm-image), so nothing is hard-coded in the client.
 *
 * Stream parsing uses `openAIChatStrategy`, since the Zhipu Chat API protocol is structurally the
 * same. Web Search lands through the webSearch profile from metadata (mergeParams + streamShape,
 * with the custom `link` field and the
 * `choices.0.delta.tool_calls.0.web_search.search_result` path).
 *
 * Image generation is not wired into this direct-connection fallback path - it goes through the
 * authoritative route /api/chat/stream, dispatched by request-builders.
 */

import { buildRecommendedModels } from "../catalog-model";
import {
  initMetadata,
  listProviderModelIds,
} from "../../metadata/metadata-client";
import {
  buildModelsFromCatalog,
  type RemoteModel,
} from "./openai-compatible";
import { USE_PROXY, syncModelsProxy } from "../proxy-client";
import { openAIChatStrategy } from "../transport/strategies/openai-chat";
import { streamWithStrategy } from "../transport/adapter-helpers";
import type { ContentPart, StreamHandle, StreamOptions, SyncResult } from '../types';

/* -- Key Validation ------------------------------------------------------ */

export async function validateKey(
  apiKey: string,
  _baseURL: string,
): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
}

/* -- Model Sync (deprecated compatibility shim) --------------------------- */

/**
 * @deprecated The catalog truth for official providers comes from metadata; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy("zhipu", apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildZhipuSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("zhipu");
  return buildZhipuSyncResult(metadataModelIds.map((id) => ({ id })));
}

/* -- Streaming Chat ------------------------------------------------------- */

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
  baseURL?: string,
  options?: StreamOptions,
  webSearchProfileName?: string,
): StreamHandle {
  return streamWithStrategy({
    strategy: openAIChatStrategy,
    providerKind: "zhipu",
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
    webSearchProfileName,
  });
}

function buildZhipuSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "zhipu");
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}
