/**
 * Mistral AI model sync, metadata-only mode.
 *
 * The model catalog comes from the backend metadata, and official providers do not validate the
 * upstream key. Chat uses the standard OpenAI Chat Completions shape; the content block array that
 * Magistral emits while thinking is handled by the shared, provider-agnostic content-block-parser,
 * which keeps this adapter thin.
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

/* -- Model Sync (deprecated compatibility shim) ----------------- */

/**
 * @deprecated The official provider catalog comes from metadata; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  baseURL: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy("mistral", apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildMistralSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds("mistral");
  return buildMistralSyncResult(metadataModelIds.map((id) => ({ id })));
}

function buildMistralSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "mistral");

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
    providerKind: 'mistral',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
  });
}
