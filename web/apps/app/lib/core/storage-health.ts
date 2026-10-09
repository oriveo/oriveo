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
 *
 * `unknown` is weaker than `timeout`: the timeout criterion itself does not hold. The deadline is
 * measured with the host's timer queue, and when that queue is starved (the page is suspended, the
 * main thread is stalled, or the tab is throttled in the background) the 3s callback may run many
 * seconds late. What it proves then is that the host stalled, not that IDB has a problem. Without
 * this state, a page load whose timers ran several times late was judged `timeout` and showed a
 * "browser storage is blocked" banner to someone whose localStorage was working fine.
 *
 * `slow` is the one state that is not a verdict yet: the deadline passed on a healthy host and
 * `open()` has not called back. A low-end device creating a database for this site for the first time, while the
 * page is still hydrating, can legitimately take longer than the deadline. The probe does not give
 * up on that `open()`: a callback that arrives later revises the result to `available` or
 * `denied`, and only when the confirmation deadline also passes without one does it become
 * `timeout`. Treating the first deadline as final would cache "broken" for the whole session and
 * show a "browser storage is disabled" banner while reads and writes carry on normally.
 */
export type IndexedDBAvailability = 'available' | 'denied' | 'unsupported' | 'slow' | 'timeout' | 'unknown';

export interface StorageHealth {
  local: StorageAvailability;
  indexedDB: IndexedDBAvailability;
  /** Characters used in localStorage (UTF-16 code units); null when unmeasurable. */
  localUsage: number | null;
  /**
   * Whether persistence is confirmed working. IndexedDB is the only medium that actually holds
   * user data (conversations, providers, notes, images), so losing it means nothing can be stored
   * locally.
   *
   * `false` only means "not confirmed working", not "confirmed broken": `unknown` lands on this
   * side too. Use {@link isPersistenceBroken} to decide whether it is really broken, and do not
   * drive user-visible warnings from this field.
   */
  persistent: boolean;
  /** Wall-clock time from starting the probe to its verdict, in ms. Tells a slow IDB from a stalled host. */
  probeElapsedMs: number;
  /**
   * Whether the host's timer queue was starved during the probe (it took far longer than the
   * deadline, or the page went hidden). When true the verdict cannot be trusted: the probe
   * measured the host, not storage.
   */
  probeStarved: boolean;
}

/**
 * IDB states that are confirmed broken and therefore worth interrupting the user for. `unknown`
 * and the not-yet-settled `slow` are not among them.
 */
const BROKEN_IDB_STATES: readonly IndexedDBAvailability[] = ['denied', 'unsupported', 'timeout'];

/**
 * Whether persistence is confirmed broken, as opposed to `!persistent`, which is merely "not
 * confirmed working". User-visible degradation notices use only this, so a stalled host is never
 * rendered as "the browser blocked site data".
 */
export function isPersistenceBroken(health: StorageHealth): boolean {
  return BROKEN_IDB_STATES.includes(health.indexedDB);
}

/** localStorage usage above this fraction of the quota counts as pressure worth reporting. */
const LOCAL_PRESSURE_RATIO = 0.6;

/** Probe deadline: without a callback by then, hand back `slow` so startup stops waiting. */
const PROBE_TIMEOUT_MS = 3000;
/**
 * Confirmation deadline, measured from the start of the probe: only when there is still no
 * callback at this point does the result become `timeout`. Five times the probe deadline is a
 * judgement call rather than a measurement. It only has to be clearly longer than a cold database
 * creation on a slow device without making a user whose storage really is blocked wait too long
 * for the notice. An engine that does call back on denial goes through onerror and is `denied`
 * immediately, unaffected by this.
 */
const PROBE_CONFIRM_TIMEOUT_MS = PROBE_TIMEOUT_MS * 5;
/**
 * Settling later than this multiple of a deadline means the ruler the deadline is measured with
 * (the host's timer queue) is itself broken. Two is conservative: a busy IDB only delays its own
 * callbacks and cannot push a 3s setTimeout past 6s. Only a stalled main thread or a suspended
 * page can.
 */
const PROBE_STARVATION_FACTOR = 2;

interface ProbeOutcome {
  availability: IndexedDBAvailability;
  elapsedMs: number;
  starved: boolean;
  /** Present only for `slow`: the final verdict of the same `open()` call. */
  revision?: Promise<ProbeOutcome>;
}

/**
 * Probes whether IndexedDB can actually be used, not merely whether the API is exposed.
 *
 * `'indexedDB' in window` is true in private windows and with site data blocked, where `open()`
 * then fails or hangs on `blocked`. Opening a dedicated probe database is the only answer that
 * distinguishes "present" from "usable", and it never touches the version of a real database.
 *
 * Starvation-proofing: the verdict carries the actual elapsed time and whether the host stalled.
 * A timeout only counts while the host's timer queue is still accurate; otherwise the result is
 * downgraded to `unknown` (see {@link IndexedDBAvailability}).
 */
async function probeIndexedDB(): Promise<ProbeOutcome> {
  const startedAt = Date.now();
  if (typeof indexedDB === 'undefined') {
    return { availability: 'unsupported', elapsedMs: 0, starved: false };
  }
  const PROBE_DB = '__oriveo_probe__';

  // A page that went to the background during the probe can have its timers throttled to the
  // minute range, at which point no deadline-based criterion means anything.
  const hasDocument = typeof document !== 'undefined';
  let sawHidden = hasDocument && document.visibilityState === 'hidden';
  const onVisibilityChange = () => {
    if (document.visibilityState === 'hidden') sawHidden = true;
  };
  if (hasDocument) document.addEventListener('visibilitychange', onVisibilityChange);
  const stopWatchingVisibility = () => {
    if (hasDocument) document.removeEventListener('visibilitychange', onVisibilityChange);
  };

  const isStarved = (limitMs: number) =>
    sawHidden || Date.now() - startedAt > limitMs * PROBE_STARVATION_FACTOR;
  const outcome = (availability: IndexedDBAvailability, limitMs: number): ProbeOutcome => ({
    availability,
    elapsedMs: Date.now() - startedAt,
    starved: isStarved(limitMs),
  });

  return new Promise<ProbeOutcome>((resolve) => {
    // The first settlement goes to startup. If it was `slow`, the later verdict of the same
    // open() call is delivered through `revise`.
    let settled = false;
    let revise: ((result: ProbeOutcome) => void) | null = null;
    const finish = (availability: IndexedDBAvailability) => {
      if (!settled) {
        settled = true;
        stopWatchingVisibility();
        resolve(outcome(availability, PROBE_TIMEOUT_MS));
        return;
      }
      if (!revise) return;
      const deliver = revise;
      revise = null;
      stopWatchingVisibility();
      deliver(outcome(availability, PROBE_CONFIRM_TIMEOUT_MS));
    };

    let request: IDBOpenDBRequest;
    try {
      request = indexedDB.open(PROBE_DB, 1);
    } catch {
      finish('denied');
      return;
    }
    request.onsuccess = () => {
      // The probe database is kept and reused. Opening and deleting it on every load costs an
      // extra create/delete each time, and the delete has to wait for every connection to close,
      // which can hang with several tabs open. Keeping it costs a few KB.
      request.result.close();
      finish('available');
    };
    request.onerror = () => finish('denied');
    request.onblocked = () => finish('available'); // Blocked by another tab is not the same as unavailable.
    // Some engines neither resolve nor error when storage is denied, so a timeout is the only
    // fallback. A timeout is not a denial: when a desktop Chrome was saturated by a 1.84M-entry
    // mutation queue, probe timeouts were previously misrecorded as denial errors. And when this
    // callback itself runs late, not even "timeout" holds: what it proves is that the host stalled.
    setTimeout(() => {
      if (settled) return;
      if (isStarved(PROBE_TIMEOUT_MS)) {
        finish('unknown');
        return;
      }
      // The deadline passed on a healthy host: hand back `slow` now and keep waiting for this
      // open() to call back; the verdict is only drawn at the confirmation deadline.
      settled = true;
      const revision = new Promise<ProbeOutcome>((resolveRevision) => { revise = resolveRevision; });
      setTimeout(
        () => finish(isStarved(PROBE_CONFIRM_TIMEOUT_MS) ? 'unknown' : 'timeout'),
        PROBE_CONFIRM_TIMEOUT_MS - PROBE_TIMEOUT_MS,
      );
      resolve({ ...outcome('slow', PROBE_TIMEOUT_MS), revision });
    }, PROBE_TIMEOUT_MS);
  });
}

let cachedHealth: StorageHealth | null = null;
let cachedTopGroups: string[] = [];
let reported = false;
/** A report was requested while the result was still `slow`; it is sent once the revision lands. */
let reportAwaitingRevision = false;

/**
 * Probe once and cache the result; storage permissions do not change within a session.
 *
 * The key-group breakdown is collected at the same moment: the probe runs as step 0 of bootstrap
 * (before any persistence, and before `reclaimLocalStorageQuota()` inside `getDB()`), while
 * reporting has to wait for auth to settle. Sampling separately would put a pre-reclaim
 * `localUsageChars` next to a post-reclaim `topGroups` in one event, where they contradict each
 * other. One sample at one instant is one scene.
 */
export async function detectStorageHealth(
  options: { onRevised?: (health: StorageHealth) => void } = {},
): Promise<StorageHealth> {
  if (cachedHealth) return cachedHealth;
  const local = safeLocalStorage.availability();
  const probe = await probeIndexedDB();
  const initial: StorageHealth = {
    local,
    indexedDB: probe.availability,
    localUsage: estimateLocalStorageUsage(),
    persistent: probe.availability === 'available',
    probeElapsedMs: probe.elapsedMs,
    probeStarved: probe.starved,
  };
  cachedHealth = initial;
  // `slow` is not a verdict: once the same open() settles the result is revised, and both the UI
  // and reporting follow the final answer.
  void probe.revision?.then((revised) => {
    // The cache was reset or another probe replaced it in the meantime: a late revision is void.
    if (cachedHealth !== initial) return;
    const next: StorageHealth = {
      ...initial,
      indexedDB: revised.availability,
      persistent: revised.availability === 'available',
      probeElapsedMs: revised.elapsedMs,
      probeStarved: revised.starved,
    };
    cachedHealth = next;
    if (revised.availability === 'available') {
      // Merely slow is not a fault. Leave a breadcrumb other events can be read against rather
      // than raising an issue of its own.
      Sentry.addBreadcrumb({
        category: 'storage',
        level: 'info',
        message: 'storage.persistence_probe_slow',
        data: { probeElapsedMs: revised.elapsedMs },
      });
    }
    options.onRevised?.(next);
    if (reportAwaitingRevision) reportStorageHealth(next);
  });
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
 *     without a callback cannot be told apart from an unresponsive IDB, so it never claims denied.
 *     Sent only when the confirmation deadline (15s) passes without any callback; `slow` at 3s is
 *     not reported, and a callback that then succeeds leaves only the breadcrumb
 *     `storage.persistence_probe_slow`
 *   - probe starved by the host -> a separate `info` signal, `storage.persistence_probe_starved`
 *   - localStorage gone while IDB still works -> `warning`; the app is broadly usable
 *   - localStorage above 60% of quota -> `warning`; this precedes the sync queue being squeezed out
 *     (the quota has been filled by a 3.3MB metadata snapshot before)
 *
 * "Worth reporting" and "worth interrupting the user" are two separate criteria, and `persistent`
 * must not serve as both: `unknown` should not raise the banner (no storage fault was measured),
 * but it must be reported, because it is exactly the kind of main-thread stall worth observing
 * and `probeElapsedMs` is what tells how long the stall lasted.
 *
 * On the Sentry side, `persistence_unavailable` from private mode or engines that refuse site
 * data is an environment signal that cannot be acted on, so it is archived until escalating: an
 * unusual volume revives it automatically without occupying an issue slot day to day.
 */
export function reportStorageHealth(health: StorageHealth): void {
  if (reported) return;
  // The caller may still hold the snapshot from before the revision; the latest verdict wins.
  if (health.indexedDB === 'slow' && cachedHealth && cachedHealth.indexedDB !== 'slow') {
    health = cachedHealth;
  }
  // Nothing is reported before the result settles: `slow` either turns back into available
  // (nothing happened) or into denied / timeout (each with its own signal). Sent now it would be a
  // warning nobody could interpret. It is sent once the revision lands instead.
  if (health.indexedDB === 'slow') {
    reportAwaitingRevision = true;
    return;
  }
  reported = true;

  const usageRatio =
    health.localUsage === null ? null : health.localUsage / LOCAL_STORAGE_QUOTA_CHARS;
  const underPressure = usageRatio !== null && usageRatio > LOCAL_PRESSURE_RATIO;

  // Worth reporting = either medium is not confirmed available, or localStorage is under pressure.
  // This deliberately tests `indexedDB !== 'available'` rather than `!persistent`. The two are
  // equivalent today, but the former says "this probe has something to say" and the latter "can
  // persistence be used"; keeping them apart means a later change to what `persistent` means
  // cannot silently change what gets reported.
  const worthReporting =
    health.indexedDB !== 'available' || health.local !== 'available' || underPressure;
  if (!worthReporting) return;

  Sentry.withScope((scope) => {
    scope.setTag('storage.local', health.local);
    scope.setTag('storage.indexeddb', health.indexedDB);
    scope.setTag('storage.probe_starved', health.probeStarved);
    scope.setContext('storage', {
      local: health.local,
      indexedDB: health.indexedDB,
      localUsageChars: health.localUsage,
      localUsageRatio: usageRatio === null ? null : Number(usageRatio.toFixed(3)),
      quotaChars: LOCAL_STORAGE_QUOTA_CHARS,
      // The probe's own wall clock: how many milliseconds later the 3s fallback timer actually
      // ran. Far beyond the deadline means the ruler the deadline is measured with is broken.
      probeElapsedMs: health.probeElapsedMs,
      probeStarved: health.probeStarved,
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

    if (health.indexedDB === 'unknown') {
      // Deliberately info rather than warning: this event does not claim anything is wrong with
      // storage, it only keeps the sample of how long the host stalled. A warning would put a
      // non-storage condition back among the alerts as noise nobody can act on.
      scope.setLevel('info');
      Sentry.captureMessage('storage.persistence_probe_starved');
      return;
    }
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
  reportAwaitingRevision = false;
}
