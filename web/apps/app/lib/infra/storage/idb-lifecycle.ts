/**
 * Shared implementation of the IndexedDB connection lifecycle callbacks (`blocked` / `blocking`).
 *
 * The deadlock this closes: an IDB version upgrade requires that no other connection is open when
 * the upgrade starts. A long-lived older connection (another tab, or a cached connection in this
 * tab that was never closed) leaves the new version's `open()` stuck on `blocked`, where it never
 * settles: it neither resolves nor rejects. Without a `blocking` callback on any `openDB` call,
 * the next `DB_VERSION` bump would leave anyone with an old tab still open looking at a new tab
 * stuck forever on the hydration step of startup.
 *
 * Division of labour:
 *   - `blocking`: this connection is in the way of someone else's upgrade, so close it and let
 *     the other side proceed. Only connections whose lifetime is managed by a module-level cache,
 *     and can therefore be reopened at any time, should do this.
 *   - `blocked`: this open is being held up by someone else. The other connection cannot be
 *     closed from here, so the only option is to report it; otherwise this kind of hang is
 *     completely silent and the user just sees a skeleton screen that never finishes.
 */

import * as Sentry from '@sentry/nextjs';
import { safeSessionStorage } from './web-storage';

/**
 * Report that this open() is blocked by another connection.
 *
 * A warning rather than an error: with several tabs this usually heals within seconds (the other
 * side's `blocking` closes its connection) and is only worth chasing at unusual volume. A failed
 * report does not change what open() does.
 */
export function reportIDBUpgradeBlocked(
  dbName: string,
  currentVersion: number | null,
  blockedVersion: number | null,
): void {
  try {
    Sentry.withScope((scope) => {
      scope.setLevel('warning');
      scope.setTag('storage.idb_database', dbName);
      scope.setContext('idb_upgrade_blocked', {
        dbName,
        currentVersion,
        blockedVersion,
      });
      Sentry.captureMessage('storage.idb_upgrade_blocked');
    });
  } catch {
    /* A failed report does not change what open() does. */
  }
}

/**
 * A stale bundle opening a database that a newer bundle has already upgraded: the requested version
 * is lower than the one on disk, and the browser throws `VersionError`.
 *
 * Typical case: a tab opened before a release runs the old bundle (`DB_VERSION = 10`), then the user
 * opens a new tab whose bundle upgrades the database to 15. The old tab's `blocking` callback closes
 * its connection to make way, but its version number is a hard-coded constant, so the next open can
 * only ask for 10 again. From then on local storage is unusable in that tab; only a reload onto the
 * new bundle recovers it. Same kind of problem as a stale chunk, same way out: reload automatically
 * once per tab session. If it is still a `VersionError` after the reload (the CDN still serving the
 * old bundle, or a lower version hard-coded somewhere), throw as usual so it gets reported.
 */
export function isIDBVersionError(error: unknown): boolean {
  return typeof error === 'object' && error !== null && (error as { name?: unknown }).name === 'VersionError';
}

/** sessionStorage gate key: a stale schema reloads at most once per tab session, so it cannot loop. */
export const IDB_STALE_SCHEMA_RELOAD_KEY = 'oriveo:idb-stale-schema-reload';

interface StaleSchemaHost {
  storage: { getItem(key: string): string | null; setItem(key: string, value: string): boolean };
  reload: () => void;
}

function browserStaleSchemaHost(): StaleSchemaHost | null {
  if (typeof window === 'undefined') return null;
  return { storage: safeSessionStorage, reload: () => window.location.reload() };
}

let staleSchemaHost: () => StaleSchemaHost | null = browserStaleSchemaHost;

/** Tests only: jsdom's `window.location.reload` cannot be replaced. Pass null to restore the default. */
export function setStaleSchemaHostForTests(host: (() => StaleSchemaHost | null) | null): void {
  staleSchemaHost = host ?? browserStaleSchemaHost;
}

function reloadOnceForStaleSchema(): boolean {
  const host = staleSchemaHost();
  if (!host) return false;
  if (host.storage.getItem(IDB_STALE_SCHEMA_RELOAD_KEY) === '1') return false;
  // If the gate cannot be written (site data disabled, quota full), do not reload: a reload without a gate could loop forever.
  if (!host.storage.setItem(IDB_STALE_SCHEMA_RELOAD_KEY, '1')) return false;
  host.reload();
  return true;
}

/**
 * Wraps one `openDB` call: on a stale schema, if this session has not reloaded yet, reload the page
 * and return a promise that never settles. The page is about to unload, so callers should not get a
 * result that is bound to fail and then report it or write broken state.
 *
 * The gate is only ever set, never cleared: several databases share it, and clearing it whenever any
 * of them opens successfully would turn "another database still throws VersionError after the reload"
 * into an endless reload loop. The cost is that a second new version within the same tab session is
 * no longer reloaded automatically and is thrown as usual.
 */
export async function openWithStaleSchemaRecovery<T>(open: () => Promise<T>): Promise<T> {
  try {
    return await open();
  } catch (error) {
    if (isIDBVersionError(error) && reloadOnceForStaleSchema()) {
      return new Promise<T>(() => {});
    }
    throw error;
  }
}
