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

import { providerDefaults } from '@oriveo/config';
import type { Provider, ProviderKind } from '@oriveo/shared/pure-types';
import type { ProviderTransportDefinition, TransportEndpoints } from '../../metadata/types';
import type { EndpointKind } from './transport-kind';

/** Look up the transport definition for a providerKind; returns undefined when metadata has none. */
export type GetProviderTransportFn = (
  providerKind: ProviderKind | string,
) => ProviderTransportDefinition | undefined;

/**
 * Payload for a rejected metadata baseURL. Carries only the host ('invalid' when it cannot be
 * parsed), never the full URL, since a published address may include a path or credentials.
 */
export type MetadataBaseURLRejectionReporter = (event: {
  providerKind: string;
  host: string;
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
  qwen: 'https://dashscope-intl.aliyuncs.com',
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

/* ── Trusted hosts (delivered by metadata as providerConfigs[].trustedHosts) ──────── */
//
// The baseUrl / regionOptions of official metadata are public contract data and must not carry a
// user's BYOK key outside that vendor's own domain boundary. The server delivers the boundary per
// vendor; when the delivered list is empty or missing, only the last two labels of that vendor's
// built-in fallback host are trusted (none of the 15 fallback hosts sit under a second-level public
// suffix, so the client ships no public suffix list).

const TRUSTED_HOST_LABEL_RE = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/;
const IPV4_RE = /^\d+(?:\.\d+){3}$/;

/** Shape check for delivered trusted hosts: lowercase, at least two labels, not an IP, no port, no wildcard; malformed items are dropped one by one. */
export function sanitizeTrustedHosts(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== 'string') continue;
    if (item !== item.toLowerCase() || IPV4_RE.test(item)) continue;
    const labels = item.split('.');
    if (labels.length < 2 || !labels.every((label) => TRUSTED_HOST_LABEL_RE.test(label))) continue;
    if (!out.includes(item)) out.push(item);
  }
  return out;
}

/** Fallback when the field is missing: the last two labels of that vendor's built-in fallback host. Returns undefined for a non-official vendor (no built-in fallback). */
export function fallbackTrustedHosts(providerKind: ProviderKind | string): string[] | undefined {
  const fallback = DEFAULT_BASE_URLS[providerKind as ProviderKind];
  if (!fallback) return undefined;
  const labels = new URL(fallback).hostname.toLowerCase().split('.');
  return [labels.slice(-2).join('.')];
}

/**
 * The trusted host list actually in effect for a vendor: the delivered value is used alone when it
 * is non-empty after the shape check, otherwise the built-in fallback applies.
 * Returns undefined = not an official vendor, so the caller applies no trusted-list constraint
 * (the same behavior as a missing entry in the old allowlist).
 */
export function resolveTrustedHosts(
  providerKind: ProviderKind | string,
  raw: unknown,
): string[] | undefined {
  const delivered = sanitizeTrustedHosts(raw);
  if (delivered.length > 0) return fallbackTrustedHosts(providerKind) ? delivered : undefined;
  return fallbackTrustedHosts(providerKind);
}

/** The single matching function: https, and the host equals an entry or ends with ".entry". Shared by base URL validation and region option filtering. */
export function trustedHostMatch(url: string, trustedHosts: readonly string[]): boolean {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  return parsed.protocol === 'https:' && hostnameAllowed(parsed.hostname, trustedHosts);
}

/* ── Official-vendor address source (endpointSource) and setup fields (setupFields) ────────── */
//
// default / region:<id> are computed from the current metadata at request time, so a server-side
// address change reaches existing records; when that cannot be computed, the literal address in the
// record is the fallback (baseURLText is still written, and older clients and sync read it).

export type EndpointSource = 'default' | 'custom' | `region:${string}`;

/** The closed set of setup fields the client knows; adding an id needs a release. */
export const SETUP_FIELD_IDS = ['workspaceId'] as const;
export type SetupFieldId = (typeof SETUP_FIELD_IDS)[number];
export type SetupValues = Partial<Record<SetupFieldId, string>>;

export interface SetupFieldSpec {
  id: SetupFieldId;
  required: boolean;
}

/** The part of providerConfig needed to resolve the address source (regionOptions should already have passed the trusted list). */
export interface OfficialEndpointConfig {
  defaultBaseURL?: string | null;
  regionOptions?: ReadonlyArray<{ id: string; baseURL: string }> | null;
  trustedHosts?: readonly string[] | null;
  setupFields?: readonly SetupFieldSpec[] | null;
}

const SETUP_PLACEHOLDER_RE = /\{([^{}]*)\}/g;
const SETUP_VALUE_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

/** The 15 official vendors (those with a built-in fallback address); relay / local connections do not take part in address sources. */
export function isOfficialEndpointKind(providerKind: ProviderKind | string): boolean {
  return Boolean(DEFAULT_BASE_URLS[providerKind as ProviderKind]);
}

function isSetupFieldId(id: string): id is SetupFieldId {
  return (SETUP_FIELD_IDS as readonly string[]).includes(id);
}

/** Decode `providerConfigs[].setupFields`: keep only distinct items inside the closed set; missing / null / empty = none. */
export function decodeSetupFields(raw: unknown): SetupFieldSpec[] | undefined {
  if (!Array.isArray(raw)) return undefined;
  const out: SetupFieldSpec[] = [];
  for (const item of raw) {
    if (!item || typeof item !== 'object') continue;
    const id = (item as { id?: unknown }).id;
    if (typeof id !== 'string' || !isSetupFieldId(id) || out.some((field) => field.id === id)) continue;
    out.push({ id, required: (item as { required?: unknown }).required === true });
  }
  return out.length > 0 ? out : undefined;
}

/** Placeholder ids appearing in an address template (deduplicated, in order of appearance). */
export function templatePlaceholderIds(template: string): string[] {
  const ids: string[] = [];
  for (const match of template.matchAll(SETUP_PLACEHOLDER_RE)) {
    const id = match[1] ?? '';
    if (!ids.includes(id)) ids.push(id);
  }
  return ids;
}

/**
 * Template admission at decode time: a placeholder is accepted only if its id is in the closed set and
 * declared in setupFields; with every placeholder replaced by `a`, the result must pass the trusted list.
 * An address with no placeholder is the same as a plain trusted-list match.
 */
export function setupTemplateAllowed(
  template: string,
  setupFields: readonly SetupFieldSpec[] | null | undefined,
  trustedHosts: readonly string[],
): boolean {
  const ids = templatePlaceholderIds(template);
  if (ids.some((id) => !isSetupFieldId(id) || !setupFields?.some((field) => field.id === id))) return false;
  return trustedHostMatch(template.trim().replace(SETUP_PLACEHOLDER_RE, 'a'), trustedHosts);
}

/** Setup field value: after trimming and lowercasing it must be a single DNS label; otherwise null. */
export function normalizeSetupFieldValue(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const value = raw.trim().toLowerCase();
  return SETUP_VALUE_RE.test(value) ? value : null;
}

/** Fill a template with the local setupValues; returns undefined if any placeholder has no value or an invalid one. */
export function fillSetupTemplate(
  template: string,
  values: SetupValues | null | undefined,
): string | undefined {
  let missing = false;
  const filled = template.replace(SETUP_PLACEHOLDER_RE, (_whole, id: string) => {
    const value = isSetupFieldId(id) ? normalizeSetupFieldValue(values?.[id]) : null;
    if (!value) missing = true;
    return value ?? '';
  });
  return missing ? undefined : filled;
}

/** Normalization before classifying: trim, lowercase scheme and host, drop trailing slashes, drop a trailing `/compatible-mode/v1`. */
export function normalizeEndpointSourceURL(url: string | null | undefined): string | undefined {
  const trimmed = url?.trim();
  if (!trimmed) return undefined;
  let out = trimmed.replace(/^([a-z][a-z0-9+.-]*:\/\/)([^/?#]*)/i, (_whole, scheme: string, host: string) =>
    `${scheme.toLowerCase()}${host.toLowerCase()}`);
  out = out.replace(/\/+$/, '').replace(/\/compatible-mode\/v1$/i, '').replace(/\/+$/, '');
  return out || undefined;
}

function trustedMetadataURL(
  providerKind: ProviderKind | string,
  url: string | null | undefined,
  config: OfficialEndpointConfig,
): string | undefined {
  const trimmed = url?.trim();
  if (!trimmed) return undefined;
  const trustedHosts = resolveTrustedHosts(providerKind, config.trustedHosts);
  if (!trustedHosts) return undefined;
  return trustedHostMatch(trimmed, trustedHosts) ? trimmed : undefined;
}

/** The full address (from @oriveo/config, with the version segment) written literally by the setup page when there is no metadata. */
function builtInDefaultBaseURL(providerKind: ProviderKind | string): string | undefined {
  return (providerDefaults as Partial<Record<string, { defaultBaseURL: string }>>)[providerKind]?.defaultBaseURL;
}

/**
 * Classify a literal address by the fixture rules: empty -> default; equal to a (trusted) region
 * address after normalization -> region:<id> (region beats default); equal to the (trusted) default
 * address -> default; equal to this client's built-in default -> default (a record created before the
 * server moved the default address still counts as default and follows it); otherwise custom.
 * Without metadata it cannot be classified and returns undefined.
 */
export function classifyEndpointSource(
  providerKind: ProviderKind | string,
  baseURLText: string | null | undefined,
  config: OfficialEndpointConfig | null | undefined,
): EndpointSource | undefined {
  const literal = normalizeEndpointSourceURL(baseURLText);
  if (!literal) return 'default';
  if (!config) return undefined;
  for (const option of config.regionOptions ?? []) {
    const trusted = trustedMetadataURL(providerKind, option.baseURL, config);
    if (trusted && normalizeEndpointSourceURL(trusted) === literal) return `region:${option.id}`;
  }
  const defaultURL = trustedMetadataURL(providerKind, config.defaultBaseURL, config);
  if (defaultURL && normalizeEndpointSourceURL(defaultURL) === literal) return 'default';
  if (normalizeEndpointSourceURL(builtInDefaultBaseURL(providerKind)) === literal) return 'default';
  return 'custom';
}

/** Retired regions: the record migrates to `replacement`, using the built-in address when metadata is absent. */
const RETIRED_REGIONS: ReadonlyArray<{
  kind: string;
  regionId: string;
  host: string;
  replacement: string;
  builtInReplacementBaseURL: string;
}> = [
  {
    kind: 'qwen',
    regionId: 'us',
    host: 'dashscope-us.aliyuncs.com',
    replacement: 'sg',
    builtInReplacementBaseURL: 'https://dashscope-intl.aliyuncs.com',
  },
];

type StoredEndpoint = {
  baseURLText?: string | null;
  endpointSource?: string | null;
  setupValues?: SetupValues | null;
};

function literalHost(url: string | null | undefined): string | undefined {
  const trimmed = url?.trim();
  if (!trimmed) return undefined;
  try {
    return new URL(trimmed).hostname.toLowerCase();
  } catch {
    return undefined;
  }
}

/**
 * Lazy migration: the startup backfill persists it locally, and a request computes the same thing in
 * memory first.
 * R1, a retired region -> replacement, with the literal rewritten to that region's address in the
 * current trusted metadata (the built-in one if none), independent of metadata;
 * unclassified -> classified by the current metadata; R2, source default with a non-empty literal that
 * matches a current trusted region -> region:<id>, literal unchanged.
 * A non-official vendor is returned as is.
 */
export function reconcileEndpointSource<T extends StoredEndpoint>(
  providerKind: ProviderKind | string,
  stored: T,
  config: OfficialEndpointConfig | null | undefined,
): T {
  if (!isOfficialEndpointKind(providerKind)) return stored;
  const retired = RETIRED_REGIONS.find((item) => item.kind === providerKind && (
    stored.endpointSource === `region:${item.regionId}` || literalHost(stored.baseURLText) === item.host
  ));
  if (retired) {
    const option = config?.regionOptions?.find((item) => item.id === retired.replacement);
    const metadataURL = option && templatePlaceholderIds(option.baseURL).length === 0
      ? trustedMetadataURL(providerKind, option.baseURL, config!)
      : undefined;
    return {
      ...stored,
      endpointSource: `region:${retired.replacement}`,
      baseURLText: metadataURL ?? retired.builtInReplacementBaseURL,
    };
  }
  const source = stored.endpointSource
    || (config ? classifyEndpointSource(providerKind, stored.baseURLText, config) : undefined);
  if (source === 'default' && config) {
    const literal = normalizeEndpointSourceURL(stored.baseURLText);
    const region = literal
      ? config.regionOptions?.find((option) => {
        const trusted = trustedMetadataURL(providerKind, option.baseURL, config);
        return trusted !== undefined && normalizeEndpointSourceURL(trusted) === literal;
      })
      : undefined;
    if (region) return { ...stored, endpointSource: `region:${region.id}` };
  }
  return source && source !== stored.endpointSource ? { ...stored, endpointSource: source } : stored;
}

/**
 * The root address of an official vendor at request time: run the lazy migration (R1 / R2) in memory
 * first, then compute default / region:<id> from the current metadata (the template is filled from
 * setupValues, and the result passes the trusted list again), falling back to the literal address when
 * that cannot be computed; custom uses the literal address. When the literal is empty it returns
 * undefined and the caller keeps the existing metadata -> built-in fallback chain. An unclassified
 * record is classified on the spot from the current metadata.
 */
export function resolveEndpointSourceBaseURL(
  providerKind: ProviderKind | string,
  stored: StoredEndpoint | null | undefined,
  config: OfficialEndpointConfig | null | undefined,
): string | undefined {
  const reconciled = stored && isOfficialEndpointKind(providerKind)
    ? reconcileEndpointSource(providerKind, stored, config)
    : stored;
  const literal = reconciled?.baseURLText?.trim() || undefined;
  if (!literal || !config || !isOfficialEndpointKind(providerKind)) return literal;
  const source = reconciled?.endpointSource ?? classifyEndpointSource(providerKind, literal, config);
  let template: string | null | undefined;
  if (source === 'default') {
    template = config.defaultBaseURL;
  } else if (source?.startsWith('region:')) {
    const regionId = source.slice('region:'.length);
    template = config.regionOptions?.find((option) => option.id === regionId)?.baseURL;
  }
  if (!template) return literal;
  const filled = fillSetupTemplate(template.trim(), reconciled?.setupValues);
  return trustedMetadataURL(providerKind, filled, config) ?? literal;
}

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
  host: string,
  reason: 'invalid_url' | 'non_https' | 'host_not_allowed',
) {
  reporter?.({ providerKind: String(providerKind), host, reason });
}

function hostnameAllowed(hostname: string, allowedSuffixes: readonly string[]): boolean {
  const host = hostname.toLowerCase();
  return allowedSuffixes.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}

export function sanitizeMetadataBaseURL(
  providerKind: ProviderKind | string,
  raw: string | undefined | null,
  reporter?: MetadataBaseURLRejectionReporter,
  /** `providerConfigs[].trustedHosts` delivered by metadata; empty / missing falls back to the built-in registered domain. */
  trustedHosts?: unknown,
): string | undefined {
  const normalized = normalizeBaseURL(raw);
  if (!normalized) return undefined;

  const allowedSuffixes = resolveTrustedHosts(providerKind, trustedHosts);
  if (!allowedSuffixes) return normalized;

  let parsed: URL;
  try {
    parsed = new URL(normalized);
  } catch {
    reportRejectedMetadataBaseURL(reporter, providerKind, 'invalid', 'invalid_url');
    return undefined;
  }
  if (parsed.protocol !== 'https:') {
    reportRejectedMetadataBaseURL(reporter, providerKind, parsed.hostname, 'non_https');
    return undefined;
  }
  if (!hostnameAllowed(parsed.hostname, allowedSuffixes)) {
    reportRejectedMetadataBaseURL(reporter, providerKind, parsed.hostname, 'host_not_allowed');
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
  const userBase = normalizeBaseURL(
    resolveEndpointSourceBaseURL(providerKind, provider, meta?.endpointConfig) ?? provider?.baseURLText,
  );
  const metaBase = sanitizeMetadataBaseURL(
    providerKind,
    meta?.baseUrl,
    reportRejectedMetadataBaseURL,
    meta?.trustedHosts,
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
  const meta = metadataOverride ?? getProviderTransport?.(providerKind);
  const userBase = normalizeBaseURL(
    resolveEndpointSourceBaseURL(providerKind, provider, meta?.endpointConfig) ?? provider?.baseURLText,
  );
  const metaBase = sanitizeMetadataBaseURL(
    providerKind,
    meta?.baseUrl,
    reportRejectedMetadataBaseURL,
    meta?.trustedHosts,
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
