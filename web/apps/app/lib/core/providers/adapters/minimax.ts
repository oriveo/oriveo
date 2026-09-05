/**
 * MiniMax adapter
 *
 * The catalog for an official provider comes from the metadata, so this module keeps no local
 * catalog shaping such as `KNOWN_TEXT_MODEL_IDS`, `KNOWN_IMAGE_GEN_IDS` or `ensureImageModels`.
 *
 * Image generation is not wired into this direct fallback path; it goes through the authoritative
 * /api/chat/stream route, which dispatches to the request builders.
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

/* -- Model sync (deprecated compatibility shim) --------------------- */

/**
 * @deprecated The catalog for an official provider comes from the metadata; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy("miniMax", apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildMiniMaxSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("miniMax");
  return buildMiniMaxSyncResult(metadataModelIds.map((id) => ({ id })));
}

function buildMiniMaxSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "miniMax");
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
  return streamWithStrategy({
    strategy: openAIChatStrategy,
    providerKind: 'miniMax',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
  });
}
