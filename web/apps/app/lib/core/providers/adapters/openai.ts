/**
 * OpenAI adapter - metadata-only mode
 *
 * The model catalog comes from backend metadata. Official providers do not validate the upstream key.
 * Relay still needs the older API-based functions, exported as validateKeyDirect / syncModelsDirect.
 *
 * Dispatches to a Strategy by the metadata `model.transport`; when it is missing, fall back
 * conservatively to openai_chat rather than guessing from the modelID.
 *
 * The adapter still handles the Bearer auth header and the Direct API path used by Relay.
 *
 * Image generation is not wired into this direct fallback path: it always goes through the
 * route-driven authoritative path at /api/chat/stream, dispatched by the request builders.
 */

import type { AIModel } from '@oriveo/shared';
import type {
  OpenAIModelsResponse,
  OpenAIRemoteModel,
} from './openai-types';
import type { ContentPart, SyncResult, StreamHandle, StreamOptions } from '../types';
import { toProviderError, networkError } from '../errors';
import { buildCatalogModel, buildRecommendedModels } from '../catalog-model';
import {
  initMetadata,
  listProviderModelIds,
} from '../../metadata/metadata-client';
import {
  buildModelsFromCatalog,
  type RemoteModel,
} from './openai-compatible';
import { USE_PROXY, syncModelsProxy } from '../proxy-client';
import { openAIChatStrategy } from '../transport/strategies/openai-chat';
import { resolveStrategyByKindOrFallback } from '../transport/transport-registry';
import { resolveModelTransport } from '../transport/model-transport-resolver';
import { streamWithStrategy } from '../transport/adapter-helpers';

const DEFAULT_BASE = 'https://api.openai.com/v1';

/** Make sure the URL carries a scheme so the browser does not treat it as a relative path */
function normalizeBaseURL(url: string | undefined): string {
  if (!url) return DEFAULT_BASE;
  const trimmed = url.trim().replace(/\/+$/, '');
  if (!trimmed) return DEFAULT_BASE;
  if (!/^https?:\/\//i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

/* ── Key Validation (metadata-only) ─────────────────── */

export async function validateKey(apiKey: string): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error('Missing API key.');
  }
}

/* ── Model Sync (metadata-only) ─────────────────────── */

export async function syncModels(
  apiKey: string,
  baseURL?: string,
): Promise<SyncResult> {
  if (!apiKey.trim()) {
    throw new Error('Missing API key.');
  }
  if (USE_PROXY) {
    const json = await syncModelsProxy('openAI', apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildOpenAISyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const modelIds = listProviderModelIds('openAI');
  return buildOpenAISyncResult(modelIds.map((id) => ({ id })));
}

/* ── Direct API-based validation (used by Relay) ────────── */

/** Models to exclude (not chat models) - needed by the Relay direct API path */
const EXCLUDED_PREFIXES = [
  'whisper', 'tts', 'text-embedding', 'text-search',
  'text-similarity', 'code-search', 'babbage', 'davinci',
  'curie', 'ada', 'text-davinci', 'text-curie', 'text-babbage',
  'text-ada', 'moderation', 'canary',
];

export async function validateKeyDirect(apiKey: string, baseURL?: string): Promise<void> {
  const base = normalizeBaseURL(baseURL);
  let res: Response;
  try {
    res = await fetch(`${base}/models`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (err) {
    throw networkError(err);
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw toProviderError(res.status, body);
  }
}

export async function syncModelsDirect(
  apiKey: string,
  baseURL?: string,
): Promise<SyncResult> {
  const base = normalizeBaseURL(baseURL);

  let res: Response;
  try {
    res = await fetch(`${base}/models`, {
      headers: { Authorization: `Bearer ${apiKey}` },
    });
  } catch (err) {
    throw networkError(err);
  }

  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw toProviderError(res.status, body);
  }

  const data: OpenAIModelsResponse = await res.json();
  if (!data.data || data.data.length === 0) {
    return { models: [], recommended: [] };
  }

  const chatModels = data.data.filter((m) => {
    const id = m.id.toLowerCase();
    // heuristic-allow: Relay/custom OpenAI-compatible model-list filter only; official OpenAI catalog uses metadata.
    return !EXCLUDED_PREFIXES.some((p) => id.startsWith(p));
  });

  const models = chatModels.map(buildModelDirect);
  const recommended = buildRecommendedModels(models);
  return { models, recommended };
}

/* ── Streaming Chat ──────────────────────────────────── */

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
  baseURL?: string,
  options?: StreamOptions,
  webSearchProfileName?: string,
): StreamHandle {
  // Official production streaming goes through the request builders behind /api/chat/stream;
  // this direct adapter is only a fallback for non-proxy environments and tests. The
  // transport comes from metadata alone, falling back to openai_chat rather than guessing from the modelID.
  const transportKind = resolveModelTransport('openAI', modelID);
  const strategy = resolveStrategyByKindOrFallback(transportKind, openAIChatStrategy, {
    providerKind: 'openAI',
    modelID,
  });

  return streamWithStrategy({
    strategy,
    providerKind: 'openAI',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { Authorization: `Bearer ${apiKey}` },
    webSearchProfileName,
  });
}

/* ── Internal Helpers ──────────────────────────────────── */

function buildOpenAISyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, 'openAI');

  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}

/** Model builder for Direct API mode - used by Relay */
function buildModelDirect(remote: OpenAIRemoteModel): AIModel {
  return buildCatalogModel({
    providerKind: 'openAI',
    runtimeModelId: remote.id,
    fallbackName: remote.id,
    createdAt: remote.created,
  });
}
