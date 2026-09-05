/**
 * Anthropic adapter, metadata-only mode
 *
 * The model catalog comes from the metadata, and official providers do not validate the key upstream.
 *
 * Provider capability spec v2 section 5.2.8: stream parsing has moved to
 * `anthropicMessagesStrategy`, so this adapter only handles metadata-only key checks, building the
 * model catalog, and wrapping the auth header.
 */

import type { StreamHandle, StreamOptions, SyncResult, ContentPart } from '../types';
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
import { anthropicMessagesStrategy } from '../transport/strategies/anthropic-messages';
import { streamWithStrategy } from '../transport/adapter-helpers';

const API_VERSION = '2023-06-01';

function authHeaders(apiKey: string): Record<string, string> {
  return {
    'x-api-key': apiKey,
    'anthropic-version': API_VERSION,
    'anthropic-dangerous-direct-browser-access': 'true',
  };
}

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
    const json = await syncModelsProxy('anthropic', apiKey, baseURL) as {
      data?: RemoteModel[];
    };
    return buildAnthropicSyncResult(json.data ?? []);
  }

  await initMetadata().catch(() => {});
  const modelIds = listProviderModelIds('anthropic');
  return buildAnthropicSyncResult(modelIds.map((id) => ({ id })));
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
  return streamWithStrategy({
    strategy: anthropicMessagesStrategy,
    providerKind: 'anthropic',
    modelID,
    messages,
    baseURL,
    options,
    authHeaders: authHeaders(apiKey),
    webSearchProfileName,
  });
}

function buildAnthropicSyncResult(remoteModels: RemoteModel[]): SyncResult {
  const models = buildModelsFromCatalog(remoteModels, {}, 'anthropic');
  return {
    models,
    recommended: buildRecommendedModels(models),
  };
}
