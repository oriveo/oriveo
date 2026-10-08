/**
 * Shell for the chat streaming metadata layer.
 *
 * The pure logic (resolve, build, deepMerge, types, ProviderValidationContract) lives in
 * `@oriveo/core/providers/request-builders/runtime` and is re-exported here so the 20+ importers
 * need no change. Only IO stays here: `getRuntimeMetadata` (the /api/metadata index plus the
 * catalog for one provider kind, with a TTL cache) and the test reset hook.
 */
export * from '@oriveo/core/providers/request-builders/runtime';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import { PUBLIC_METADATA_BASE_URL } from '@oriveo/shared';
import {
  assembleLeanFromSplit,
  expandMetadataCatalog,
  indexCatalogRevision,
  isMetadataIndexPayload,
  type ExpandedMetadataCatalog,
  type MetadataIndexPayload,
} from '../../../../lib/core/metadata/metadata-split';

type SnapshotEntry =
  | { kind: 'split'; index: MetadataIndexPayload; etag: string | null; expiresAt: number }
  /** A lean/full snapshot, from a server that answers the index with 400 or ignores the view parameter; its etag only goes back to the URL that issued it. */
  | { kind: 'lean'; data: RuntimeMetadataResponse; etag: string | null; etagView: 'index' | 'lean'; expiresAt: number };

interface CatalogEntry {
  catalog: ExpandedMetadataCatalog;
  etag: string | null;
}

const METADATA_TTL = 5 * 60 * 1000;
let snapshot: SnapshotEntry | null = null;
/** Only one index request may be in flight at a time, so concurrent sends at the instant the TTL expires do not each fetch their own copy. */
let inflight: Promise<SnapshotEntry | null> | null = null;
/** Last-good catalog per provider; not requested again while its revision matches the index. */
const catalogs = new Map<string, CatalogEntry>();
/** In-flight catalog fetches, deduplicated per kind. */
const catalogInflight = new Map<string, Promise<void>>();
/** Assembled results memoized on the identity of (index, catalog): the same inputs return the same object. */
const assembled = new Map<string, { index: MetadataIndexPayload; catalog: CatalogEntry | undefined; data: RuntimeMetadataResponse }>();

/**
 * This path runs on every message send, so each of its jobs takes the cheapest route:
 *
 * - Index plus on-demand catalog: a request only needs provider-level fields and the catalog of
 *   the provider it targets. The index (global config plus provider-level fields) comes first,
 *   then only the catalog for `providerKind`, reassembled in memory into a lean-shaped object for
 *   the core request builder (which accepts the parametersRef + generationParameterTables shape).
 *   A catalog whose revision matches the index is not requested again.
 * - Compatibility fallback: a server that answers view=index with 400 is read through `view=lean`,
 *   exactly as before.
 * - Conditional requests: the index, each catalog and the lean view each carry their own ETag, and
 *   validators never cross views. `cache: 'no-store'` stays, because validation happens here rather
 *   than in the Next Data Cache.
 * - In-flight deduplication: one index request globally, one catalog request per kind.
 */
export async function getRuntimeMetadata(providerKind?: string): Promise<RuntimeMetadataResponse | null> {
  const entry = await loadSnapshot();
  if (!entry) return null;
  if (entry.kind === 'lean') return entry.data;

  const kind = providerKind && entry.index.providers[providerKind] ? providerKind : undefined;
  if (kind) await ensureCatalog(kind);
  const current = snapshot?.kind === 'split' ? snapshot.index : entry.index;
  return assembleFor(current, kind);
}

/**
 * Re-checks the index with the backend right away instead of waiting for the TTL (a conditional
 * request with the ETag, so an unchanged index costs one 304).
 *
 * Subscription version headers are resolved from this snapshot. An upstream 426 means the value
 * in the snapshot is below the upstream minimum. Without this pull, every user on this instance
 * keeps being rejected for up to one more TTL after the published value has been corrected.
 * Joins a refresh that is already in flight.
 */
export async function refreshRuntimeMetadataNow(): Promise<void> {
  await refreshSnapshot();
}

async function loadSnapshot(): Promise<SnapshotEntry | null> {
  if (snapshot && Date.now() < snapshot.expiresAt) return snapshot;
  return refreshSnapshot();
}

function refreshSnapshot(): Promise<SnapshotEntry | null> {
  if (inflight) return inflight;
  inflight = (async () => {
    try {
      return await fetchSnapshot();
    } catch {
      return snapshot;
    } finally {
      inflight = null;
    }
  })();
  return inflight;
}

async function fetchSnapshot(): Promise<SnapshotEntry | null> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  const validator = snapshot?.kind === 'split'
    ? snapshot.etag
    : snapshot?.kind === 'lean' && snapshot.etagView === 'index'
      ? snapshot.etag
      : null;
  if (validator) headers['If-None-Match'] = validator;

  const res = await fetch(`${resolveMetadataBackendURL()}/api/metadata?view=index`, {
    headers,
    cache: 'no-store',
  });

  // A 304 is outside the range of res.ok, so it has to be checked before !res.ok: the content is unchanged and only the TTL is renewed.
  if (res.status === 304 && snapshot && validator) {
    snapshot = { ...snapshot, expiresAt: Date.now() + METADATA_TTL };
    return snapshot;
  }
  if (res.status === 400) return fetchLeanSnapshot();
  if (!res.ok) return snapshot;

  const payload = await res.json() as { data?: unknown } | unknown;
  const data = unwrapRuntimeMetadata(payload);
  if (isMetadataIndexPayload(data)) {
    snapshot = { kind: 'split', index: data, etag: res.headers.get('ETag'), expiresAt: Date.now() + METADATA_TTL };
    return snapshot;
  }
  snapshot = {
    kind: 'lean',
    data: data as RuntimeMetadataResponse,
    etag: res.headers.get('ETag'),
    etagView: 'index',
    expiresAt: Date.now() + METADATA_TTL,
  };
  return snapshot;
}

/** Fallback for older servers: the full lean view, exactly as before the split view existed. */
async function fetchLeanSnapshot(): Promise<SnapshotEntry | null> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  const validator = snapshot?.kind === 'lean' && snapshot.etagView === 'lean' ? snapshot.etag : null;
  if (validator) headers['If-None-Match'] = validator;
  const res = await fetch(`${resolveMetadataBackendURL()}/api/metadata?view=lean`, {
    headers,
    cache: 'no-store',
  });
  if (res.status === 304 && snapshot && validator) {
    snapshot = { ...snapshot, expiresAt: Date.now() + METADATA_TTL };
    return snapshot;
  }
  if (!res.ok) return snapshot;
  const payload = await res.json() as { data?: unknown } | unknown;
  snapshot = {
    kind: 'lean',
    data: unwrapRuntimeMetadata(payload) as RuntimeMetadataResponse,
    etag: res.headers.get('ETag'),
    etagView: 'lean',
    expiresAt: Date.now() + METADATA_TTL,
  };
  return snapshot;
}

async function ensureCatalog(kind: string): Promise<void> {
  const existing = catalogInflight.get(kind);
  if (existing) return existing;
  const promise = (async () => {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      if (snapshot?.kind !== 'split') return;
      const expected = indexCatalogRevision(snapshot.index, kind);
      if (!expected) return;
      const stored = catalogs.get(kind);
      if (stored?.catalog.revision === expected) return;
      const outcome = await fetchCatalog(kind, expected, stored);
      if (outcome !== 'revision_mismatch') return;
      // The revision disagrees with the index (most likely a snapshot activation landed in between):
      // refetch the index once and retry; if it still disagrees, keep the last-good copy.
      if (attempt === 0) await refreshSnapshot();
    }
  })().catch(() => {}).finally(() => {
    catalogInflight.delete(kind);
  });
  catalogInflight.set(kind, promise);
  return promise;
}

async function fetchCatalog(
  kind: string,
  expectedRevision: string,
  stored: CatalogEntry | undefined,
): Promise<'accepted' | 'revision_mismatch' | 'kept'> {
  const headers: Record<string, string> = { Accept: 'application/json' };
  if (stored?.etag) headers['If-None-Match'] = stored.etag;
  const res = await fetch(
    `${resolveMetadataBackendURL()}/api/metadata?view=catalog&provider=${encodeURIComponent(kind)}`,
    { headers, cache: 'no-store' },
  );
  if (res.status === 304 && stored?.etag) {
    return stored.catalog.revision === expectedRevision ? 'kept' : 'revision_mismatch';
  }
  // A 404 is not an empty catalog; like any other failure it keeps the last-good copy.
  if (!res.ok) return 'kept';
  const payload = await res.json() as { data?: unknown } | unknown;
  const expanded = expandMetadataCatalog(unwrapRuntimeMetadata(payload), {
    provider: kind,
    revision: expectedRevision,
  });
  if (!expanded.ok) {
    // Unresolved ref or malformed shape: reject the whole catalog and keep the last-good copy.
    return expanded.reason === 'revision_mismatch' ? 'revision_mismatch' : 'kept';
  }
  catalogs.set(kind, { catalog: expanded.catalog, etag: res.headers.get('ETag') });
  return 'accepted';
}

function assembleFor(index: MetadataIndexPayload, kind: string | undefined): RuntimeMetadataResponse {
  const key = kind ?? '';
  const catalog = kind ? catalogs.get(kind) : undefined;
  const memo = assembled.get(key);
  if (memo && memo.index === index && memo.catalog === catalog) return memo.data;
  const loaded = new Map<string, ExpandedMetadataCatalog>();
  if (kind && catalog) loaded.set(kind, catalog.catalog);
  // Other providers appear with their index fields and empty models: validation and subscription
  // auth only read provider-level fields.
  const data = assembleLeanFromSplit(index, loaded, { includeIndexOnlyProviders: true }) as unknown as RuntimeMetadataResponse;
  assembled.set(key, { index, catalog, data });
  return data;
}

export function __resetRuntimeMetadataCache(): void {
  snapshot = null;
  inflight = null;
  catalogs.clear();
  catalogInflight.clear();
  assembled.clear();
}

function unwrapRuntimeMetadata(payload: unknown): unknown {
  if (payload && typeof payload === 'object' && 'data' in payload) {
    return (payload as { data?: unknown }).data ?? payload;
  }
  return payload;
}

function resolveMetadataBackendURL(): string {
  const configured = process.env.NEXT_PUBLIC_BACKEND_URL?.trim().replace(/\/+$/, '')
    || process.env.BACKEND_URL?.trim().replace(/\/+$/, '');
  return configured || PUBLIC_METADATA_BASE_URL;
}
