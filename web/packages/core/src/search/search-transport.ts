// External web search: restricted declarative transport json_http/v1, result sanitizing, error mapping, and custom service validation.
// Reference implementation: scripts/lib/search-transport.mjs, ported function by function (browser + Node, no node:* dependency).
// Same names on every client: buildSearchRequest / parseSearchResponse / sanitizeSearchText / classifySearchError /
// validateCustomSearchService / validateManualMapping. Values are only read; templates, expressions and scripts are not supported.

export const TRANSPORT_KIND = 'json_http/v1';

// Client-side hard limits, independent of the catalog
export const HARD_LIMITS = Object.freeze({
  maxCount: 10,
  defaultCount: 5,
  maxTimeoutSec: 60,
  maxResponseBytes: 2 * 1024 * 1024,
  titleMaxChars: 200,
  snippetMaxChars: 1000,
  siteMaxChars: 100,
  dateMaxChars: 32,
  maxQueryChars: 400,
});

type StaticParamRule = { readonly enum?: readonly unknown[]; readonly int?: readonly [number, number] };

// Allowlist of static params the catalog may enable (key = dotted path): stops a catalog from switching on surcharge params. Custom services are not bound by it.
export const STATIC_PARAM_WHITELIST: Readonly<Record<string, StaticParamRule>> = Object.freeze({
  search_engine: { enum: ['search_std', 'search-prime'] },
  search_intent: { enum: [false] },
  search_depth: { enum: ['basic'] },
  type: { enum: ['auto'] },
  max_tokens_per_page: { int: [1, 512] },
  'contents.text': { enum: [false] },
  'contents.highlights.maxCharacters': { int: [1, 1000] },
  format: { enum: ['json'] },
});

export type StaticParamValue = string | number | boolean;
export type FieldLocation = 'body' | 'query';

export interface TransportField {
  field: string;
  in: FieldLocation;
  maxChars?: number;
  max?: number;
}

export interface ErrorRule {
  status: number;
  match?: { path: string; equals: unknown } | null;
  class: ErrorClass;
}

export interface ResponseMapping {
  results: string;
  title: string[];
  url: string[];
  snippet?: string[];
  site?: string[];
  date?: string[];
  html?: boolean;
}

/** json_http/v1 description: a catalog entry's transport, or a custom service's mapping (SearXNG / manual / "same as X" snapshot). */
export interface TransportSpec {
  kind?: string;
  method: 'GET' | 'POST';
  path?: string;
  auth: { kind: 'bearer' | 'header' | 'none'; name?: string };
  query: TransportField;
  count?: TransportField | null;
  static?: { in?: FieldLocation; params?: Record<string, StaticParamValue> } | null;
  response: ResponseMapping;
  errors?: ErrorRule[];
}

export interface SearchTarget {
  scheme: string;
  host: string;
  port?: number | null;
  /** Full path of a custom service; overrides spec.path */
  path?: string;
  /** Static params overridden by the site */
  static?: Record<string, StaticParamValue>;
}

export interface SearchRequest {
  method: 'GET' | 'POST';
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown> | null;
}

export interface SearchResult {
  title: string;
  url: string;
  snippet: string;
  site?: string;
  date?: string;
}

/** An empty query sends no request (does not cost the user money); callers treat it as "no results" */
export interface SearchRequestSkip {
  skip: 'query_empty';
}

export type ParsedSearchResponse =
  | { kind: 'results'; results: SearchResult[] }
  | { kind: 'empty' }
  | { kind: 'error'; errorClass: 'parse_mismatch' };

export function staticParamAllowed(key: string, value: unknown): boolean {
  const rule = Object.prototype.hasOwnProperty.call(STATIC_PARAM_WHITELIST, key) ? STATIC_PARAM_WHITELIST[key] : undefined;
  if (!rule) return false;
  if (rule.enum) return rule.enum.some((v) => v === value);
  if (rule.int) return Number.isInteger(value) && (value as number) >= rule.int[0] && (value as number) <= rule.int[1];
  return false;
}

const IDENT_PATH = /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/;
const HEADER_NAME = /^[A-Za-z0-9!#$%&'*+.^_`|~-]{1,64}$/;
const BLOCKED_HEADERS = new Set(['host', 'content-length', 'content-type', 'cookie', 'connection', 'transfer-encoding', 'origin', 'referer', 'accept', 'user-agent']);
const TEMPLATE_MARKERS = ['{{', '${', '<%', '#{'];

function codePoints(s: string): string[] {
  return Array.from(s);
}

function truncateChars(s: string, max: number): string {
  const cps = codePoints(s);
  if (cps.length <= max) return s;
  return cps.slice(0, max - 1).join('') + '…';
}

function setPath(obj: Record<string, unknown>, dotted: string, value: unknown): void {
  const parts = dotted.split('.');
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i += 1) {
    if (cur[parts[i]] === undefined) cur[parts[i]] = {};
    cur = cur[parts[i]] as Record<string, unknown>;
  }
  cur[parts[parts.length - 1]] = value;
}

export function getPath(obj: unknown, dotted: string): unknown {
  let cur = obj;
  for (const part of dotted.split('.')) {
    if (cur === null || typeof cur !== 'object' || Array.isArray(cur)) return undefined;
    cur = (cur as Record<string, unknown>)[part];
  }
  return cur;
}

const ENTITY: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

/**
 * Cleans text in results: with html=true strips tags and decodes entities; C0 / C1 control characters become spaces; runs of whitespace collapse to one space; trimmed; truncated by code point (with … appended).
 */
export function sanitizeSearchText(value: unknown, { html = false, maxChars }: { html?: boolean; maxChars: number }): string {
  if (typeof value !== 'string') return '';
  let s = value;
  if (html) {
    s = s.replace(/<[^>]*>/g, '');
    s = s.replace(/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-zA-Z]+);/g, (m, body: string) => {
      if (body[0] === '#') {
        const cp = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
        return Number.isInteger(cp) && cp > 0 && cp <= 0x10ffff && !(cp >= 0xd800 && cp <= 0xdfff) ? String.fromCodePoint(cp) : ' ';
      }
      return Object.prototype.hasOwnProperty.call(ENTITY, body) ? ENTITY[body] : m;
    });
  }
  // eslint-disable-next-line no-control-regex
  s = s.replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ');
  s = s.replace(/[\s\u00a0\u2028\u2029\u3000]+/gu, ' ').trim();
  return truncateChars(s, maxChars);
}

function firstText(item: unknown, paths: readonly string[] | undefined, html: boolean, maxChars: number): string {
  for (const p of paths ?? []) {
    const v = getPath(item, p);
    let text = '';
    if (typeof v === 'string') text = v;
    else if (Array.isArray(v) && v.every((x) => typeof x === 'string')) text = v.join(' … ');
    const clean = sanitizeSearchText(text, { html, maxChars });
    if (clean) return clean;
  }
  return '';
}

function absoluteHttpUrl(s: unknown): string | null {
  if (typeof s !== 'string') return null;
  const t = s.trim();
  if (!/^https?:\/\/[^\s/?#]+/i.test(t)) return null;
  return t;
}

function encodeQuery(pairs: Array<[string, unknown]>): string {
  return pairs.map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join('&');
}

/**
 * spec: json_http/v1 description (a catalog entry's transport, or a custom service's mapping).
 * target: { scheme, host, port?, path? (full path of a custom service, overrides spec.path), static? (site override) }
 * Outputs { method, url, headers, body }; body is an object (compared by JSON semantics, not bytes).
 */
export function buildSearchRequest(
  spec: TransportSpec,
  target: SearchTarget,
  { query, count, key }: { query: string | null | undefined; count?: number | null; key?: string | null },
): SearchRequest | SearchRequestSkip {
  const maxChars = Math.min(spec.query.maxChars ?? HARD_LIMITS.maxQueryChars, HARD_LIMITS.maxQueryChars);
  const q = codePoints(String(query ?? '').trim()).slice(0, maxChars).join('');
  // An empty query sends no request (does not cost the user money); callers treat it as "no results"
  if (!q) return { skip: 'query_empty' };
  const specMax = spec.count?.max ?? HARD_LIMITS.maxCount;
  // A count that is not a positive integer (missing, 0, negative, fractional) always falls back to the default 5 ("requested value || 5")
  const want = typeof count === 'number' && Number.isSafeInteger(count) && count > 0 ? count : HARD_LIMITS.defaultCount;
  const n = Math.max(1, Math.min(want, specMax, HARD_LIMITS.maxCount));
  const bodyObj: Record<string, unknown> = {};
  const queryPairs: Array<[string, unknown]> = [];
  const put = (where: FieldLocation, field: string, value: unknown) => {
    if (where === 'query') queryPairs.push([field, value]);
    else setPath(bodyObj, field, value);
  };
  put(spec.query.in, spec.query.field, q);
  if (spec.count) put(spec.count.in, spec.count.field, n);
  const staticParams: Record<string, StaticParamValue> = { ...(spec.static?.params ?? {}), ...(target.static ?? {}) };
  for (const k of Object.keys(staticParams).sort()) put(spec.static?.in ?? spec.query.in, k, staticParams[k]);

  const port = target.port ? `:${target.port}` : '';
  const path = target.path ?? spec.path ?? '/';
  const qs = queryPairs.length ? `?${encodeQuery(queryPairs)}` : '';
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (spec.method === 'POST') headers['Content-Type'] = 'application/json';
  if (key) {
    if (spec.auth.kind === 'bearer') headers.Authorization = `Bearer ${key}`;
    else if (spec.auth.kind === 'header' && spec.auth.name) headers[spec.auth.name] = key;
  }
  return {
    method: spec.method,
    url: `${target.scheme}://${target.host}${port}${path}${qs}`,
    headers,
    body: spec.method === 'POST' ? bodyObj : null,
  };
}

/**
 * 2xx response -> { kind: 'results', results } | { kind: 'empty' } | { kind: 'error', errorClass: 'parse_mismatch' }.
 * Each item: { title, url, snippet, site?, date? }; items whose url is not an absolute http(s) URL are dropped; results of one response are de-duplicated by url; truncated by count.
 */
export function parseSearchResponse(spec: Pick<TransportSpec, 'response'>, body: unknown, { count }: { count?: number | null } = {}): ParsedSearchResponse {
  const r = spec.response;
  const list = getPath(body, r.results);
  if (!Array.isArray(list)) return { kind: 'error', errorClass: 'parse_mismatch' };
  // Same count rule as buildSearchRequest: a non-positive-integer becomes 5, then it is clamped by the hard limit
  const n = Math.min(typeof count === 'number' && Number.isSafeInteger(count) && count > 0 ? count : HARD_LIMITS.defaultCount, HARD_LIMITS.maxCount);
  const seen = new Set<string>();
  const results: SearchResult[] = [];
  for (const item of list) {
    if (results.length >= n) break;
    if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
    let url: string | null = null;
    for (const p of r.url) {
      url = absoluteHttpUrl(getPath(item, p));
      if (url) break;
    }
    if (!url || seen.has(url)) continue;
    seen.add(url);
    const html = r.html === true;
    const out: SearchResult = {
      title: firstText(item, r.title, html, HARD_LIMITS.titleMaxChars) || url,
      url,
      snippet: firstText(item, r.snippet, html, HARD_LIMITS.snippetMaxChars),
    };
    const site = firstText(item, r.site, html, HARD_LIMITS.siteMaxChars);
    if (site) out.site = site;
    const date = firstText(item, r.date, false, HARD_LIMITS.dateMaxChars);
    if (date) out.date = date;
    results.push(out);
  }
  if (list.length > 0 && results.length === 0) return { kind: 'error', errorClass: 'parse_mismatch' };
  return results.length ? { kind: 'results', results } : { kind: 'empty' };
}

// ───────────── Error mapping ─────────────

export type ErrorClass =
  | 'auth_invalid'
  | 'insufficient_balance'
  | 'rate_limited'
  | 'timeout'
  | 'network'
  | 'upstream_unavailable'
  | 'upstream_error'
  | 'request_rejected'
  | 'parse_mismatch'
  | 'searxng_json_disabled'
  | 'host_changed'
  | 'service_withdrawn'
  | 'response_too_large';

export type ToolMessageKey = 'no_results' | 'unavailable' | 'cap_reached';

export interface ErrorCard {
  headline: string;
  primaryAction: string;
  secondaryAction?: string;
}

interface ErrorClassDef {
  readonly retryOnce: boolean;
  readonly toolMessage: ToolMessageKey;
  readonly card: { readonly headline: string; readonly primaryAction: string };
}

export const ERROR_CLASSES: Readonly<Record<ErrorClass, ErrorClassDef>> = Object.freeze({
  auth_invalid: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'key_rejected', primaryAction: 'update_key' } },
  insufficient_balance: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'insufficient_balance', primaryAction: 'top_up' } },
  rate_limited: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'rate_limited', primaryAction: 'retry_later' } },
  timeout: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'no_response', primaryAction: 'retry' } },
  network: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'no_response', primaryAction: 'retry' } },
  upstream_unavailable: { retryOnce: true, toolMessage: 'unavailable', card: { headline: 'no_response', primaryAction: 'retry' } },
  upstream_error: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'service_error', primaryAction: 'retry' } },
  request_rejected: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'service_error', primaryAction: 'switch_service' } },
  parse_mismatch: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'format_mismatch', primaryAction: 'switch_service' } },
  searxng_json_disabled: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'searxng_json_disabled', primaryAction: 'view_setup_guide' } },
  host_changed: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'host_changed', primaryAction: 'reconfirm' } },
  service_withdrawn: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'service_withdrawn', primaryAction: 'switch_service' } },
  response_too_large: { retryOnce: false, toolMessage: 'unavailable', card: { headline: 'service_error', primaryAction: 'switch_service' } },
});

// Fixed text returned to the model (English, byte-identical on every client)
export const TOOL_MESSAGES: Readonly<Record<ToolMessageKey, string>> = Object.freeze({
  no_results: 'The web search returned no results. Do not search again for this; answer from what you know and say that the search found nothing.',
  unavailable: 'Web search is not available right now. Do not call web_search again in this reply. Answer directly and tell the user you could not search the web.',
  cap_reached: 'The web search limit for this reply has been reached. Do not call web_search again. Answer from the results you already have.',
});

function matches(body: unknown, match: ErrorRule['match']): boolean {
  if (!match) return true;
  return getPath(body, match.path) === match.equals;
}

export interface SearchErrorInput {
  /** HTTP status; absent for network-layer failures */
  status?: number;
  /** blocked = refused by this device's security policy (resolved to a private network / DNS rebinding, cross-origin / too many hops / invalid Location redirect aborted) */
  transportFailure?: 'timeout' | 'network' | 'too_large' | 'blocked';
  preflight?: 'host_changed' | 'service_withdrawn';
  parse?: 'mismatch';
  body?: unknown;
  /** Specific rules of a catalog entry / custom protocol */
  rules?: readonly ErrorRule[];
  custom?: boolean;
  otherServices?: number;
}

export interface ClassifiedSearchError {
  errorClass: ErrorClass;
  retryOnce: boolean;
  toolMessage: ToolMessageKey;
  card: ErrorCard;
}

/**
 * Input: { status?, transportFailure?, preflight?, parse?, body?, rules?, custom?, otherServices? }
 * Output: { errorClass, retryOnce, toolMessage, card: { headline, primaryAction, secondaryAction? } }
 */
export function classifySearchError(input: SearchErrorInput): ClassifiedSearchError {
  let cls: ErrorClass | null = null;
  if (input.transportFailure === 'timeout') cls = 'timeout';
  else if (input.transportFailure === 'network') cls = 'network';
  else if (input.transportFailure === 'too_large') cls = 'response_too_large';
  // Refused by the local security policy: there is no HTTP status and retrying is pointless; treat as a rejected request
  else if (input.transportFailure === 'blocked') cls = 'request_rejected';
  else if (input.preflight === 'host_changed') cls = 'host_changed';
  else if (input.preflight === 'service_withdrawn') cls = 'service_withdrawn';
  else if (input.parse === 'mismatch') cls = 'parse_mismatch';
  if (!cls) {
    const s = input.status;
    for (const rule of input.rules ?? []) {
      if (rule.status === s && matches(input.body, rule.match)) {
        cls = rule.class;
        break;
      }
    }
    if (!cls) {
      if (s === 401 || s === 403) cls = 'auth_invalid';
      else if (s === 402) cls = 'insufficient_balance';
      else if (s === 429) cls = 'rate_limited';
      // HTTP 408 means upstream says "did not get to it this time" and is retried once like 502 / 503; a local timeout is a transportFailure and is not retried
      else if (s === 408 || s === 502 || s === 503) cls = 'upstream_unavailable';
      else if (s !== undefined && s >= 500) cls = 'upstream_error';
      else cls = 'request_rejected';
    }
  }
  const def = errorClassDef(cls);
  return { errorClass: cls, retryOnce: def.retryOnce, toolMessage: def.toolMessage, card: searchErrorCard(cls, input) };
}

function errorClassDef(cls: string): ErrorClassDef {
  const def = Object.prototype.hasOwnProperty.call(ERROR_CLASSES, cls) ? ERROR_CLASSES[cls as ErrorClass] : undefined;
  if (!def) throw new Error(`unknown error class ${cls}`);
  return def;
}

/** Primary / secondary actions of the error card: shared by classifySearchError and the reply wrap-up (search-turn finishSearchReply). */
export function searchErrorCard(cls: string, { custom = false, otherServices = 0 }: { custom?: boolean; otherServices?: number } = {}): ErrorCard {
  const def = errorClassDef(cls);
  const card: ErrorCard = { ...def.card };
  // A custom service has no official link / catalog, so the primary action for balance and format errors becomes "Check settings"
  if (custom === true && ['top_up', 'switch_service'].includes(card.primaryAction) && cls !== 'service_withdrawn') card.primaryAction = 'check_settings';
  // A failure does not switch services automatically; when other services exist, offer a "Switch to X" secondary action
  // On a local network failure no other service will connect either, so "Switch to X" is not offered
  if ((otherServices ?? 0) > 0 && card.primaryAction !== 'switch_service' && cls !== 'network') card.secondaryAction = 'switch_to_other_service';
  return card;
}

// ───────────── Custom services ─────────────

export const CUSTOM_PROTOCOLS = Object.freeze(['searxng', 'same_as', 'manual'] as const);
export type CustomProtocol = (typeof CUSTOM_PROTOCOLS)[number];

// Custom services (all three protocols) carry no catalog limits and always use this timeout (same as most presets, still bounded by HARD_LIMITS.maxTimeoutSec)
export const CUSTOM_TIMEOUT_SEC = 20;

// SearXNG protocol: built into the client (not a catalog vendor), GET /search?format=json; the key is optional and sent as a Bearer token when present
export const SEARXNG_SPEC: Readonly<TransportSpec> = Object.freeze({
  kind: TRANSPORT_KIND,
  method: 'GET',
  auth: { kind: 'bearer' },
  query: { field: 'q', in: 'query', maxChars: HARD_LIMITS.maxQueryChars },
  count: null,
  static: { in: 'query', params: { format: 'json' } },
  response: { results: 'results', title: ['title'], url: ['url'], snippet: ['content'], date: ['publishedDate'], html: true },
  errors: [{ status: 403, class: 'searxng_json_disabled' }],
} satisfies TransportSpec);

const DEFAULT_PORT: Record<string, number> = { http: 80, https: 443 };

// Web is forwarded through the server and can only connect to ports the SSRF guard allows (apps/app/app/api/_shared/ssrf-guard.ts ALLOWED_PORTS)
export const WEB_ALLOWED_PORTS: readonly number[] = Object.freeze([80, 443, 8080, 8443]);

export interface ServiceAddress {
  scheme: string;
  host: string;
  port: number | null;
  path: string;
  query: string;
}

/** Address split: only ASCII hostnames or IPs are accepted; userinfo / fragment are rejected. Returns null = invalid. */
export function parseServiceAddress(address: unknown): ServiceAddress | null {
  if (typeof address !== 'string') return null;
  const t = address.trim();
  const m = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/.exec(t);
  if (!m) return null;
  const scheme = m[1].toLowerCase();
  const authority = m[2];
  if (m[5] !== undefined || authority.includes('@') || authority === '') return null;
  const hp = /^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::(\d{1,5}))?$/.exec(authority);
  if (!hp) return null;
  const host = hp[1].toLowerCase();
  if (!host.startsWith('[') && (host.startsWith('.') || host.endsWith('.') || host.includes('..'))) return null;
  let port: number | null = hp[2] !== undefined ? Number(hp[2]) : null;
  if (port !== null && (port < 1 || port > 65535)) return null;
  if (port !== null && DEFAULT_PORT[scheme] === port) port = null;
  return { scheme, host, port, path: m[3] || '', query: m[4] ?? '' };
}

/** Source the key is bound to: scheme://host[:port] (default port omitted). A changed path does not clear the key; a changed source must. */
export function keyBindingOrigin(address: unknown): string | null {
  const p = parseServiceAddress(address);
  if (!p) return null;
  return `${p.scheme}://${p.host}${p.port ? `:${p.port}` : ''}`;
}

export function addressChangeClearsKey(oldAddress: unknown, newAddress: unknown): boolean {
  return keyBindingOrigin(oldAddress) !== keyBindingOrigin(newAddress);
}

export function searxngPath(path: string | null | undefined): string {
  const base = (path || '').replace(/\/+$/, '');
  return base.endsWith('/search') ? base : `${base}/search`;
}

function hasTemplate(s: unknown): boolean {
  return typeof s === 'string' && TEMPLATE_MARKERS.some((m) => s.includes(m));
}

type LooseMapping = {
  method?: unknown;
  auth?: { kind?: unknown; name?: unknown } | null;
  query?: { field?: unknown; in?: unknown } | null;
  count?: { field?: unknown; in?: unknown } | null;
  static?: { in?: unknown; params?: Record<string, unknown> | null } | null;
  response?: Record<string, unknown> | null;
};

// Two paths at the same location (body or query string) that are identical, or where one is a prefix of the other (a and a.b), would overwrite each other when expanded
function pathConflict(m: LooseMapping): boolean {
  const where: Record<string, string[]> = { body: [], query: [] };
  const push = (location: unknown, path: unknown) => {
    if (typeof path === 'string' && path && typeof location === 'string' && Object.prototype.hasOwnProperty.call(where, location)) where[location].push(path);
  };
  push(m.query?.in, m.query?.field);
  push(m.count?.in, m.count?.field);
  const staticIn = m.static?.in ?? m.query?.in;
  for (const k of Object.keys(m.static?.params ?? {})) push(staticIn, k);
  for (const list of Object.values(where)) {
    for (let i = 0; i < list.length; i += 1) {
      for (let j = 0; j < list.length; j += 1) {
        if (i !== j && (list[i] === list[j] || list[j].startsWith(`${list[i]}.`))) return true;
      }
    }
  }
  return false;
}

/** Manual mapping (json_http/v1 subset) validation: returns an array of error codes, empty = valid. */
export function validateManualMapping(mapping: unknown): string[] {
  const errors: string[] = [];
  if (!mapping || typeof mapping !== 'object') return ['mapping_missing'];
  const m = mapping as LooseMapping;
  if (!['GET', 'POST'].includes(m.method as string)) errors.push('method_invalid');
  const auth = m.auth ?? {};
  if (!['bearer', 'header', 'none'].includes(auth.kind as string)) errors.push('auth_invalid');
  if (auth.kind === 'header' && (!HEADER_NAME.test((auth.name as string) ?? '') || BLOCKED_HEADERS.has(String(auth.name).toLowerCase()))) errors.push('header_name_invalid');
  const fieldOk = (f: LooseMapping['query']) => !!f && typeof f.field === 'string' && IDENT_PATH.test(f.field) && ['body', 'query'].includes(f.in as string);
  if (!fieldOk(m.query)) errors.push('query_field_invalid');
  if (m.count !== null && m.count !== undefined && !fieldOk(m.count)) errors.push('count_field_invalid');
  if (m.method === 'GET') {
    if (m.query?.in === 'body' || m.count?.in === 'body' || (m.static && m.static.in === 'body')) errors.push('get_has_body');
  }
  const params = m.static?.params ?? {};
  const keys = Object.keys(params);
  if (keys.length > 10) errors.push('too_many_static_params');
  for (const k of keys) {
    const v = params[k];
    if (!IDENT_PATH.test(k)) errors.push('static_key_invalid');
    else if (!(typeof v === 'boolean' || Number.isInteger(v) || (typeof v === 'string' && Array.from(v).length <= 200))) errors.push('static_value_invalid');
    else if (hasTemplate(v)) errors.push('template_rejected');
  }
  const r = m.response ?? {};
  if (typeof r.results !== 'string' || !IDENT_PATH.test(r.results)) errors.push('results_path_invalid');
  const pathList = (v: unknown): v is unknown[] => Array.isArray(v) && v.length <= 3 && v.every((p) => typeof p === 'string' && IDENT_PATH.test(p));
  for (const key of ['title', 'url', 'snippet']) {
    const v = r[key];
    if (!pathList(v) || v.length === 0) errors.push(`${key}_path_invalid`);
  }
  for (const key of ['site', 'date']) {
    if (r[key] !== undefined && !pathList(r[key])) errors.push(`${key}_path_invalid`);
  }
  for (const s of [m.query?.field, m.count?.field, r.results]) if (hasTemplate(s)) errors.push('template_rejected');
  if (pathConflict(m)) errors.push('path_conflict');
  return [...new Set(errors)];
}

/** Entry fields read by snapshotPresetMapping (a subset of a catalog entry). */
export interface PresetEntryForSnapshot {
  id: string;
  regions?: Array<{ id: string; static?: Record<string, StaticParamValue> }>;
  transport: TransportSpec;
}

export interface PresetMappingSnapshot extends TransportSpec {
  kind: typeof TRANSPORT_KIND;
  count: TransportField | null;
  static: { in: FieldLocation; params: Record<string, StaticParamValue> } | null;
  errors: ErrorRule[];
  snapshotOf: { serviceId: string; region: string | null };
}

/** "Same as X": snapshots that provider's mapping (without the host) at save time, so later catalog changes do not affect an already saved service. */
export function snapshotPresetMapping(entry: PresetEntryForSnapshot, regionId: string | null | undefined): PresetMappingSnapshot {
  const t = entry.transport;
  const region = (entry.regions ?? []).find((r) => r.id === regionId) ?? entry.regions?.[0];
  const params: Record<string, StaticParamValue> = { ...(t.static?.params ?? {}), ...(region?.static ?? {}) };
  return {
    kind: TRANSPORT_KIND,
    method: t.method,
    auth: { ...t.auth },
    query: { ...t.query },
    count: t.count ? { ...t.count } : null,
    static: Object.keys(params).length ? { in: t.static?.in ?? t.query.in, params } : null,
    response: JSON.parse(JSON.stringify(t.response)) as ResponseMapping,
    errors: JSON.parse(JSON.stringify(t.errors ?? [])) as ErrorRule[],
    snapshotOf: { serviceId: entry.id, region: region?.id ?? null },
  };
}

export interface CustomServiceInput {
  name?: unknown;
  address?: unknown;
  protocol?: unknown;
  platform?: 'ios' | 'android' | 'web';
  /** Provided by the existing security checks for local / LAN endpoints (after DNS resolution) */
  addressClass?: 'public' | 'lan' | 'unresolved';
  presetId?: string;
  catalogAvailable?: boolean;
  presetActive?: boolean;
  manual?: unknown;
}

export interface CustomServiceValidation {
  ok: boolean;
  errors: string[];
  warnings: string[];
  origin: string | null;
  requestPath: string | null;
}

/**
 * Custom service form validation.
 * Input: { name, address, protocol, platform: 'ios' | 'android' | 'web', addressClass, presetId?, catalogAvailable?, presetActive?, manual? }
 * Output: { ok, errors, warnings, origin, requestPath }
 */
export function validateCustomSearchService(input: CustomServiceInput): CustomServiceValidation {
  const errors: string[] = [];
  const warnings: string[] = [];
  const name = typeof input.name === 'string' ? input.name.trim() : '';
  if (!name) errors.push('name_empty');
  else if (Array.from(name).length > 40) errors.push('name_too_long');
  const addr = parseServiceAddress(input.address);
  if (!addr) errors.push('address_invalid');
  else if (!['http', 'https'].includes(addr.scheme)) errors.push('scheme_not_allowed');
  else if (addr.query) errors.push('address_has_query');
  else {
    const web = input.platform === 'web';
    if (web && addr.scheme === 'http') errors.push('http_not_allowed_on_web');
    if (web && addr.port !== null && !WEB_ALLOWED_PORTS.includes(addr.port)) errors.push('port_not_allowed_on_web');
    if (web && input.addressClass === 'lan') errors.push('private_address_on_web');
    if (!web && addr.scheme === 'http' && input.addressClass === 'public') errors.push('http_public_not_allowed');
    if (!web && addr.scheme === 'http' && input.addressClass === 'lan') warnings.push('cleartext_lan');
    if (input.addressClass === 'unresolved') errors.push('address_unresolved');
  }
  if (!(CUSTOM_PROTOCOLS as readonly unknown[]).includes(input.protocol)) errors.push('protocol_invalid');
  if (input.protocol === 'same_as' && !(input.catalogAvailable === true && input.presetActive === true)) errors.push('preset_unavailable');
  if (input.protocol === 'manual') errors.push(...validateManualMapping(input.manual));
  let requestPath: string | null = null;
  if (addr && errors.length === 0) requestPath = input.protocol === 'searxng' ? searxngPath(addr.path) : addr.path || '/';
  return { ok: errors.length === 0, errors: [...new Set(errors)], warnings, origin: addr ? keyBindingOrigin(input.address) : null, requestPath };
}

export type SearchKeyNormalization = { ok: true; key: string } | { ok: false; error: 'key_empty' | 'key_invalid' };

/**
 * Key pasted by the user (same for presets and custom services): trimmed at save time; empty -> key_empty; not 1-1024 printable ASCII characters (0x21-0x7E,
 * i.e. no whitespace, control characters or non-ASCII) -> key_invalid - it goes into an HTTP header, and the HTTP libraries on all three platforms reject non-ASCII header values.
 * The saved value is used when sending and is not altered again.
 */
export function normalizeSearchKey(raw: unknown): SearchKeyNormalization {
  const key = typeof raw === 'string' ? raw.trim() : '';
  if (!key) return { ok: false, error: 'key_empty' };
  if (!/^[\x21-\x7e]{1,1024}$/.test(key)) return { ok: false, error: 'key_invalid' };
  return { ok: true, key };
}

export type CatalogOutage = { usable: boolean; creatable: boolean; presentation?: 'presets_unavailable' };

/** Availability of each service kind when the preset catalog is unavailable (404 / signature failure / no snapshot). */
export function catalogOutageBehavior({ protocol, saved, catalogAvailable }: { protocol: string; saved?: boolean; catalogAvailable: boolean }): CatalogOutage {
  if (catalogAvailable) return { usable: true, creatable: true };
  if (protocol === 'preset') return { usable: false, creatable: false, presentation: 'presets_unavailable' };
  if (protocol === 'same_as') return { usable: saved === true, creatable: false };
  return { usable: true, creatable: true };
}
