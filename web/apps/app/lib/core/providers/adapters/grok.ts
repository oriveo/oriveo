/**
 * Grok (xAI) adapter — metadata-only sync, OpenAI chat-completions compatible.
 *
 * Dispatches on `model.transport`: grok-4.1 / 4.3 / 4-fast use `openai_responses` (the xAI Agent
 * Tools API), while grok-3 and grok-2 stay on `openai_chat`. The adapter keeps the Bearer auth
 * header; reasoning_effort and the web_search tool are injected by each strategy from options.
 *
 * Image generation is not wired into this direct fallback path: it always goes through the
 * route-driven authoritative path /api/chat/stream, dispatched by the request builders.
 */

import { buildRecommendedModels } from "../catalog-model";
import {
  initMetadata,
  listProviderModelIds,
  refreshMetadata,
} from "../../metadata/metadata-client";
import {
  buildModelsFromCatalog,
  type RemoteModel,
} from "./openai-compatible";
import { USE_PROXY, syncModelsProxy } from "../proxy-client";
import { openAIChatStrategy } from "../transport/strategies/openai-chat";
import { resolveStrategyByKindOrFallback } from "../transport/transport-registry";
import { resolveModelTransport } from "../transport/model-transport-resolver";
import { streamWithStrategy } from "../transport/adapter-helpers";
import type {
  ContentPart,
  StreamHandle,
  StreamOptions,
  SyncResult,
} from "../types";

export async function validateKey(
  apiKey: string,
  _baseURL: string,
): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error("Missing API key.");
  }
}

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
    const json = (await syncModelsProxy("grok", apiKey, baseURL)) as {
      data?: RemoteModel[];
    };
    await refreshMetadata().catch(() => initMetadata().catch(() => {}));
    return buildGrokSyncResult(json.data ?? []);
  }

  await refreshMetadata().catch(() => initMetadata().catch(() => {}));
  const modelIds = listProviderModelIds("grok");
  return buildGrokSyncResult(modelIds.map((id) => ({ id })));
}

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: {
    role: "user" | "assistant" | "system";
    content: string | ContentPart[];
  }[],
  baseURL: string,
  options?: StreamOptions,
  webSearchProfileName?: string,
): StreamHandle {
  // Official production streaming goes through the request builders behind /api/chat/stream; this
  // direct adapter is only a fallback for non-proxied environments and tests. transport is read
  // from metadata only, defaulting conservatively to openai_chat rather than guessing from the
  // model id.
  const transportKind = resolveModelTransport("grok", modelID);
  const strategy = resolveStrategyByKindOrFallback(transportKind, openAIChatStrategy, {
    providerKind: "grok",
    modelID,
  });

  return streamWithStrategy({
    strategy,
    providerKind: "grok",
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
    webSearchProfileName,
  });
}

function buildGrokSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, "grok");
  return { models, recommended: buildRecommendedModels(models) };
}
