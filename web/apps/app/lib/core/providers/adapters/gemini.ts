/**
 * Gemini adapter -- metadata-only mode.
 *
 * The model catalog comes from the backend metadata, and official providers do not validate the
 * upstream key.
 *
 * Stream parsing goes through `geminiGenerateStrategy`; the adapter keeps only the metadata-only
 * key check, the model catalog build and the x-goog-api-key header. The endpoint template
 * `/v1beta/models/{model}:streamGenerateContent?alt=sse` is resolved by EndpointResolver, so the
 * adapter does not assemble paths itself.
 */

import type { ContentPart, SyncResult, StreamHandle, StreamOptions } from '../types';
import { buildRecommendedModels } from '../catalog-model';
import {
  initMetadata,
  listProviderModelIds,
} from '../../metadata/metadata-client';
import {
  buildModelsFromCatalog,
  type RemoteModel,
} from './openai-compatible';
import { USE_PROXY, syncModelsProxy } from '../proxy-client';
import { geminiGenerateStrategy } from '../transport/strategies/gemini-generate';
import { streamWithStrategy } from '../transport/adapter-helpers';

/* ── Key Validation (metadata-only) ─────────────────── */

export async function validateKey(apiKey: string, _baseURL?: string): Promise<void> {
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
    const json = await syncModelsProxy('gemini', apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildGeminiSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const modelIds = listProviderModelIds('gemini');
  return buildGeminiSyncResult(modelIds.map((id) => ({ id })));
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
  // The API key must travel in the `x-goog-api-key` header and never in the URL query: URLs end
  // up in Sentry and in any outgoing fetch log, which would leak the BYOK key.
  return streamWithStrategy({
    strategy: geminiGenerateStrategy,
    providerKind: 'gemini',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: { 'x-goog-api-key': apiKey },
    webSearchProfileName,
  });
}

/* ── Internal Helpers ──────────────────────────────────── */

function buildGeminiSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, 'gemini');
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}
