/**
 * Studio style / effect presets Store: serves the persisted Server presets for the
 * cached locale, otherwise the bundled offline snapshot; refreshes at most every
 * 6 hours from GET /api/studio/presets with If-None-Match. Not wired to any entry yet.
 */
import { resolveMetadataBackendURL } from '../metadata/metadata-client';
import { safeLocalStorage } from '../../infra/storage/web-storage';
import {
  applyStudioPresetResponse,
  bundledStudioPresetsSnapshot,
  decodeStudioPresets,
  localizeStudioPresets,
  planStudioPresetRefresh,
  type StudioPresetApplyOutcome,
  type StudioPresetCache,
  type StudioPresetResponse,
  type StudioPresets,
} from './presets';

export const STUDIO_PRESETS_STORAGE_KEY = 'oriveo.studio.presets.v1';

const REQUEST_TIMEOUT_MS = 15_000;
const MAX_BODY_BYTES = 1024 * 1024;

export interface StudioPresetsStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export interface StudioPresetsStoreOptions {
  fetch?: typeof fetch;
  /** null = no persistence. Defaults to the guarded localStorage facade (no-op under SSR / denied storage). */
  storage?: StudioPresetsStorage | null;
  now?: () => number;
  backendURL?: string | (() => string);
}

/** `throttled` = the 6-hour window has not elapsed, no request was made. */
export type StudioPresetsRefreshOutcome = StudioPresetApplyOutcome | 'throttled';

export interface StudioPresetsStore {
  /** null only when even the bundled snapshot does not decode. */
  current(locale: string): StudioPresets | null;
  refreshIfNeeded(locale: string, nowMs?: number): Promise<StudioPresetsRefreshOutcome>;
}

interface PersistedPresets {
  cache: StudioPresetCache;
  body: unknown;
}

function parsePersisted(raw: string | null): PersistedPresets | null {
  if (raw === null) return null;
  try {
    const value = JSON.parse(raw) as { cache?: unknown; body?: unknown } | null;
    const cache = value && typeof value === 'object' ? (value.cache as Partial<StudioPresetCache> | null) : null;
    if (
      !cache || typeof cache !== 'object'
      || typeof cache.locale !== 'string'
      || typeof cache.revision !== 'string'
      || !(cache.etag === null || typeof cache.etag === 'string')
      || typeof cache.checkedAtMs !== 'number' || !Number.isFinite(cache.checkedAtMs)
    ) return null;
    return {
      cache: { locale: cache.locale, revision: cache.revision, etag: cache.etag, checkedAtMs: cache.checkedAtMs },
      body: value?.body,
    };
  } catch {
    return null;
  }
}

function offlinePresets(locale: string): StudioPresets | null {
  try {
    const decoded = decodeStudioPresets(localizeStudioPresets(bundledStudioPresetsSnapshot(), locale));
    // The bundled snapshot is covered by the shared snapshotCases; null here is a build defect, not a crash.
    return decoded.error === null ? decoded : null;
  } catch {
    return null;
  }
}

// RFC 3986 unreserved characters only: encodeURIComponent also leaves ! ' ( ) * as-is.
function encodeLocale(locale: string): string {
  return encodeURIComponent(locale).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
}

export function createStudioPresetsStore(options: StudioPresetsStoreOptions = {}): StudioPresetsStore {
  const doFetch = options.fetch ?? ((input: RequestInfo | URL, init?: RequestInit) => fetch(input, init));
  const storage = options.storage === undefined ? safeLocalStorage : options.storage;
  const now = options.now ?? Date.now;
  const backendURL = options.backendURL ?? resolveMetadataBackendURL;

  const readStorage = (): string | null => {
    try {
      return storage ? storage.getItem(STUDIO_PRESETS_STORAGE_KEY) : null;
    } catch {
      return null;
    }
  };

  let state: PersistedPresets | null = parsePersisted(readStorage());
  const offlineByLocale = new Map<string, StudioPresets | null>();
  let decodedBody: { body: unknown; presets: StudioPresets | null } | null = null;
  // At most one request per store: same-locale callers share the queued / running refresh,
  // other locales wait for it to settle first.
  const pending = new Map<string, Promise<StudioPresetsRefreshOutcome>>();
  let tail: Promise<unknown> = Promise.resolve();

  // Decoded persisted presets, memoized by body; null = missing or undecodable body.
  const persistedPresets = (from: PersistedPresets | null): StudioPresets | null => {
    if (!from) return null;
    if (!decodedBody || decodedBody.body !== from.body) {
      const decoded = decodeStudioPresets(from.body);
      decodedBody = { body: from.body, presets: decoded.error === null ? decoded : null };
    }
    return decodedBody.presets;
  };

  // A cache whose body is missing or does not decode is planned as no cache (fetch now, no If-None-Match).
  const usableCache = (from: PersistedPresets | null): StudioPresetCache | null =>
    from && persistedPresets(from) ? from.cache : null;

  const persist = (next: PersistedPresets): void => {
    state = next;
    try {
      storage?.setItem(STUDIO_PRESETS_STORAGE_KEY, JSON.stringify(next));
    } catch {
      // Storage unavailable: keep the in-memory copy only.
    }
  };

  const offline = (locale: string): StudioPresets | null => {
    if (!offlineByLocale.has(locale)) offlineByLocale.set(locale, offlinePresets(locale));
    return offlineByLocale.get(locale) ?? null;
  };

  async function request(locale: string, ifNoneMatch: string | null): Promise<StudioPresetResponse> {
    const base = (typeof backendURL === 'function' ? backendURL() : backendURL).replace(/\/+$/, '');
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (ifNoneMatch) headers['If-None-Match'] = ifNoneMatch;
    // One deadline for the whole exchange, body included.
    const signal = AbortSignal.timeout(REQUEST_TIMEOUT_MS);
    let res: Response;
    try {
      res = await doFetch(`${base}/api/studio/presets?locale=${encodeLocale(locale)}`, {
        headers,
        cache: 'no-store',
        signal,
      });
    } catch {
      return { status: 0 };
    }
    const etag = res.headers.get('ETag');
    if (res.status !== 200) return { status: res.status, etag };
    let text: string;
    try {
      text = await res.text();
    } catch {
      return { status: 0 };
    }
    // Unreadable or oversized 200 body -> applyResponse classifies it as invalid.
    if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) return { status: 200, etag, body: undefined };
    try {
      return { status: 200, etag, body: JSON.parse(text) as unknown };
    } catch {
      return { status: 200, etag, body: undefined };
    }
  }

  async function refresh(locale: string, nowMs: number): Promise<StudioPresetsRefreshOutcome> {
    const plan = planStudioPresetRefresh({ cache: usableCache(state), locale, nowMs });
    if (!plan.fetch) return 'throttled';
    const response = await request(locale, plan.ifNoneMatch);
    // Re-read the state after the await: another refresh may have landed meanwhile.
    const latest = state;
    const result = applyStudioPresetResponse({ cache: usableCache(latest), locale, nowMs, response });
    if (result.outcome === 'replaced' && result.cache) {
      persist({ cache: result.cache, body: response.body });
    } else if ((result.outcome === 'not_modified' || result.outcome === 'unchanged') && result.cache && latest) {
      persist({ cache: result.cache, body: latest.body });
    }
    return result.outcome;
  }

  return {
    current(locale) {
      const cached = state && state.cache.locale === locale ? persistedPresets(state) : null;
      return cached ?? offline(locale);
    },

    refreshIfNeeded(locale, nowMs) {
      const existing = pending.get(locale);
      if (existing) return existing;
      const run = tail
        .then(() => refresh(locale, nowMs ?? now()))
        .finally(() => {
          pending.delete(locale);
        });
      tail = run.catch(() => undefined);
      pending.set(locale, run);
      return run;
    },
  };
}
