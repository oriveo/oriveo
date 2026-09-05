/**
 * SiliconFlow adapter
 *
 * Catalog truth for official providers comes from the bundled catalog. SiliconFlow is an aggregate
 * provider, so vendor/group must come from the catalog `vendorKey/vendorName` and `groupKey/groupName`
 * fields; the client must not guess the vendor from a model id slug (`Qwen/...`, `deepseek-ai/...`).
 *
 * Image generation is not wired into this direct fallback path; it goes through the route-driven path /api/chat/stream (dispatched by request-builders).
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

/* ── Key Validation ─────────────────────────────────── */

export async function validateKey(
  apiKey: string,
  _baseURL: string,
): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
}

/* ── Model Sync (deprecated compatibility shim) ─────────────────── */

/**
 * @deprecated Catalog truth for official providers comes from the bundled catalog; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy("siliconFlow", apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildSiliconFlowSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("siliconFlow");
  return buildSiliconFlowSyncResult(metadataModelIds.map((id) => ({ id })));
}

function buildSiliconFlowSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "siliconFlow");
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: {
    role: 'user' | 'assistant' | 'system';
    content: string | ContentPart[];
  }[],
  baseURL?: string,
  options?: StreamOptions,
): StreamHandle {
  // Official production streaming goes through the request-builders behind /api/chat/stream, where the
  // catalog reasoning profile injects enable_thinking/thinking_budget. This direct adapter is only a
  // fallback for non-proxy environments and tests, and carries no local level mapping.
  void options;

  return streamWithStrategy({
    strategy: openAIChatStrategy,
    providerKind: 'siliconFlow',
    modelID,
    messages,
    baseURL,
    options: undefined,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
  });
}
