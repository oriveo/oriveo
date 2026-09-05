/**
 * Three-level endpoint resolution.
 *
 * Priority, highest first:
 *   1. User configuration `provider.baseURLText` (self-hosted proxy, Azure, regional relay)
 *   2. `providers.{kind}.transport.{baseUrl, endpoints}` from metadata
 *   3. Built-in fallback table (client safety net)
 *
 * The metadata lookup is injected as getProviderTransport so this module stays decoupled from any
 * particular cache layer. ProviderTransportDefinition/TransportEndpoints come from
 * @oriveo/core/metadata/types.
 */

import type { Provider, ProviderKind } from '@oriveo/shared/pure-types';
import type { ProviderTransportDefinition, TransportEndpoints } from '../../metadata/types';
import type { EndpointKind } from './transport-kind';

/** Look up the transport definition for a providerKind; returns undefined when metadata has none. */
export type GetProviderTransportFn = (
  providerKind: ProviderKind | string,
) => ProviderTransportDefinition | undefined;

export type MetadataBaseURLRejectionReporter = (event: {
  providerKind: string;
  baseUrl: string;
  reason: 'invalid_url' | 'non_https' | 'host_not_allowed';
}) => void;

/* ── Built-in fallback table ─────────────────────────────── */

/**
 * Built-in default baseURL per provider, used as the last resort when neither metadata nor the user
 * supplies one.
 */
const DEFAULT_BASE_URLS: Partial<Record<ProviderKind, string>> = {
  openAI: 'https://api.openai.com',
  anthropic: 'https://api.anthropic.com',
  gemini: 'https://generativelanguage.googleapis.com',
  openRouter: 'https://openrouter.ai/api',
  grok: 'https://api.x.ai',
  deepseek: 'https://api.deepseek.com',
  mistral: 'https://api.mistral.ai',
  groq: 'https://api.groq.com/openai',
  togetherAI: 'https://api.together.xyz',
  fireworksAI: 'https://api.fireworks.ai/inference',
  miniMax: 'https://api.minimax.io',
  zhipu: 'https://open.bigmodel.cn/api/paas',
  qwen: 'https://dashscope.aliyuncs.com',
  siliconFlow: 'https://api.siliconflow.cn',
  moonshot: 'https://api.moonshot.ai',
};

/**
 * Default path per provider and endpoint kind.
 * The Gemini chat path's `:streamGenerateContent` suffix is assembled by its adapter, not here.
 */
const DEFAULT_ENDPOINTS: Partial<Record<ProviderKind, TransportEndpoints>> = {
  openAI: {
    chat: '/v1/chat/completions',
    responses: '/v1/responses',
    images: '/v1/images/generations',
    files: '/v1/files',
  },
  anthropic: {
    chat: '/v1/messages',
    files: '/v1/files',
  },
  gemini: {
    // The Gemini chat endpoint uses a {model} placeholder template.
    chat: '/v1beta/models/{model}:streamGenerateContent?alt=sse',
  },
  openRouter: {
    chat: '/v1/chat/completions',
  },
  grok: {
    chat: '/v1/chat/completions',
    responses: '/v1/responses',
    images: '/v1/images/generations',
  },
  deepseek: {
    chat: '/v1/chat/completions',
  },
  mistral: {
    chat: '/v1/chat/completions',
  },
  groq: {
    chat: '/v1/chat/completions',
  },
  togetherAI: {
    chat: '/v1/chat/completions',
  },
  fireworksAI: {
    chat: '/v1/chat/completions',
  },
  miniMax: {
    // OpenAI-compatible endpoint. /v1/text/chatcompletion_v2 is MiniMax's native protocol endpoint and
    // does not accept an OpenAI-compatible body, so sending there always fails.
    chat: '/v1/chat/completions',
    // Image generation uses MiniMax's own endpoint; the OpenAI-shaped /v1/images/generations does not
    // exist there.
    images: '/v1/image_generation',
  },
  zhipu: {
    chat: '/v4/chat/completions',
  },
  qwen: {
    // OpenAI-compatible endpoint; it is the only one the qwen3.x models are reachable through, and the
    // native text-generation/generation path is deprecated.
    chat: '/compatible-mode/v1/chat/completions',
  },
  siliconFlow: {
    chat: '/v1/chat/completions',
  },
  moonshot: {
    chat: '/v1/chat/completions',
  },
};

// fallback only: official metadata baseUrl is public contract data and must not
// be able to redirect user BYOK keys outside the vendor-owned domain boundary.
const OFFICIAL_METADATA_BASE_URL_ALLOWLIST: Partial<Record<ProviderKind, string[]>> = {
  openAI: ['openai.com'],
  anthropic: ['anthropic.com'],
  gemini: ['googleapis.com'],
  openRouter: ['openrouter.ai'],
  grok: ['x.ai'],
  deepseek: ['deepseek.com'],
  mistral: ['mistral.ai'],
  groq: ['groq.com'],
  togetherAI: ['together.xyz'],
  fireworksAI: ['fireworks.ai'],
  miniMax: ['minimax.io'],
  zhipu: ['bigmodel.cn'],
  qwen: ['aliyuncs.com'],
  moonshot: ['moonshot.ai', 'moonshot.cn'],
  siliconFlow: ['siliconflow.cn', 'siliconflow.com'],
};

/* ── Resolution ──────────────────────────────────────────── */

function normalizeBaseURL(url: string | undefined | null): string | undefined {
  if (!url) return undefined;
  const trimmed = url.trim().replace(/\/+$/, '');
  if (!trimmed) return undefined;
  if (!/^https?:\/\//i.test(trimmed)) return `https://${trimmed}`;
  return trimmed;
}

function reportRejectedMetadataBaseURL(
  reporter: MetadataBaseURLRejectionReporter | undefined,
  providerKind: ProviderKind | string,
  baseUrl: string,
  reason: 'invalid_url' | 'non_https' | 'host_not_allowed',
) {
  reporter?.({ providerKind: String(providerKind), baseUrl, reason });
}

function hostnameAllowed(hostname: string, allowedSuffixes: string[]): boolean {
  const host = hostname.toLowerCase();
  return allowedSuffixes.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}

export function sanitizeMetadataBaseURL(
  providerKind: ProviderKind | string,
  raw: string | undefined | null,
  reporter?: MetadataBaseURLRejectionReporter,
): string | undefined {
  const normalized = normalizeBaseURL(raw);
  if (!normalized) return undefined;

  const allowedSuffixes = OFFICIAL_METADATA_BASE_URL_ALLOWLIST[providerKind as ProviderKind];
  if (!allowedSuffixes) return normalized;

  let parsed: URL;
  try {
    parsed = new URL(normalized);
  } catch {
    reportRejectedMetadataBaseURL(reporter, providerKind, normalized, 'invalid_url');
    return undefined;
  }
  if (parsed.protocol !== 'https:') {
    reportRejectedMetadataBaseURL(reporter, providerKind, normalized, 'non_https');
    return undefined;
  }
  if (!hostnameAllowed(parsed.hostname, allowedSuffixes)) {
    reportRejectedMetadataBaseURL(reporter, providerKind, normalized, 'host_not_allowed');
    return undefined;
  }
  return normalized;
}

function joinURL(base: string, path: string | undefined): string {
  if (!path) return base;
  if (/^https?:\/\//i.test(path)) return path; // a full URL is returned as is
  return `${base.replace(/\/+$/, '')}/${path.replace(/^\/+/, '')}`;
}

function pathnameForPath(path: string | undefined): string {
  if (!path) return '';
  try {
    return new URL(path, 'https://endpoint.local').pathname.replace(/\/+$/, '');
  } catch {
    return path.split('?')[0]?.replace(/\/+$/, '') ?? '';
  }
}

function normalizeBaseForEndpoint(
  base: string,
  providerKind: ProviderKind | string,
  endpoint: string | undefined,
): string {
  if (!endpoint || /^https?:\/\//i.test(endpoint)) return base;

  let parsed: URL;
  try {
    parsed = new URL(base);
  } catch {
    return base;
  }

  const endpointPath = pathnameForPath(endpoint);
  if (!endpointPath) return base;

  let basePath = parsed.pathname.replace(/\/+$/, '');
  if (basePath === '/') basePath = '';

  if (providerKind === 'qwen' && basePath.endsWith('/compatible-mode/v1')) {
    parsed.pathname = basePath.slice(0, -'/compatible-mode/v1'.length) || '/';
    parsed.search = '';
    parsed.hash = '';
    return parsed.toString().replace(/\/+$/, '');
  }

  if (
    basePath &&
    (endpointPath === basePath || endpointPath.startsWith(`${basePath}/`))
  ) {
    parsed.pathname = '/';
    parsed.search = '';
    parsed.hash = '';
    return parsed.toString().replace(/\/+$/, '');
  }

  return base;
}

/* ── request-builders bridge ─────────────────────────────── */

/**
 * Short path suffix that each provider's request builder appends to the chat path itself.
 * A builder means `${base}` plus its short path, while metadata means `baseUrl` plus
 * `endpoints.chat` (a full path). Stripping this suffix from endpoints.chat yields the base a
 * builder expects.
 */
const BUILDER_CHAT_PATH_SUFFIX: Partial<Record<ProviderKind, string>> = {
  openAI: '/chat/completions',
  grok: '/chat/completions',
  openRouter: '/chat/completions',
  deepseek: '/chat/completions',
  mistral: '/chat/completions',
  groq: '/chat/completions',
  togetherAI: '/chat/completions',
  fireworksAI: '/chat/completions',
  miniMax: '/chat/completions',
  zhipu: '/chat/completions',
  siliconFlow: '/chat/completions',
  moonshot: '/chat/completions',
  anthropic: '/messages',
  gemini: '/models',
};

/**
 * Normalize a metadata transport (baseUrl plus the full endpoints.chat path) into the base that
 * request builders expect, since a builder appends its own short path. Both shapes are accepted:
 *   - already normalized: baseUrl=https://api.openai.com/v1 + chat=/chat/completions, base unchanged
 *   - full path: baseUrl=https://api.openai.com + chat=/v1/chat/completions,
 *     strip the short suffix to get base=https://api.openai.com/v1
 * Fail-safe: when endpoints.chat has an unrecognized shape (does not end in a known short suffix),
 * return undefined so the caller falls back to the built-in providerDefaults. Bad server data must
 * never be worse than not consuming metadata at all.
 */
export function deriveBuilderBaseURL(
  providerKind: ProviderKind | string,
  metaBaseUrl: string,
  endpoints: TransportEndpoints | undefined,
): string | undefined {
  // The qwen builder adapts to a bare origin itself (resolveDashScopeCompatibleChatURL appends
  // /compatible-mode/v1, and images needs the bare origin to build the native /api/v1/... path), so
  // pass it through without stripping.
  if (providerKind === 'qwen') return metaBaseUrl;

  const suffix = BUILDER_CHAT_PATH_SUFFIX[providerKind as ProviderKind];
  if (!suffix) return undefined;

  const chat = endpoints?.chat;
  // No endpoints published: the older shape where baseUrl is already the builder base, pass through.
  if (!chat) return metaBaseUrl;

  const path = pathnameForPath(chat);
  if (!path || path === suffix) return metaBaseUrl;
  if (path.endsWith(suffix)) {
    return joinURL(metaBaseUrl, path.slice(0, -suffix.length));
  }
  return undefined;
}

/** Substitute the {model} placeholder in an endpoint template. */
export function applyEndpointPlaceholders(
  template: string,
  vars: { model?: string },
): string {
  if (!template) return template;
  let out = template;
  if (vars.model != null) {
    out = out.replace(/\{model\}/g, encodeURIComponent(vars.model));
  }
  return out;
}

/**
 * Resolve the runtime endpoint for a provider and endpoint kind.
 *
 * @param getProviderTransport injected metadata lookup; without it only metadataOverride and the
 *   built-in fallbacks are used.
 * @returns the full URL string
 */
export function resolveEndpoint(
  provider: Provider | null | undefined,
  providerKind: ProviderKind | string,
  kind: EndpointKind,
  options?: {
    metadataOverride?: ProviderTransportDefinition | null;
    modelID?: string;
  } | ProviderTransportDefinition | null,
  getProviderTransport?: GetProviderTransportFn,
  reportRejectedMetadataBaseURL?: MetadataBaseURLRejectionReporter,
): string {
  // The fourth argument may also be a bare metadataOverride.
  const opts: {
    metadataOverride?: ProviderTransportDefinition | null;
    modelID?: string;
  } = options && typeof options === 'object' && 'metadataOverride' in options
    ? (options as { metadataOverride?: ProviderTransportDefinition | null; modelID?: string })
    : options && typeof options === 'object' && ('baseUrl' in options || 'endpoints' in options)
      ? { metadataOverride: options as ProviderTransportDefinition }
      : options === null
        ? { metadataOverride: null }
        : {};

  const meta = opts.metadataOverride ?? getProviderTransport?.(providerKind);
  const metaEndpoint = meta?.endpoints?.[kind];

  // Endpoint path: metadata first, built-in fallback when metadata has none.
  const endpointTemplate =
    metaEndpoint ?? DEFAULT_ENDPOINTS[providerKind as ProviderKind]?.[kind];
  const endpoint = endpointTemplate
    ? applyEndpointPlaceholders(endpointTemplate, { model: opts.modelID })
    : undefined;
  const userBase = normalizeBaseURL(provider?.baseURLText);
  const metaBase = sanitizeMetadataBaseURL(
    providerKind,
    meta?.baseUrl,
    reportRejectedMetadataBaseURL,
  );

  // Base URL: user configuration beats metadata, metadata beats the built-in fallback.
  const rawBase =
    userBase ??
    metaBase ??
    normalizeBaseURL(DEFAULT_BASE_URLS[providerKind as ProviderKind]) ??
    '';
  const base = rawBase
    ? normalizeBaseForEndpoint(rawBase, providerKind, endpoint)
    : '';

  if (!base) {
    throw new Error(
      `resolveEndpoint: cannot resolve the ${kind} endpoint for ${providerKind} (base URL missing)`,
    );
  }

  return joinURL(base, endpoint);
}

/** Resolve only the base URL, for callers that build the path themselves (such as Gemini). */
export function resolveBaseURL(
  provider: Provider | null | undefined,
  providerKind: ProviderKind | string,
  metadataOverride?: ProviderTransportDefinition | null,
  getProviderTransport?: GetProviderTransportFn,
  reportRejectedMetadataBaseURL?: MetadataBaseURLRejectionReporter,
): string {
  const userBase = normalizeBaseURL(provider?.baseURLText);
  const meta = metadataOverride ?? getProviderTransport?.(providerKind);
  const metaBase = sanitizeMetadataBaseURL(
    providerKind,
    meta?.baseUrl,
    reportRejectedMetadataBaseURL,
  );
  const base = (
    userBase ??
    metaBase ??
    normalizeBaseURL(DEFAULT_BASE_URLS[providerKind as ProviderKind]) ??
    ''
  );
  const endpoint = meta?.endpoints?.chat ?? DEFAULT_ENDPOINTS[providerKind as ProviderKind]?.chat;
  return base ? normalizeBaseForEndpoint(base, providerKind, endpoint) : base;
}

/** Resolve only the endpoint path fragment, so callers such as Gemini can compose it. */
export function resolveEndpointPath(
  providerKind: ProviderKind | string,
  kind: EndpointKind,
  metadataOverride?: ProviderTransportDefinition | null,
  getProviderTransport?: GetProviderTransportFn,
): string | undefined {
  const meta = metadataOverride ?? getProviderTransport?.(providerKind);
  return meta?.endpoints?.[kind] ?? DEFAULT_ENDPOINTS[providerKind as ProviderKind]?.[kind];
}
