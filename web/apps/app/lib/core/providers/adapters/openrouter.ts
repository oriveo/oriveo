/**
 * OpenRouter adapter - metadata-only mode
 *
 * The model catalog comes from backend metadata. Official providers do not validate the upstream key.
 * OpenRouter also requires the HTTP-Referer / X-Title common headers.
 */

import type { AIModel } from '@oriveo/shared';
import type {
  OpenRouterChatRequest,
  OpenRouterStreamChunk,
  ContentPartResponse,
} from './openrouter-types';
import type { StreamEvent, ContentPart, SyncResult, StreamHandle, StreamOptions } from '../types';
import { deduplicateByCanonical } from '../catalog-model';
import { createSSEFetchStream } from '../../../infra/sse-parser';
import { buildRecommendedModels } from '../catalog-model';
import {
  getWebSearchProfile,
  initMetadata,
  listProviderModelIds,
} from '../../metadata/metadata-client';
import { USE_PROXY, syncModelsProxy } from '../proxy-client';
import { buildModelsFromCatalog, type RemoteModel } from './openai-compatible';
import { citationFromRaw, mergeCitation } from '../transport/citation-utils';
import { deepMerge } from '../transport/merge-utils';
import { parseUsageOpenRouter } from '../transport/usage-parsers';

const BASE_URL = 'https://openrouter.ai/api/v1';

/** Common headers OpenRouter requires */
function commonHeaders(apiKey: string): Record<string, string> {
  return {
    Authorization: `Bearer ${apiKey}`,
    'HTTP-Referer': 'https://github.com/oriveo/oriveo',
    'X-Title': 'Oriveo',
  };
}

/* ── Key Validation (metadata-only) ─────────────────── */

export async function validateKey(apiKey: string): Promise<void> {
  if (!apiKey.trim()) {
    throw new Error('Missing API key.');
  }
}

/* ── Model Sync (metadata-only) ─────────────────────── */

export type { SyncResult } from '../types';

/**
 * @deprecated Official provider catalogs come from metadata; use `buildOfficialEnabledModels`.
 */
export async function syncModels(
  apiKey: string,
  preferredModelID?: string,
): Promise<SyncResult> {
  if (USE_PROXY) {
    const json = await syncModelsProxy('openRouter', apiKey) as {
      data?: RemoteModel[];
    };
    return buildOpenRouterSyncResult(json.data ?? [], preferredModelID);
  }

  await initMetadata().catch(() => {});
  const metadataModelIds = listProviderModelIds('openRouter');
  return buildOpenRouterSyncResult(metadataModelIds.map((id) => ({ id })), preferredModelID);
}

/* ── Streaming Chat ──────────────────────────────────── */

export type { StreamHandle } from '../types';

export function sendMessageStream(
  apiKey: string,
  modelID: string,
  messages: { role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[],
  options?: StreamOptions,
  supportsImageGen?: boolean,
  webSearchProfileName?: string,
): StreamHandle {
  const controller = new AbortController();

  const body: OpenRouterChatRequest & Record<string, unknown> = {
    model: modelID,
    stream: true,
    stream_options: { include_usage: true },
    messages,
  };
  void supportsImageGen;
  void options;

  // Official production streaming goes through the request builders behind /api/chat/stream,
  // which inject reasoning from the metadata reasoning profile. This direct adapter is only a
  // fallback for non-proxy environments and tests, and maps no tiers locally.
  // mergeParams is passed through as-is without picking keys: or_web moved from a server
  // tool (tools) to a web plugin (plugins), and an implementation that only recognized
  // `mergeParams.tools` would silently stop searching the web the moment the profile
  // changed, with no error and no log.
  if (webSearchProfileName) {
    const profile = getWebSearchProfile(webSearchProfileName);
    if (profile?.mergeParams) {
      deepMerge(body as Record<string, unknown>, profile.mergeParams as Record<string, unknown>);
    }
  }

  const citations: NonNullable<Extract<StreamEvent, { type: 'citations' }>['citations']> = [];

  const parseChunk = (_eventType: string | null, data: string): StreamEvent | StreamEvent[] | null => {
    const chunk: OpenRouterStreamChunk = JSON.parse(data);
    const events: StreamEvent[] = [];

    if (chunk.model) {
      events.push({ type: 'model', modelID: chunk.model });
    }
    // Inject the cost breakdown. OpenRouter's `usage.cost` already includes every cache
    // discount and goes to upstreamCost; `prompt_tokens_details.cache_write_tokens` is
    // counted as the 1h cache. Downstream, deriveCostFields falls back to estimateCost when
    // there is no breakdown, which loses the upstream cost field.
    if (chunk.usage) {
      events.push({
        type: 'usage',
        usage: {
          ...chunk.usage,
          breakdown: parseUsageOpenRouter(chunk.usage as Record<string, unknown>),
        },
      });
    }
    const choice = chunk.choices?.[0];
    // OpenRouter normalizes reasoning content from every upstream model (DeepSeek, Qwen,
    // GLM, Grok, Gemini, GPT and others) into delta.reasoning as plain string increments,
    // interleaved with the body content, so the two are emitted separately.
    // Some OpenAI-compatible services use reasoning_content instead, so check both.
    const reasoning =
      choice?.delta?.reasoning_content
      ?? choice?.delta?.reasoning
      ?? choice?.message?.reasoning_content
      ?? choice?.message?.reasoning;
    if (reasoning) {
      events.push({ type: 'reasoning', content: reasoning });
    }
    // Extract text content: prefer delta, fall back to message
    const content = choice?.delta?.content ?? choice?.message?.content;
    if (content) {
      extractContentEvents(content, events);
    }
    // Extract images: delta.images or message.images
    const images = choice?.delta?.images ?? choice?.message?.images;
    if (images) {
      for (const img of images) {
        if (img.image_url?.url) events.push({ type: 'image', url: img.image_url.url });
      }
    }
    // The OpenRouter web plugin searches before answering: all annotations arrive in the
    // first frame of the stream and are surfaced immediately, keeping the display order
    // reasoning -> body -> sources.
    emitAnnotationCitations(choice?.delta?.annotations, citations);
    emitAnnotationCitations(choice?.message?.annotations, citations);

    return events.length > 0 ? events : null;
  };

  const stream = createSSEFetchStream(
    `${BASE_URL}/chat/completions`,
    {
      headers: {
        ...commonHeaders(apiKey),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    },
    parseChunk,
    { signal: controller.signal },
  ).pipeThrough(
    new TransformStream<StreamEvent, StreamEvent>({
      flush(ctrl) {
        if (citations.length > 0) {
          ctrl.enqueue({ type: 'citations', citations: citations.slice() });
        }
      },
    }),
  );

  return { stream, abort: () => controller.abort() };
}

function emitAnnotationCitations(
  annotations: unknown,
  citations: NonNullable<Extract<StreamEvent, { type: 'citations' }>['citations']>,
): boolean {
  if (!Array.isArray(annotations)) return false;
  let changed = false;
  for (const raw of annotations) {
    if (!raw || typeof raw !== 'object') continue;
    const item = raw as Record<string, unknown>;
    const citation = item.type === 'url_citation' && item.url_citation && typeof item.url_citation === 'object'
      ? citationFromRaw(item.url_citation, null, {
        urlField: 'url',
        titleField: 'title',
        snippetField: 'snippet',
      })
      : citationFromRaw(item, null, {
        urlField: 'url',
        titleField: 'title',
        snippetField: 'snippet',
      });
    if (mergeCitation(citations, citation)) changed = true;
  }
  return changed;
}

/* ── Helpers: Stream content processing ──────────────── */

/** Convert content (a string or an array of content parts) into a list of StreamEvents */
function extractContentEvents(
  content: string | ContentPartResponse[],
  events: StreamEvent[],
): void {
  if (typeof content === 'string') {
    if (content) events.push({ type: 'delta', content });
  } else if (Array.isArray(content)) {
    for (const part of content) {
      if (part.type === 'text' && part.text) {
        events.push({ type: 'delta', content: part.text });
      } else if (part.type === 'image_url' && part.image_url?.url) {
        events.push({ type: 'image', url: part.image_url.url });
      }
    }
  }
}

/* ── Internal Helpers ──────────────────────────────────── */

function buildOpenRouterSyncResult(
  remoteModels: RemoteModel[],
  preferredModelID?: string,
): SyncResult {
  const models = deduplicateByCanonical(
    buildModelsFromCatalog(remoteModels, {}, 'openRouter'),
  );
  const recommended = buildRecommended(models, preferredModelID);

  return { models, recommended };
}

function buildRecommended(models: AIModel[], preferredModelID?: string): AIModel[] {
  const recommended = buildRecommendedModels(models);
  if (!preferredModelID) {
    return recommended;
  }

  const preferred = models.find((model) => model.id === preferredModelID);
  if (!preferred || recommended.find((model) => model.id === preferredModelID)) {
    return recommended;
  }

  return [preferred, ...recommended].slice(0, 6);
}
