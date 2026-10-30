/**
 * Data layer of the web search settings page (external search service contract section 11a): adopted catalog, local service view, model connections, test search.
 *
 * - Catalog: GET /api/search/catalog (the same server-side loader as the forward route), cached in memory for 5 minutes, never written to localStorage.
 * - Test search: always via POST /api/search/forward (the only outbound path on Web); the caller saves only if it passes.
 * - UI rules (grouping, row state, default, consent sentence, test presentation, field hints) come only from core/search/search-settings.
 */

import { getProviderDisplayName } from '@oriveo/config';
import { providerFormOf } from '../core/capability/truth/provider-form';
import type { Provider } from '@oriveo/shared';
import type { CatalogEntry } from '@oriveo/core/search/search-catalog';
import { classifySearchError, type CustomProtocol, type SearchResult, type TransportSpec } from '@oriveo/core/search/search-transport';
import {
  RESULT_COUNT_DEFAULT,
  resolveDefaultSearchService,
  searchResultCount,
  searchServiceDisplayName,
  searchServiceRowState,
  type SearchKeySource,
  type SearchServiceRowState,
  type SearchTestOutcome,
} from '@oriveo/core/search/search-settings';
import {
  getDefaultSearchServiceId,
  listSearchServices,
  readSearchServiceKey,
  type StoredSearchService,
} from './search-service-store';
import { resolveBaseURL } from '../core/providers/transport/endpoint-resolver';

export const SETTINGS_CATALOG_TTL_MS = 5 * 60 * 1000;

export interface SettingsCatalog {
  available: boolean;
  /** Entries that passed validation and are not withdrawn, in catalog order */
  entries: CatalogEntry[];
  withdrawn: string[];
}

const UNAVAILABLE: SettingsCatalog = { available: false, entries: [], withdrawn: [] };

let cached: { at: number; value: SettingsCatalog } | null = null;
let inflight: Promise<SettingsCatalog> | null = null;

/** The settings page's adopted catalog; fetch failure = presets unavailable (custom services work as usual). */
export function loadSettingsCatalog({ force = false }: { force?: boolean } = {}): Promise<SettingsCatalog> {
  if (!force && cached && Date.now() - cached.at < SETTINGS_CATALOG_TTL_MS) return Promise.resolve(cached.value);
  if (inflight) return inflight;
  inflight = (async () => {
    try {
      const res = await fetch('/api/search/catalog', { headers: { Accept: 'application/json' }, cache: 'no-store' });
      if (!res.ok) return UNAVAILABLE;
      const body = (await res.json()) as Partial<SettingsCatalog>;
      const value: SettingsCatalog = body.available === true
        ? { available: true, entries: Array.isArray(body.entries) ? body.entries : [], withdrawn: Array.isArray(body.withdrawn) ? body.withdrawn : [] }
        : UNAVAILABLE;
      cached = { at: Date.now(), value };
      return value;
    } catch {
      return UNAVAILABLE;
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

/** The already-cached adopted catalog (new or stale, sends no request); this page has not fetched yet = null. The pre-send route uses only this. */
export function cachedSettingsCatalog(): SettingsCatalog | null {
  return cached?.value ?? null;
}

/** Test hook: drop the catalog cache. */
export function __resetSettingsCatalogForTests(): void {
  cached = null;
  inflight = null;
}

/** Display names always go through searchServiceDisplayName: presets use adopted catalog -> name stored at save time -> serviceId. */
export function serviceDisplayName(catalog: SettingsCatalog | null, service: StoredSearchService): string {
  if (service.kind === 'custom') return searchServiceDisplayName({ kind: 'custom', name: service.name });
  return searchServiceDisplayName({
    kind: 'preset',
    name: service.name ?? null,
    serviceId: service.serviceId,
    catalogDisplayName: catalog?.entries.find((e) => e.id === service.serviceId)?.displayName ?? null,
  });
}

// ── Model connections (reusing a key) ────────────────────────────────────────────────

export interface SearchConnectionOption {
  id: string;
  name: string;
  providerKind: string;
  baseUrl: string | null;
  apiKey: string;
}

/**
 * Model connections reusable on this device (in connection list order): only official BYOK (providerFormOf = official), API key auth, with a key on this device.
 * The address comes from resolveBaseURL, the single entry point for the actual request address on this client (including official site selection; empty falls back to that provider's default address).
 */
export function searchConnectionsFromProviders(providers: readonly Provider[]): SearchConnectionOption[] {
  return providers
    // Only official BYOK connections count (judged by shape, not by comparing kind): hosted / free / relay / subscription logins are not reusable user keys.
    .filter((p) => providerFormOf(p) === 'official' && (p.authMode ?? 'apiKey') === 'apiKey')
    .filter((p) => typeof p.apiKey === 'string' && p.apiKey.trim().length > 0)
    .map((p) => {
      let baseUrl: string | null;
      try {
        baseUrl = resolveBaseURL(p, p.kind) || null;
      } catch {
        baseUrl = null;
      }
      return {
        id: p.id,
        name: p.customName?.trim() || getProviderDisplayName(p.kind),
        providerKind: p.kind,
        baseUrl,
        apiKey: p.apiKey,
      };
    });
}

// ── Local service view ─────────────────────────────────────────────────────

export interface SearchServiceView {
  record: StoredSearchService;
  name: string;
  keySource: SearchKeySource;
  hasKey: boolean;
  /** Last 4 characters of the user's own stored key (detail page "Saved ••••xxxx") */
  keyTail: string | null;
  row: SearchServiceRowState;
  resultCount: number;
}

export interface SearchServicesSnapshot {
  services: SearchServiceView[];
  defaultId: string | null;
}

/** View of one stored service (row state, display name and count all follow core rules); for the key only presence and the last 4 characters are exposed. */
export function buildSearchServiceView(
  record: StoredSearchService,
  key: { hasKey: boolean; keyTail: string | null },
  catalog: SettingsCatalog | null,
  connections: readonly SearchConnectionOption[],
): SearchServiceView {
  const keySource: SearchKeySource = record.kind === 'preset' && record.connectionRef ? 'connection' : key.hasKey ? 'own' : record.kind === 'preset' ? 'own' : 'none';
  const entry = record.kind === 'preset' ? catalog?.entries.find((e) => e.id === record.serviceId) ?? null : null;
  const row = searchServiceRowState({
    service: record.kind === 'preset'
      ? { kind: 'preset', serviceId: record.serviceId, regionId: record.regionId, boundHost: record.boundHost, keySource, connectionRef: record.connectionRef, hasKey: key.hasKey }
      : { kind: 'custom', keySource, hasKey: key.hasKey },
    catalogAvailable: catalog?.available ?? false,
    entry,
    withdrawn: record.kind === 'preset' && (catalog?.withdrawn.includes(record.serviceId) ?? false),
    connections,
  });
  return {
    record,
    name: serviceDisplayName(catalog, record),
    keySource,
    hasKey: key.hasKey,
    keyTail: key.keyTail,
    row,
    resultCount: searchResultCount(record.resultCount),
  };
}

export async function loadSearchServicesSnapshot(
  uid: string,
  catalog: SettingsCatalog | null,
  connections: readonly SearchConnectionOption[],
): Promise<SearchServicesSnapshot> {
  const [records, storedDefault] = await Promise.all([listSearchServices(uid), getDefaultSearchServiceId(uid)]);
  const services: SearchServiceView[] = [];
  for (const record of records.filter((r) => !r.pendingAdd)) {
    const key = await readSearchServiceKey(uid, record.id);
    services.push(buildSearchServiceView(record, { hasKey: !!key, keyTail: key ? key.slice(-4) : null }, catalog, connections));
  }
  const defaultId = resolveDefaultSearchService({ serviceIds: services.map((s) => s.record.id), storedDefault });
  return { services, defaultId };
}

// ── Rough check of custom addresses (the forward route's assertUrlNotSsrf is final) ──────────

function ipv4Private(host: string): boolean {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(host);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

/** The browser cannot get DNS: judge only by IP literal (private / loopback / link-local literal = lan), and hand everything else to the server as public. */
export function webAddressClass(address: string): 'public' | 'lan' {
  let host: string;
  try {
    host = new URL(address.trim()).hostname.toLowerCase();
  } catch {
    return 'public';
  }
  if (host === 'localhost' || host.endsWith('.localhost')) return 'lan';
  if (ipv4Private(host)) return 'lan';
  const v6 = host.replace(/^\[|\]$/g, '');
  if (v6.includes(':') && (v6 === '::1' || /^f[cd]/.test(v6) || /^fe[89ab]/.test(v6))) return 'lan';
  return 'public';
}

// ── Test search (via /api/search/forward) ───────────────────────────────

export type SearchForwardTarget =
  | { kind: 'preset'; serviceId: string; regionId: string; boundHost: string }
  | { kind: 'custom'; address: string; protocol: CustomProtocol; mapping: TransportSpec | null };

export interface SearchTestRequest {
  target: SearchForwardTarget;
  key: string | null;
  query: string;
  count?: number;
  otherServices?: number;
}

type ForwardJson =
  | { ok: true; kind?: string; results?: unknown[] }
  | { ok: false; errorClass?: string; retryOnce?: boolean; sent?: boolean; card?: { headline?: string; primaryAction?: string; secondaryAction?: string } }
  | { error?: string; errors?: string[] };

/** One search via /api/search/forward (shared by the test search and the chat executor). */
export type SearchForwardOutcome =
  | { ok: true; results: SearchResult[]; latencyMs: number }
  | {
    ok: false;
    errorClass: string | null;
    retryOnce: boolean;
    card: { headline?: string; primaryAction?: string; secondaryAction?: string } | null;
    /** Whether the request reached the search service (false when the pre-send check failed or the local / route refused to send: not billed, not counted). */
    sent: boolean;
    latencyMs: number;
  };

/** Send one search: request construction and result mapping live only here (the key exists only within this request). */
export async function forwardSearch(request: SearchTestRequest, fetchImpl: typeof fetch = fetch, signal?: AbortSignal): Promise<SearchForwardOutcome> {
  const custom = request.target.kind === 'custom';
  const now = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());
  const started = now();
  const failWith = (input: Parameters<typeof classifySearchError>[0], sent: boolean): SearchForwardOutcome => {
    const classified = classifySearchError({ ...input, custom });
    return { ok: false, errorClass: classified.errorClass, retryOnce: classified.retryOnce, card: classified.card, sent, latencyMs: now() - started };
  };
  let res: Response;
  try {
    res = await fetchImpl('/api/search/forward', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      cache: 'no-store',
      body: JSON.stringify({
        ...request.target,
        query: request.query,
        count: request.count ?? RESULT_COUNT_DEFAULT,
        key: request.key,
        otherServices: request.otherServices ?? 0,
      }),
      ...(signal ? { signal } : {}),
    });
  } catch (error) {
    if (signal?.aborted) throw error;
    return failWith({ transportFailure: 'network' }, true);
  }
  const latencyMs = now() - started;
  let body: ForwardJson | null = null;
  try {
    body = (await res.json()) as ForwardJson;
  } catch {
    body = null;
  }
  // 429 = the forward route's own rate limit: the request never reached the search service
  if (res.status === 429) return failWith({ status: 429 }, false);
  // 400 = rejected by the route (including the server's SSRF verdict of private / unresolvable): shown as request refused, nothing was sent
  if (res.status === 400) return failWith({ transportFailure: 'blocked' }, false);
  if (!res.ok || !body || !('ok' in body)) return failWith({ transportFailure: 'network' }, true);
  if (body.ok) {
    const results = Array.isArray(body.results) ? (body.results as SearchResult[]) : [];
    return { ok: true, results, latencyMs };
  }
  return {
    ok: false,
    errorClass: body.errorClass ?? null,
    retryOnce: body.retryOnce === true,
    card: body.card ?? null,
    sent: body.sent !== false,
    latencyMs,
  };
}

/** Run one test search and give the result to searchTestPresentation. The key exists only within this request. */
export async function runSearchTest(request: SearchTestRequest, fetchImpl: typeof fetch = fetch): Promise<SearchTestOutcome> {
  const outcome = await forwardSearch(request, fetchImpl);
  if (outcome.ok) return { ok: true, count: outcome.results.length, latencyMs: outcome.latencyMs };
  return { ok: false, error: { errorClass: outcome.errorClass, card: outcome.card } };
}

/** Error headline key (snake) -> copy key `error.*` (camel); likewise for actions. */
export function camelKey(snake: string): string {
  return snake.replace(/_([a-z])/g, (_, c: string) => c.toUpperCase());
}
