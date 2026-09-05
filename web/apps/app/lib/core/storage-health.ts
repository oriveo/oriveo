/**
 * Browser persistence health probe and reporting.
 *
 * The visibility gap this closes: when a user blocks site data in the browser, every form of
 * persistence fails - conversations and BYOK keys cannot be stored. In production that outage
 * was invisible: `bootstrapApp` only wrote one `console.error` and nothing reached Sentry.
 *
 * The probe therefore runs at startup, and the result goes both into the store (driving the
 * degraded-mode UI) and into Sentry (once per session, with enough context to diagnose).
 */

import * as Sentry from '@sentry/nextjs';
import {
  LOCAL_STORAGE_QUOTA_CHARS,
  estimateLocalStorageUsage,
  safeLocalStorage,
  summarizeLocalStorageUsage,
  type StorageAvailability,
} from '../infra/storage/web-storage';
import { localStorageQuotaRecoveries } from '../infra/storage/quota-reclaim';

/**
 * IndexedDB availability. Same criteria as localStorage, but IDB can only be probed
 * asynchronously. `timeout` is its own state: the probe received no callback within the deadline,
 * which can mean storage was denied without a callback, or that IDB is simply unresponsive (a
 * side effect of a poisoned mutation queue saturating the main thread). An unmeasurable result is
 * reported as unmeasurable rather than as `denied`.
 */
export type IndexedDBAvailability = 'available' | 'denied' | 'unsupported' | 'timeout';

export interface StorageHealth {
  local: StorageAvailability;
  indexedDB: IndexedDBAvailability;
  /** Characters used in localStorage (UTF-16 code units); null when unmeasurable. */
  localUsage: number | null;
  /**
   * Whether persistence works at all. IndexedDB is the only medium that actually holds user data
   * (conversations, providers, notes, images), so losing it means nothing can be stored locally.
   */
  persistent: boolean;
}

/** localStorage usage above this fraction of the quota counts as pressure worth reporting. */
const LOCAL_PRESSURE_RATIO = 0.6;

/**
 *   IndexedDB  
 *
 *   `'indexedDB' in window`—— `open()`  
 *   error/blocked  
 */
async function probeIndexedDB(): Promise<IndexedDBAvailability> {
  if (typeof indexedDB === 'undefined') return 'unsupported';
  const PROBE_DB = '__oriveo_probe__';
  try {
    return await new Promise<IndexedDBAvailability>((resolve) => {
      let settled = false;
      const settle = (result: IndexedDBAvailability) => {
        if (settled) return;
        settled = true;
        resolve(result);
      };
      let request: IDBOpenDBRequest;
      try {
        request = indexedDB.open(PROBE_DB, 1);
      } catch {
        settle('denied');
        return;
      }
      request.onsuccess = () => {
        request.result.close();
        try {
          indexedDB.deleteDatabase(PROBE_DB);
        } catch {
          /* Deleting the probe database is best effort. */
        }
        settle('available');
      };
      request.onerror = () => settle('denied');
      request.onblocked = () => settle('available'); // Blocked by another tab is not the same as unavailable.
      // Some engines neither resolve nor error when storage is denied, so a timeout is the only
      // fallback. A timeout is not a denial: when a desktop Chrome was saturated by a 1.84M-entry
      // mutation queue, probe timeouts were previously misrecorded as denial errors.
      setTimeout(() => settle('timeout'), 3000);
    });
  } catch {
    return 'denied';
  }
}

let cachedHealth: StorageHealth | null = null;
let cachedTopGroups: string[] = [];
let reported = false;

/**
 * Probe once and cache the result; storage permissions do not change within a session.
 *
 * The key-group breakdown is collected at the same moment: the probe runs as step 0 of bootstrap
 * (before any persistence, and before `reclaimLocalStorageQuota()` inside `getDB()`), while
 * reporting has to wait for auth to settle. Sampling separately would put a pre-reclaim
 * `localUsageChars` next to a post-reclaim `topGroups` in one event, where they contradict each
 * other. One sample at one instant is one scene.
 */
export async function detectStorageHealth(): Promise<StorageHealth> {
  if (cachedHealth) return cachedHealth;
  const local = safeLocalStorage.availability();
  const idb = await probeIndexedDB();
  cachedHealth = {
    local,
    indexedDB: idb,
    localUsage: estimateLocalStorageUsage(),
    persistent: idb === 'available',
  };
  cachedTopGroups = summarizeLocalStorageUsage().map(
    (group) => `${group.group} - ${group.chars} chars - ${group.keys} keys`,
  );
  return cachedHealth;
}

/**
 * Send the probe result to Sentry, at most once per session.
 *
 * The grading is deliberately conservative:
 *   - IDB explicitly denied or unsupported -> `error`; nothing can be stored at all
 *   - probe timeout -> a separate `warning` signal, `storage.persistence_probe_timeout`: denial
 *     without a callback cannot be told apart from an unresponsive IDB, so it never claims denied
 *   - localStorage gone while IDB still works -> `warning`; the app is broadly usable
 *   - localStorage above 60% of quota -> `warning`; this precedes the sync queue being squeezed out
 *     (the quota has been filled by a 3.3MB metadata snapshot before)
 *
 * On the Sentry side, `persistence_unavailable` from private mode or engines that refuse site
 * data is an environment signal that cannot be acted on, so it is archived until escalating: an
 * unusual volume revives it automatically without occupying an issue slot day to day.
 */
export function reportStorageHealth(health: StorageHealth): void {
  if (reported) return;
  reported = true;

  const usageRatio =
    health.localUsage === null ? null : health.localUsage / LOCAL_STORAGE_QUOTA_CHARS;
  const underPressure = usageRatio !== null && usageRatio > LOCAL_PRESSURE_RATIO;

  if (health.persistent && health.local === 'available' && !underPressure) return;

  Sentry.withScope((scope) => {
    scope.setTag('storage.local', health.local);
    scope.setTag('storage.indexeddb', health.indexedDB);
    scope.setContext('storage', {
      local: health.local,
      indexedDB: health.indexedDB,
      localUsageChars: health.localUsage,
      localUsageRatio: usageRatio === null ? null : Number(usageRatio.toFixed(3)),
      quotaChars: LOCAL_STORAGE_QUOTA_CHARS,
      // Reporting only the total leaves "who filled the quota" to be inferred from SDK sources.
      // Key groups are normalized (uid / batchId replaced with placeholders) so no user identifier
      // reaches monitoring.
      //
      // Must be an array of strings: Sentry's `normalizeDepth` defaults to 3 and
      // `contexts.storage.topGroups[i]` already sits at depth 4, so objects are replaced wholesale
      // by the literal `"[Object]"` and the field becomes useless. Strings are primitives and
      // survive at any depth. Sampled at probe time (see detectStorageHealth), the same scene as
      // localUsageChars.
      topGroups: cachedTopGroups,
      quotaGuardRecoveries: localStorageQuotaRecoveries(),
    });

    if (!health.persistent) {
      if (health.indexedDB === 'timeout') {
        scope.setLevel('warning');
        Sentry.captureMessage('storage.persistence_probe_timeout');
        return;
      }
      scope.setLevel('error');
      Sentry.captureMessage('storage.persistence_unavailable');
      return;
    }
    scope.setLevel('warning');
    Sentry.captureMessage(
      health.local === 'available'
        ? 'storage.local_pressure'
        : 'storage.local_unavailable',
    );
  });
}

/** Test-only: clears the probe cache and the reporting gate. */
export function __resetStorageHealthForTest(): void {
  cachedHealth = null;
  cachedTopGroups = [];
  reported = false;
}
