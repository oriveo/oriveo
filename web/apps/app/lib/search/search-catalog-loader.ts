/**
 * Server-side loading of the external search catalog (external search service contract section 8): GET /api/metadata?view=search, with an in-memory TTL cache.
 *
 * It starts from the snapshot bundled with the install (core `SEARCH_CATALOG_SNAPSHOT_VIEW`); both the network catalog and the snapshot go through `acceptSearchCatalog`
 * signature-verified adoption (production keys `SEARCH_CATALOG_PRODUCTION_KEYS`). Fetch results are handled per `catalogFetchAction`: 200 adopts;
 * 404 withdraws the presets (including the bundled snapshot, flagged in-process until a 200 is obtained and adopted successfully -- including an unchanged same-revision result -- which clears it);
 * 304 / other statuses (including the 400 an older server returns for an unknown view) / network errors keep the previous copy.
 * Withdrawn, or no catalog ever adopted = presets unavailable (`getSearchCatalog()` returns null).
 *
 * Used only on the Node runtime (the search forward route); written after getRuntimeMetadata in app/api/chat/stream/runtime.ts.
 */

import {
  acceptSearchCatalog,
  catalogFetchAction,
  validateCatalogEntry,
  type CatalogEntry,
  type CatalogSource,
  type CatalogState,
  type ClampedLimits,
} from '@oriveo/core/search/search-catalog';
import { SEARCH_CATALOG_PRODUCTION_KEYS } from '@oriveo/core/search/catalog-keys';
import { SEARCH_CATALOG_SNAPSHOT_VIEW } from '@oriveo/core/search/catalog-snapshot';

export const SEARCH_CATALOG_TTL_MS = 5 * 60 * 1000;

export interface ActiveSearchService {
  entry: CatalogEntry;
  /** Timeout / entry count after clamping to the client's hard limits at adoption */
  limits: ClampedLimits;
}

export interface LoadedSearchCatalog {
  revision: number;
  source: CatalogSource;
  active: ReadonlyMap<string, ActiveSearchService>;
  withdrawn: ReadonlySet<string>;
}

export interface SearchCatalogLoaderOptions {
  trustedKeys?: Readonly<Record<string, string>>;
  /** Bundled snapshot (the ?view=search response as-is, or the catalog body); null = no snapshot */
  builtin?: unknown;
  fetchView?: () => Promise<Response>;
  ttlMs?: number;
  now?: () => number;
}

export interface SearchCatalogLoader {
  get(): Promise<LoadedSearchCatalog | null>;
  refreshNow(): Promise<LoadedSearchCatalog | null>;
}

/** The ?view=search response envelope is { code, data, message }; a bare catalog body is also accepted. */
function unwrapView(payload: unknown): unknown {
  if (payload && typeof payload === 'object' && 'data' in payload && !('schema' in payload)) {
    return (payload as { data?: unknown }).data;
  }
  return payload;
}

function resolveSearchCatalogBackendURL(): string {
  const configured = process.env.NEXT_PUBLIC_BACKEND_URL?.trim().replace(/\/+$/, '')
    || process.env.BACKEND_URL?.trim().replace(/\/+$/, '');
  if (configured) return configured;
  return 'http://localhost:8080';
}

function fetchSearchCatalogView(): Promise<Response> {
  return fetch(`${resolveSearchCatalogBackendURL()}/api/metadata?view=search`, {
    headers: { Accept: 'application/json' },
    cache: 'no-store',
  });
}

export function createSearchCatalogLoader(options: SearchCatalogLoaderOptions = {}): SearchCatalogLoader {
  const trustedKeys = options.trustedKeys ?? SEARCH_CATALOG_PRODUCTION_KEYS;
  const builtin = options.builtin === undefined ? SEARCH_CATALOG_SNAPSHOT_VIEW : options.builtin;
  const fetchView = options.fetchView ?? fetchSearchCatalogView;
  const ttlMs = options.ttlMs ?? SEARCH_CATALOG_TTL_MS;
  const now = options.now ?? Date.now;

  let state: CatalogState = { maxSeenRevision: 0, current: null };
  let catalog: LoadedSearchCatalog | null = null;
  // The backend explicitly says there is no catalog (404): presets are unavailable until an adoptable catalog is obtained again
  let unavailable = false;
  let builtinTried = false;
  let expiresAt = 0;
  let inflight: Promise<LoadedSearchCatalog | null> | null = null;

  const usable = (): LoadedSearchCatalog | null => (unavailable ? null : catalog);

  /** Adopt a catalog; returns true = the catalog in hand matches it (newly adopted or unchanged). */
  async function adopt(payload: unknown, source: CatalogSource): Promise<boolean> {
    const doc = unwrapView(payload);
    const verdict = await acceptSearchCatalog({ state, incoming: doc, source, trustedKeys });
    if (!verdict.accepted) return verdict.reason === 'unchanged';
    state = { maxSeenRevision: verdict.maxSeenRevision, current: verdict.current };
    // The adoption result carries only id + limits; forwarding needs the host and transport description, so match the raw entries in the same validation order
    const entries = ((doc as { services?: unknown }).services ?? []) as unknown[];
    const valid = (Array.isArray(entries) ? entries : []).filter((e) => validateCatalogEntry(e) === null) as CatalogEntry[];
    const active = new Map<string, ActiveSearchService>();
    const withdrawn = new Set<string>();
    verdict.current.services.forEach((service, index) => {
      if (service.status === 'withdrawn') {
        withdrawn.add(service.id);
        active.delete(service.id);
      } else if (!withdrawn.has(service.id) && !active.has(service.id) && valid[index]) {
        active.set(service.id, { entry: valid[index], limits: service.limits });
      }
    });
    catalog = { revision: verdict.current.revision, source, active, withdrawn };
    return true;
  }

  async function refresh(): Promise<LoadedSearchCatalog | null> {
    if (!builtinTried) {
      builtinTried = true;
      if (builtin !== null) await adopt(builtin, 'builtin').catch(() => false);
    }
    let res: Response | null = null;
    try {
      res = await fetchView();
    } catch {
      res = null;
    }
    const action = catalogFetchAction(res ? { status: res.status } : { transportFailure: 'network' });
    if (action === 'withdraw_presets') {
      unavailable = true;
    } else if (action === 'adopt' && res) {
      try {
        if (await adopt(await res.json(), 'network')) unavailable = false;
      } catch {
        // Body parse failed: keep the previous copy
      }
    }
    expiresAt = now() + ttlMs;
    return usable();
  }

  function refreshOnce(): Promise<LoadedSearchCatalog | null> {
    if (inflight) return inflight;
    inflight = refresh().finally(() => {
      inflight = null;
    });
    return inflight;
  }

  return {
    async get() {
      if (builtinTried && now() < expiresAt) return usable();
      return refreshOnce();
    },
    refreshNow: refreshOnce,
  };
}

type SearchCatalogGlobal = typeof globalThis & {
  __oriveoSearchCatalogLoader?: SearchCatalogLoader;
  __oriveoSearchCatalogLoaderOverride?: SearchCatalogLoader;
};

/** The currently usable preset catalog; null = presets unavailable. */
export function getSearchCatalog(): Promise<LoadedSearchCatalog | null> {
  const g = globalThis as SearchCatalogGlobal;
  if (g.__oriveoSearchCatalogLoaderOverride) return g.__oriveoSearchCatalogLoaderOverride.get();
  g.__oriveoSearchCatalogLoader ??= createSearchCatalogLoader();
  return g.__oriveoSearchCatalogLoader.get();
}

/** Test hook: swap the process-level loader (pass undefined to restore and drop the cache). */
export function __setSearchCatalogLoaderForTests(loader: SearchCatalogLoader | undefined): void {
  const g = globalThis as SearchCatalogGlobal;
  if (loader) g.__oriveoSearchCatalogLoaderOverride = loader;
  else {
    delete g.__oriveoSearchCatalogLoaderOverride;
    delete g.__oriveoSearchCatalogLoader;
  }
}
