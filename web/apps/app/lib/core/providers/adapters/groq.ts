/**
 * Groq model sync, metadata-only.
 *
 * The model catalog is authoritative in the backend metadata. Official providers do not validate
 * the key against upstream.
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

/* -- Model Sync (deprecated compatibility shim) ------------------- */

/**
 * @deprecated The catalog for an official provider is authoritative in metadata; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy("groq", apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildGroqSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("groq");
  return buildGroqSyncResult(metadataModelIds.map((id) => ({ id })));
}

function buildGroqSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "groq");

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
    providerKind: 'groq',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
  });
}
