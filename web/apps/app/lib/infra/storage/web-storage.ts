/**
 * Safe facade over Web Storage.
 *
 * Why this layer exists: when the browser blocks site data, **the property access itself**
 * throws `SecurityError: Failed to read the 'localStorage' property from 'Window'` - the getter
 * throws, not `getItem`. Common guards such as `typeof localStorage === 'undefined'` or
 * `'localStorage' in window` are therefore **useless**: they blow up on their own.
 *
 * Seen in production on Chrome Mobile 149 / Android: step 1 of `bootstrapApp`,
 * `migrateToPartitionedStorage()`, read localStorage raw, threw SecurityError, and the whole try
 * block jumped to catch - later metadata and provider hydration never ran and the user landed
 * in an empty app shell.
 *
 * So: **never touch `localStorage` / `sessionStorage` directly anywhere in the app**, always go
 * through here. Reads return null on failure, writes return false, and nothing ever throws.
 */

import * as Sentry from '@sentry/nextjs';

/**
 * Storage availability.
 *   - `available`: readable and writable
 *   - `denied`: the browser refuses access (site data disabled, some private modes) - **site-wide degradation signal**
 *   - `unsupported`: not implemented (SSR, old engines)
 */
export type StorageAvailability = 'available' | 'denied' | 'unsupported';

/** Write failure reason. `quota` is only knowable at write time and is not a probe result; `oversize` is this facade's own per-key limit. */
export type StorageWriteFailure = 'quota' | 'denied' | 'unsupported' | 'oversize';

/**
 * Per-key write limit (key + value, in UTF-16 code units).
 *
 * In Chrome, localStorage is a 5MB per-origin quota shared by the whole site. A convention that
 * structured caches over a few tens of KB belong in blob-cache is not enforceable by review
 * alone - a 3.3MB metadata snapshot once ate 66% of the quota. So it becomes a runtime fact:
 * oversized writes are refused, large objects go to `blob-cache.ts` (IndexedDB, disk-scaled).
 */
export const LOCAL_STORAGE_MAX_ITEM_CHARS = 64 * 1024;

interface SafeStorage {
  getItem(key: string): string | null;
  /** @returns whether the write succeeded; never throws on failure */
  setItem(key: string, value: string): boolean;
  removeItem(key: string): boolean;
  /** Snapshot of every current key; empty array when unavailable. Deleting while iterating is safe (snapshot is taken first). */
  keys(): string[];
  /** Reason for the most recent write failure; cleared after a successful write */
  lastWriteFailure(): StorageWriteFailure | null;
}

/** SecurityError = refused by the user or a policy; anything else (ReferenceError and friends) counts as not implemented. */
function classifyAccessError(error: unknown): 'denied' | 'unsupported' {
  if (error instanceof Error && error.name === 'SecurityError') return 'denied';
  return 'unsupported';
}

function isQuotaError(error: unknown): boolean {
  // Deliberately not `instanceof Error`: quota errors are DOMException, whose Error inheritance
  // only landed in WebIDL in 2021 and hosts such as jsdom do not honour it - going by instanceof
  // would misreport a real quota error as "storage unavailable".
  if (typeof error !== 'object' || error === null) return false;
  const { name, code } = error as { name?: unknown; code?: unknown };
  // Three vendor spellings across Chrome/Safari/Firefox, plus the numeric codes from old IE
  return (
    name === 'QuotaExceededError'
    || name === 'NS_ERROR_DOM_QUOTA_REACHED'
    || code === 22
    || code === 1014
  );
}

/**
 * Reads the underlying Storage object. **The getter itself can throw**, so this is the only place
 * allowed to touch `window.localStorage` directly; everything else must go through this module.
 */
function rawStorage(kind: 'local' | 'session'): Storage | null {
  if (typeof window === 'undefined') return null;
  try {
    return kind === 'local' ? window.localStorage : window.sessionStorage;
  } catch {
    return null;
  }
}

function probe(kind: 'local' | 'session'): StorageAvailability {
  if (typeof window === 'undefined') return 'unsupported';
  try {
    const store = kind === 'local' ? window.localStorage : window.sessionStorage;
    if (!store) return 'unsupported';
    // Only a real read/write proves availability: some engines pass the getter but throw on use
    const probeKey = '__oriveo_probe__';
    store.setItem(probeKey, '1');
    store.removeItem(probeKey);
    return 'available';
  } catch (error) {
    // A full quota does not mean unavailable - reads still work, and the fallback differs
    if (isQuotaError(error)) return 'available';
    return classifyAccessError(error);
  }
}

/** Report each key family once per session: callers usually retry the refused write verbatim, and Sentry should not see a storm. */
const reportedOversizeGroups = new Set<string>();

function reportOversizeWrite(kind: 'local' | 'session', key: string, valueChars: number): void {
  const group = `${kind}:${normalizeStorageKey(key)}`;
  // Normalize the key before reporting: raw keys can carry a uid, which must not reach monitoring.
  if (reportedOversizeGroups.has(group)) return;
  reportedOversizeGroups.add(group);
  if (process.env.NODE_ENV !== 'production') {
    console.error(
      `[oriveo/storage] refused to write ${kind}Storage key "${key}": ${valueChars} characters exceed the per-key limit of `
      + `${LOCAL_STORAGE_MAX_ITEM_CHARS}. Use lib/infra/storage/blob-cache.ts (IndexedDB) for large objects.`,
    );
  }
  try {
    Sentry.withScope((scope) => {
      scope.setLevel('warning');
      scope.setTag('storage.kind', kind);
      scope.setContext('storage_oversize_write', {
        keyGroup: normalizeStorageKey(key),
        valueChars,
        limitChars: LOCAL_STORAGE_MAX_ITEM_CHARS,
        hint: 'use lib/infra/storage/blob-cache.ts (IndexedDB) for large structured caches',
      });
      Sentry.captureMessage('storage.oversize_write_rejected');
    });
  } catch {
    /* A failed report must not change the refusal semantics */
  }
}

function createSafeStorage(kind: 'local' | 'session'): SafeStorage & {
  availability(): StorageAvailability;
  resetForTest(): void;
} {
  let availability: StorageAvailability | null = null;
  let lastWriteFailure: StorageWriteFailure | null = null;

  const resolveAvailability = (): StorageAvailability => {
    availability ??= probe(kind);
    return availability;
  };

  return {
    availability: resolveAvailability,

    getItem(key) {
      const store = rawStorage(kind);
      if (!store) return null;
      try {
        return store.getItem(key);
      } catch {
        return null;
      }
    },

    setItem(key, value) {
      if (key.length + value.length > LOCAL_STORAGE_MAX_ITEM_CHARS) {
        lastWriteFailure = 'oversize';
        reportOversizeWrite(kind, key, value.length);
        return false;
      }
      const store = rawStorage(kind);
      if (!store) {
        // A throwing getter and a missing implementation both make rawStorage return null,
        // but the reason differs: the first is a refusal the user can lift in settings, the
        // second has no fix. Use the probe result so denied is not reported as unsupported.
        const availability = resolveAvailability();
        lastWriteFailure = availability === 'denied' ? 'denied' : 'unsupported';
        return false;
      }
      try {
        store.setItem(key, value);
        lastWriteFailure = null;
        return true;
      } catch (error) {
        lastWriteFailure = isQuotaError(error) ? 'quota' : classifyAccessError(error);
        return false;
      }
    },

    removeItem(key) {
      const store = rawStorage(kind);
      if (!store) return false;
      try {
        store.removeItem(key);
        return true;
      } catch {
        return false;
      }
    },

    keys() {
      const store = rawStorage(kind);
      if (!store) return [];
      try {
        const out: string[] = [];
        for (let i = 0; i < store.length; i += 1) {
          const key = store.key(i);
          if (key !== null) out.push(key);
        }
        return out;
      } catch {
        return [];
      }
    },

    lastWriteFailure: () => lastWriteFailure,

    resetForTest() {
      availability = null;
      lastWriteFailure = null;
      reportedOversizeGroups.clear();
    },
  };
}

let quotaGuardInstalled = false;

/**
 * Installs a quota guard on the native `localStorage.setItem`: on overflow it calls `reclaim` to
 * free space, then retries once.
 *
 * The patch has to sit on the **native object**, because a third-party SDK that writes through
 * `window.localStorage` never reaches `safeLocalStorage`, and such a library typically handles
 * QuotaExceededError badly - letting it bubble into a fatal assertion, or blocking whatever it was
 * doing. This file is the only place allowed to touch `window.localStorage` directly, so the patch
 * belongs here.
 *
 * `reclaim` returns how many keys it freed; 0 means nothing was reclaimable, and the error is
 * rethrown as-is so a genuine write failure is never swallowed.
 */
export function installLocalStorageQuotaGuard(reclaim: () => number): boolean {
  if (quotaGuardInstalled) return true;
  const store = rawStorage('local');
  if (!store) return false;

  // Must be installed on `Storage.prototype`, never as `store.setItem = fn`: Storage is a legacy
  // platform object, so assigning to an instance goes through the named property setter and is
  // equivalent to `setItem('setItem', fn)` - the method is untouched and a junk key gets stored.
  // (quota-reclaim.test.ts covers this.)
  const proto = Object.getPrototypeOf(store) as Storage | null;
  if (!proto || typeof proto.setItem !== 'function') return false;
  const nativeSetItem = proto.setItem;
  try {
    Object.defineProperty(proto, 'setItem', {
      configurable: true,
      writable: true,
      value: function guardedSetItem(this: Storage, key: string, value: string): void {
        try {
          nativeSetItem.call(this, key, value);
        } catch (error) {
          // Self-heal only for localStorage: sessionStorage shares the prototype but holds no sync keys.
          if (this !== store || !isQuotaError(error) || reclaim() === 0) throw error;
          nativeSetItem.call(this, key, value);
        }
      },
    });
    quotaGuardInstalled = true;
    return true;
  } catch {
    // Some engines define Storage methods as non-writable; if the patch does not apply, run without it.
    return false;
  }
}

export const safeLocalStorage = createSafeStorage('local');
export const safeSessionStorage = createSafeStorage('session');

/** Whether the browser denies localStorage (the signal for site-wide persistence degradation). */
export function isLocalStorageDenied(): boolean {
  return safeLocalStorage.availability() === 'denied';
}

/**
 * Estimates the characters currently stored in localStorage (UTF-16 code units, the unit Chrome
 * counts its quota in). Diagnostics only, never part of control flow; returns null when unavailable.
 */
export function estimateLocalStorageUsage(): number | null {
  const store = rawStorage('local');
  if (!store) return null;
  try {
    let total = 0;
    for (const key of safeLocalStorage.keys()) {
      total += key.length + (store.getItem(key)?.length ?? 0);
    }
    return total;
  } catch {
    return null;
  }
}

export interface LocalStorageGroupUsage {
  /** Normalized key family (uid / batchId and other variable segments stripped) */
  group: string;
  /** Number of keys in this family */
  keys: number;
  /** Characters used by this family (key names + values) */
  chars: number;
}

/**
 * Strips the variable segments out of a key name, leaving only the key family.
 *
 * Required before reporting usage: raw key names carry a uid (`oriveo.<uid>.preferences`) and
 * a batchId plus a uid, so sending them to Sentry would leak user identifiers into monitoring.
 */
function normalizeStorageKey(key: string): string {
  // Strip e-mail addresses whole before the per-token pass. One real key is suffixed with an
  // address (`oriveo.providersUsageSummary.<email>`, see core/usage/account-usage-summary-cache.ts):
  // `@` and `.` are separators, so every token it splits into is short and purely lowercase and
  // sails through the "long, with mixed case and digits" test below - **the address would reach Sentry intact**.
  const withoutEmails = key.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '<email>');
  // Per token rather than one regex over the whole string: `firestore_mutations_firestore` is
  // 29 characters with its underscores, and a "20+ characters means id" rule would blank the
  // entire prefix to <id>, leaving a report nobody can identify.
  return withoutEmails.replace(/[A-Za-z0-9-]+/g, (token) => {
    if (/^\d{3,}$/.test(token)) return '<n>';
    // Shape of a uid / document ID: long, with mixed case and digits. Short lowercase dashed strings such as project IDs stay.
    const looksLikeIdentifier = token.length >= 20
      && /[a-z]/.test(token)
      && /[A-Z]/.test(token)
      && /\d/.test(token);
    return looksLikeIdentifier ? '<id>' : token;
  });
}

/**
 * Breaks localStorage usage down by key family, largest first, capped at `limit` families.
 *
 * Reporting only the total leaves "who filled the 5MB" to be inferred from SDK sources; with this,
 * the first alert of the next such incident names the culprit directly.
 */
export function summarizeLocalStorageUsage(limit = 5): LocalStorageGroupUsage[] {
  const store = rawStorage('local');
  if (!store) return [];
  try {
    const groups = new Map<string, LocalStorageGroupUsage>();
    for (const key of safeLocalStorage.keys()) {
      const chars = key.length + (store.getItem(key)?.length ?? 0);
      const group = normalizeStorageKey(key);
      const existing = groups.get(group);
      if (existing) {
        existing.keys += 1;
        existing.chars += chars;
      } else {
        groups.set(group, { group, keys: 1, chars });
      }
    }
    return [...groups.values()].sort((left, right) => right.chars - left.chars).slice(0, limit);
  } catch {
    return [];
  }
}

/** Hard localStorage quota in Chrome/Safari (UTF-16 code units). */
export const LOCAL_STORAGE_QUOTA_CHARS = 5 * 1024 * 1024;
