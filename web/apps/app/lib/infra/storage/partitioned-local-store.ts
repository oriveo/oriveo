import { getActiveUIDSync } from './partition';
import { safeLocalStorage } from './web-storage';

const PREFIX = 'oriveo.';

/**
 * Whole-table per-UID localStorage (`oriveo.{uid}.{bareKey}`), same semantics as `preferences.ts`.
 *
 * The model control tables have to be partitioned because they store user intent along a
 * connection x model x transport axis, and a connection belongs to an account. Left unpartitioned
 * under one origin, A's preferences would still be there after A logs out and B logs in, and B's
 * sync export would push them to the cloud (`exportCapabilityPreferenceSyncPayload` reads exactly
 * this table). That is a cross-account data leak, not a display glitch.
 *
 * Only the local key prefix changes here; the sync envelope is untouched. `schemaVersion`, the
 * record shape and the recordId composition stay byte-identical, because the envelope is a frozen
 * cross-client contract.
 */
function prefixed(bareKey: string, uid?: string): string {
  return `${PREFIX}${uid ?? getActiveUIDSync()}.${bareKey}`;
}

/** The old bare key with no UID dimension, used only for the one-time migration of existing installs. */
function legacyPrefixed(bareKey: string): string {
  return `${PREFIX}${bareKey}`;
}

/**
 * Local account watermark: the uid of the first real account that ever signed in on this machine.
 * One per machine, and not itself a partition key.
 *
 * It exists because the only sound criterion for inheriting a bare key is 'this machine has never
 * had a real account' (contract
 * `capability_preference_sync.v1#accountScopeInvariants.legacyBareKeyClaim`). Data written before
 * partitioning existed still has a clear owner: it belonged to whoever was signed in at the time,
 * so 'unowned' was never true. Handing the bare key to the account signed in now, after another
 * real account has already appeared on this machine, is a cross-account inheritance: A's records
 * would ride into B's cloud document on B's next full-table sync.
 */
const REAL_ACCOUNT_WATERMARK_KEY = `${PREFIX}firstRealAccountClaim.v1`;

/**
 * How a bare key is claimed:
 *   - `inherit`: inherit it and consume it (a real account that owns the machine watermark).
 *   - `copy`: copy without deleting (guest, and no real account has ever used this machine).
 *     Auth boot briefly hydrates the guest partition, and deleting the bare key at that moment
 *     would let guest take it before the real account arrives.
 *   - `discard`: delete the bare key without inheriting it -- the local data belongs to a
 *     different real account.
 */
export type LegacyBareKeyClaim = 'inherit' | 'copy' | 'discard';

/**
 * Decide who owns the bare key, and stamp the watermark the first time a real uid lands on this
 * machine (guest never stamps).
 *
 * Stamping is independent of whether a given table holds any data: the stamp records that a real
 * account has appeared at all, so every partitioned read and write runs it instead of only the
 * migrations. Otherwise a machine with no bare keys would never carry a stamp, and a bare key
 * that shows up later (a one-time rewrite of existing data writes back to the bare key) would be
 * judged unowned.
 *
 * Shares the criterion with `preferences.ts`, which inherits memoryText/pinned and is even more
 * sensitive.
 */
export function resolveLegacyBareKeyClaim(uid: string): LegacyBareKeyClaim {
  // The watermark stamp goes through safeLocalStorage: it is the only new write point in this
  // module, no bare call is added (`local-storage-call-sites.test.ts`), and it brings the 'does
  // not throw when the browser blocks site data' semantics along with it.
  const watermark = safeLocalStorage.getItem(REAL_ACCOUNT_WATERMARK_KEY);
  if (uid === 'guest') return watermark === null ? 'copy' : 'discard';
  if (watermark === null) {
    safeLocalStorage.setItem(REAL_ACCOUNT_WATERMARK_KEY, uid);
    return 'inherit';
  }
  return watermark === uid ? 'inherit' : 'discard';
}

/**
 * One-time migration of existing data, semantically identical to `migrateLegacyPreference` in
 * `preferences.ts`, with the decision delegated to `resolveLegacyBareKeyClaim`.
 * Called inline on every read and write so it always sees the activeUID at call time.
 */
function migrateLegacy(bareKey: string, uid: string): void {
  const claim = resolveLegacyBareKeyClaim(uid);
  const partitionedKey = prefixed(bareKey, uid);
  if (localStorage.getItem(partitionedKey) !== null) return;
  const legacyKey = legacyPrefixed(bareKey);
  const legacyRaw = localStorage.getItem(legacyKey);
  if (legacyRaw === null) return;
  if (claim === 'discard') {
    localStorage.removeItem(legacyKey);
    return;
  }
  localStorage.setItem(partitionedKey, legacyRaw);
  if (claim === 'inherit') localStorage.removeItem(legacyKey);
}

export function readPartitionedStore(bareKey: string): string | null {
  if (typeof window === 'undefined') return null;
  try {
    const uid = getActiveUIDSync();
    migrateLegacy(bareKey, uid);
    return localStorage.getItem(prefixed(bareKey, uid));
  } catch {
    return null;
  }
}

export function writePartitionedStore(bareKey: string, raw: string): void {
  if (typeof window === 'undefined') return;
  try {
    const uid = getActiveUIDSync();
    // Consume the bare key before writing, so it cannot be misread later or migrate overwritten
    // data back in.
    migrateLegacy(bareKey, uid);
    localStorage.setItem(prefixed(bareKey, uid), raw);
  } catch {
    /* Quota exhausted or privacy mode: an optional local setting, so give up silently. */
  }
}

/**
 * Raw read/write of the legacy bare key. Only for the one-time migration; normal access must go
 * through the two partitioned functions above.
 *
 * The hatch is needed because a bare key under the guest partition is not deleted while no real
 * account has used the machine (`claim === 'copy'`, see `resolveLegacyBareKeyClaim`); it waits
 * for the first real sign-in to inherit it. So any migration that rewrites existing data must
 * rewrite the bare-key copy as well, or the user inherits pre-migration data after signing in
 * while that migration's trigger (a key that has already been deleted) can never fire again.
 */
export function readLegacyBareStore(bareKey: string): string | null {
  if (typeof window === 'undefined') return null;
  try { return localStorage.getItem(legacyPrefixed(bareKey)); } catch { return null; }
}

export function writeLegacyBareStore(bareKey: string, raw: string): void {
  if (typeof window === 'undefined') return;
  try { localStorage.setItem(legacyPrefixed(bareKey), raw); } catch { /* optional local setting */ }
}

/**
 * Clear every partitioned key for a UID (`oriveo.<uid>.*`, including the matching keys owned by
 * `preferences.ts` -- both modules share the same `oriveo.{uid}.{bareKey}` scheme).
 *
 * Used by sign-out: per-UID keys have no other cleanup path and pile up as accounts rotate, and
 * leaving them under the origin exposes the previous account's preferences to the next user of
 * the machine. Deleting is safe because the preferences and capability tables sync to the cloud
 * and come back on the next sign-in.
 *
 * Matching is an exact prefix on the real uid handed in by the caller, never a guess at which
 * segment looks like a uid: the `oriveo.` key space also holds non-partitioned keys such as
 * `oriveo.sync.deviceId` and `oriveo.providersUsageSummary.<key>`, and guessing by shape will
 * eventually delete the wrong one. The guest partition and the legacy bare keys (still waiting
 * for the first real account) are never touched.
 */
export function clearPartitionedStoreForUID(uid: string): number {
  if (typeof window === 'undefined' || !uid || uid === 'guest') return 0;
  return removePartitionKeys(uid);
}

/**
 * Explicitly clear the guest partition keys. The default entry point always refuses guest, since
 * clearing it wipes everything a signed-out user has; only a switch between two real accounts
 * should call this.
 *
 * Guest has to be cleared on an account switch because the contract's `guestPromotion` is
 * `not_migrated`: sync-visible state produced while in guest must not be inherited by any real
 * account. Auth boot and the sign-out fallback both park activeUID on guest briefly during the
 * previous account's session, leaving unowned residue, and the account-switch boundary is the
 * only moment it can be cleared safely, because no guest session is using it then.
 */
export function clearGuestPartitionedStore(): number {
  if (typeof window === 'undefined') return 0;
  return removePartitionKeys('guest');
}

function removePartitionKeys(uid: string): number {
  const doomedPrefix = `${PREFIX}${uid}.`;
  let removed = 0;
  for (const key of safeLocalStorage.keys()) {
    if (!key.startsWith(doomedPrefix)) continue;
    if (safeLocalStorage.removeItem(key)) removed += 1;
  }
  return removed;
}

/** Whether the legacy bare key still exists (probed before migration, and by read-only checks such as `hasDormant*`). */
export function hasLegacyBareStore(bareKey: string): boolean {
  if (typeof window === 'undefined') return false;
  try {
    return localStorage.getItem(legacyPrefixed(bareKey)) !== null
      || localStorage.getItem(prefixed(bareKey)) !== null;
  } catch {
    return false;
  }
}
