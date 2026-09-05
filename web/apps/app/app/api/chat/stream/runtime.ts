/**
 * Shell for the chat streaming metadata layer.
 *
 * The pure logic (resolve, build, deepMerge, types, ProviderValidationContract) lives in
 * `@oriveo/core/providers/request-builders/runtime` and is re-exported here so the 20+ importers
 * need no change. Only IO stays here: `getRuntimeMetadata` (the /api/metadata fetch plus its TTL
 * cache) and the test reset hook.
 */
export * from '@oriveo/core/providers/request-builders/runtime';
import type { RuntimeMetadataResponse } from '@oriveo/core/providers/request-builders/runtime';
import { PUBLIC_METADATA_BASE_URL } from '@oriveo/shared';

interface CacheEntry {
  data: RuntimeMetadataResponse;
  expiresAt: number;
  etag: string | null;
}

const METADATA_TTL = 5 * 60 * 1000;
let metadataCache: CacheEntry | null = null;
/** Only one request may be in flight at a time, so concurrent sends at the instant the TTL expires do not each fetch their own copy. */
let inflight: Promise<RuntimeMetadataResponse | null> | null = null;

/**
 * This path runs on every message send, so all three of its jobs take the cheapest route:
 *
 * - Lean view: request building only needs transport / endpoints / profiles. Lean drops
 *   modelFacts, per-model sourceSummary and the `$comment` of a recipe, and deduplicates each
 *   model `profiles.generation.parameters` into a `parametersRef` plus a shared
 *   `generationParameterTables`. resolveGenerationProfile in core already accepts both shapes,
 *   and request-builders never reads modelFacts or sourceSummary.
 * - Conditional requests: the server sends an ETag, so If-None-Match has to go out with the
 *   request. Without it a 304 never arrives and the full snapshot is downloaded again every time
 *   the TTL expires. `cache: 'no-store'` stays, because validation happens here rather than in
 *   the Next Data Cache.
 * - In-flight deduplication: requests arriving at the instant the TTL expires share one promise.
 */
export async function getRuntimeMetadata(): Promise<RuntimeMetadataResponse | null> {
  if (metadataCache && Date.now() < metadataCache.expiresAt) {
    return metadataCache.data;
  }
  if (inflight) return inflight;

  inflight = (async () => {
    try {
      const headers: Record<string, string> = { Accept: 'application/json' };
      if (metadataCache?.etag) headers['If-None-Match'] = metadataCache.etag;

      const res = await fetch(`${resolveMetadataBackendURL()}/api/metadata?view=lean`, {
        headers,
        cache: 'no-store',
      });

      // A 304 is outside the range of res.ok, so it has to be checked before !res.ok: the content is unchanged and only the TTL is renewed.
      if (res.status === 304 && metadataCache) {
        metadataCache = { ...metadataCache, expiresAt: Date.now() + METADATA_TTL };
        return metadataCache.data;
      }
      if (!res.ok) {
        return metadataCache?.data ?? null;
      }

      const payload = await res.json() as { data?: RuntimeMetadataResponse } | RuntimeMetadataResponse;
      const data = unwrapRuntimeMetadata(payload);
      metadataCache = {
        data,
        expiresAt: Date.now() + METADATA_TTL,
        etag: res.headers.get('ETag'),
      };
      return data;
    } catch {
      return metadataCache?.data ?? null;
    } finally {
      inflight = null;
    }
  })();

  return inflight;
}

export function __resetRuntimeMetadataCache(): void {
  metadataCache = null;
  inflight = null;
}

function unwrapRuntimeMetadata(
  payload: { data?: RuntimeMetadataResponse } | RuntimeMetadataResponse,
): RuntimeMetadataResponse {
  return (payload as { data?: RuntimeMetadataResponse }).data ?? (payload as RuntimeMetadataResponse);
}

function resolveMetadataBackendURL(): string {
  const configured = process.env.NEXT_PUBLIC_BACKEND_URL?.trim().replace(/\/+$/, '')
    || process.env.BACKEND_URL?.trim().replace(/\/+$/, '');
  return configured || PUBLIC_METADATA_BASE_URL;
}
