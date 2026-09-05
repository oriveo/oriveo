import type { Event, ErrorEvent } from "@sentry/nextjs";

/**
 * Drop chunk-load and IndexedDB environment noise from Sentry.
 *
 * Chunk failures self-heal with a reload. IndexedDB "server lost" /
 * closing-connection errors are browser environment noise, not app bugs.
 * Provider upstream/network errors stay reportable.
 */

/** Fingerprints of stale chunk and dynamic import failures across webpack, ESM and Safari. */
const CHUNK_ERROR_PATTERNS = [
  /ChunkLoadError/i,
  /Loading chunk \S+ failed/i,
  /Failed to fetch dynamically imported module/i,
  /error loading dynamically imported module/i,
  /Importing a module script failed/i,
] as const;

/** IndexedDB environment / permission noise */
const IDB_NOISE_PATTERNS = [
  /Indexed Database server lost/i,
  /database connection is closing/i,
  /'transaction' on 'IDBDatabase'/i,
  /Internal error opening backing store/i,
  /is not, or is no longer, usable/i,
  /The user denied permission to access the database/i,
] as const;

/** Opaque cross-origin "Script error." */
const OPAQUE_SCRIPT_ERROR = /^Script error\.?$/i;

function matchesAny(patterns: readonly RegExp[], value: string | undefined): boolean {
  if (!value) return false;
  return patterns.some((pattern) => pattern.test(value));
}

/** Chunk load failure test against a raw Error, so an error boundary can decide whether to reload. */
export function isChunkLoadError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return matchesAny(CHUNK_ERROR_PATTERNS, error.name) || matchesAny(CHUNK_ERROR_PATTERNS, error.message);
}

/** Sentry beforeSend filter: a match returns true and the caller drops the event. */
export function isIgnorableBrowserNoiseError(event: Event): boolean {
  const values = (event as ErrorEvent).exception?.values ?? [];
  return values.some((entry) => {
    const haystack = entry.value;
    const typeName = entry.type;
    return (
      matchesAny(CHUNK_ERROR_PATTERNS, haystack)
      || matchesAny(CHUNK_ERROR_PATTERNS, typeName)
      || matchesAny(IDB_NOISE_PATTERNS, haystack)
      || OPAQUE_SCRIPT_ERROR.test(haystack ?? "")
    );
  });
}

/** sessionStorage gate key: at most one automatic reload per session, so a stale chunk cannot loop forever. */
export const CHUNK_RELOAD_STORAGE_KEY = "oriveo:chunk-reload";

/**
 * First chunk reload returns true; a second attempt in the same session
 * returns false so we do not loop.
 */
export function consumeChunkReloadAttempt(
  storage: Pick<Storage, "getItem" | "setItem">,
): boolean {
  if (storage.getItem(CHUNK_RELOAD_STORAGE_KEY) === "1") return false;
  storage.setItem(CHUNK_RELOAD_STORAGE_KEY, "1");
  return true;
}
