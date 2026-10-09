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
