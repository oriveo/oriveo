import { getActiveUIDSync } from './partition';
import { resolveLegacyBareKeyClaim } from './partitioned-local-store';

const PREFIX = 'oriveo.';

/**
 * Per-UID preference keys: `oriveo.{uid}.{key}` (guests use uid='guest').
 *
 * Preferences used to live under a global `oriveo.{key}` with no UID dimension, so when sign-out
 * did not clear them the next account would hydrate the previous account's memoryText, pinned
 * items and so on, leaking across accounts. They are now isolated by activeUID;
 * getActiveUIDSync reads a synchronous module-level mirror (see partition.ts).
 */
function prefixed(key: string, expectedUID?: string): string {
  return `${PREFIX}${expectedUID ?? getActiveUIDSync()}.${key}`;
}

/** Old global key with no UID dimension, used only for the one-time migration of existing data */
function legacyPrefixed(key: string): string {
  return `${PREFIX}${key}`;
}

/**
 * One-time migration of existing preferences: when the per-UID key is missing but the old global
 * key exists, the claim rules decide whether to move it or drop it.
 *
 * The rules are shared with `partitioned-local-store` (`resolveLegacyBareKeyClaim`, contract
 * `accountScopeInvariants.legacyBareKeyClaim`): existing data goes to the first real sign-in only
 * when this machine has never had a real account.
 *   - `inherit`: copy, then delete the old global key, so no later account inherits it and the
 *     migration is naturally idempotent (once the old key is gone it cannot trigger again).
 *   - `copy` (guest, and no account watermark on this machine): copy without deleting. Auth boot
 *     briefly hydrates the guest partition to take a snapshot, and activeUID is 'guest' at that
 *     moment; deleting the old global key there would leave the real account unable to read the
 *     existing preferences once it hydrates, with memory and pinned items claimed by the guest.
 *   - `discard`: delete the old global key without inheriting. Partitioning is newer than the
 *     data, which belongs to a definite account (it is that signed-in user's memoryText and
 *     pinned items), so assigning it to whoever signs in now, on a machine that already belongs
 *     to another account, is exactly the cross-account leak.
 * Called inline from get/set so the activeUID used is the one at call time.
 */
function migrateLegacyPreference(key: string, expectedUID?: string): void {
  const uid = expectedUID ?? getActiveUIDSync();
  const claim = resolveLegacyBareKeyClaim(uid);
  const newKey = prefixed(key, uid);
  if (localStorage.getItem(newKey) !== null) return; // A per-UID value already exists, nothing to migrate
  const legacyKey = legacyPrefixed(key);
  const legacyRaw = localStorage.getItem(legacyKey);
  if (legacyRaw === null) return; // Nothing to migrate
  if (claim === 'discard') {
    localStorage.removeItem(legacyKey);
    return;
  }
  localStorage.setItem(newKey, legacyRaw);
  if (claim === 'inherit') {
    localStorage.removeItem(legacyKey);
  }
}

export function getPreference<T>(key: string, fallback: T, expectedUID?: string): T {
  if (typeof window === 'undefined') return fallback;
  try {
    migrateLegacyPreference(key, expectedUID);
    const raw = localStorage.getItem(prefixed(key, expectedUID));
    return raw !== null ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

export function setPreference(key: string, value: unknown, expectedUID?: string): void {
  if (typeof window === 'undefined') return;
  try {
    // Consume (delete) the old global key before writing, to avoid a later misread or a repeated migration
    migrateLegacyPreference(key, expectedUID);
    localStorage.setItem(prefixed(key, expectedUID), JSON.stringify(value));
  } catch {
    /* quota exceeded — silently ignore */
  }
}

export function removePreference(key: string): void {
  if (typeof window === 'undefined') return;
  localStorage.removeItem(prefixed(key));
  // Under a real account, clear any leftover old global key so the next get does not migrate the
  // value back and resurrect a preference the user cleared. Guests keep the old global key, in
  // line with migrateLegacyPreference, so the first real sign-in is not deprived of the data.
  if (getActiveUIDSync() !== 'guest') {
    localStorage.removeItem(legacyPrefixed(key));
  }
}
