/**
 * Bridge helper between an adapter and a transport strategy.
 *
 * It factors out "parse the stream with a strategy" so the five web-capable direct adapters
 * (anthropic, openai, gemini, grok, zhipu) can share it.
 *
 * The transport (fetch), getProviderTransport and getWebSearchProfile are injected through deps so
 * this module depends on neither a global fetch nor a metadata cache layer: a browser host injects
 * window.fetch plus the metadata client, a Node host injects an SSRF-guarded client plus a snapshot.
 */

import type { Provider, ProviderKind } from '@oriveo/shared/pure-types';
import type { TransportPort } from '../../ports';
import type { ProviderTransportDefinition, StreamShape } from '../../metadata/types';
import type { ContentPart, StreamEvent, StreamHandle, StreamOptions } from '../types';
import { createSSEFetchStream } from '../sse-parser';
import { resolveEndpoint, type GetProviderTransportFn } from './endpoint-resolver';
import { createStreamContext, type TransportStrategy } from './transport-strategy';
import { endpointKindForTransport } from './transport-kind';

/** webSearch profile lookup: returns mergeParams plus streamShape, or null when it is not enabled. */
export type GetWebSearchProfileFn = (
  name: string,
) => { mergeParams?: Record<string, unknown>; streamShape?: StreamShape | null } | null | undefined;

/** I/O is injected by the caller rather than depended on directly. */
export interface StreamWithStrategyDeps {
  /** The transport that actually performs the HTTP request. */
  transport: TransportPort;
  /** Metadata transport lookup, used by resolveEndpoint. */
  getProviderTransport: GetProviderTransportFn;
  /** webSearch profile lookup. */
  getWebSearchProfile: GetWebSearchProfileFn;
}

export interface StreamWithStrategyParams {
  /** The selected strategy, as returned by getStrategyByKind. */
  strategy: TransportStrategy;
  /** Provider kind, used by resolveEndpoint. */
  providerKind: ProviderKind | string;
  modelID: string;
  messages: {
    role: 'user' | 'assistant' | 'system';
    content: string | ContentPart[];
  }[];
  /** User-configured baseURL; when omitted, metadata and the built-in fallback are used. */
  baseURL?: string;
  options?: StreamOptions;
  /** Auth headers each adapter builds itself, keeping the strategy decoupled from auth. */
  authHeaders: Record<string, string>;
  /** webSearch profile name; when enabled its mergeParams are injected into the request body. */
  webSearchProfileName?: string;
  /** Custom metadata transport, for manually constructed definitions; otherwise looked up automatically. */
  metadataOverride?: ProviderTransportDefinition | null;
  /**
   * Provider-specific body fields, deep-merged into the body alongside webSearch.mergeParams.
   * Used for non-generic fields such as SiliconFlow's enable_thinking and thinking_budget.
   */
  extraBodyParams?: Record<string, unknown>;
}

/**
 * Run one streaming request through a strategy:
 *   - resolveEndpoint supplies the URL, including {model} placeholder substitution
 *   - profile.mergeParams is injected into the request body
 *   - strategy.parseStreamChunk parses the SSE stream
 *   - ctx.citations accumulates inside the strategy, and readStream emits the 'citations' event
 */
export function streamWithStrategy(
  params: StreamWithStrategyParams,
  deps: StreamWithStrategyDeps,
): StreamHandle {
  const {
    strategy,
    providerKind,
    modelID,
    messages,
    baseURL,
    options,
    authHeaders,
    webSearchProfileName,
    metadataOverride,
    extraBodyParams,
  } = params;

  const controller = new AbortController();
  const ctx = createStreamContext(String(providerKind));

  const providerStub: Provider = {
    id: providerKind as string,
    kind: providerKind as ProviderKind,
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: '',
    apiKeyPreview: '',
    baseURLText: baseURL,
  };

  // openai_chat maps to '/v1/chat/completions' and openai_responses to '/v1/responses'; every other
  // streaming kind still uses 'chat' (anthropic_messages, gemini_generate, dashscope_native).
  const endpointKind = endpointKindForTransport(strategy.kind);
  const url = resolveEndpoint(
    providerStub,
    providerKind,
    endpointKind,
    {
      metadataOverride: metadataOverride ?? deps.getProviderTransport(providerKind),
      modelID,
    },
    deps.getProviderTransport,
  );

  // Both mergeParams and streamShape for the webSearch profile come from here.
  const profile = webSearchProfileName && options?.supportsWebSearch
    ? deps.getWebSearchProfile(webSearchProfileName)
    : null;
  // Provider-specific fields (such as SiliconFlow's enable_thinking) merged with the webSearch profile's mergeParams.
  const mergeParams: Record<string, unknown> = {
    ...(extraBodyParams ?? {}),
    ...(profile?.mergeParams ?? {}),
  };
  const shape: StreamShape | null = profile?.streamShape ?? null;

  const body = strategy.buildRequestBody({
    providerKind: String(providerKind),
    modelID,
    messages,
    options,
    mergeParams,
  });

  const parseChunk = (eventType: string | null, data: string): StreamEvent | StreamEvent[] | null => {
    return strategy.parseStreamChunk(eventType, data, ctx, shape);
  };

  const stream = createSSEFetchStream(
    url,
    { headers: authHeaders, body: JSON.stringify(body) },
    parseChunk,
    { signal: controller.signal, transport: deps.transport },
  );

  return { stream, abort: () => controller.abort() };
}
