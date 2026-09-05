/**
 * Reclaim leftover localStorage keys when the origin quota is under pressure.
 *
 * Some clients persist pending work as many small keys. If those accumulate,
 * later writes throw QuotaExceededError. This module drops only leftover
 * mutation-queue keys and leaves app preferences intact.
 */

import {
  LOCAL_STORAGE_QUOTA_CHARS,
  estimateLocalStorageUsage,
  installLocalStorageQuotaGuard as installGuard,
  safeLocalStorage,
} from './web-storage';

/** Prefix for leftover mutation-queue keys. */
const FIRESTORE_MUTATION_KEY_PREFIX = 'firestore_mutations_';

/**
 * Deliberately the same value as the storage-health warning threshold: that warning says trouble is
 * coming, and this is the self-repair right before it lands, so the two should fire together.
 */
const RECLAIM_TRIGGER_RATIO = 0.6;

export interface QuotaReclaimResult {
  /** Whether reclaim actually ran; false when the threshold was not reached. */
  ran: boolean;
  /** Number of keys removed. */
  removedKeys: number;
  /** Characters reclaimed, counting both key names and values. */
  freedChars: number;
  /** Usage after the pass, or null when it cannot be measured. */
  usageAfter: number | null;
}

const IDLE_RESULT: QuotaReclaimResult = {
  ran: false,
  removedKeys: 0,
  freedChars: 0,
  usageAfter: null,
};

let cachedResult: QuotaReclaimResult | null = null;

/**
 * Drop leftover mutation-queue keys when localStorage is above the trigger ratio.
 */
export function reclaimLocalStorageQuota(): QuotaReclaimResult {
  if (cachedResult) return cachedResult;
  if (typeof window === 'undefined') return IDLE_RESULT;

  try {
    const usageBefore = estimateLocalStorageUsage();
    if (usageBefore === null || usageBefore / LOCAL_STORAGE_QUOTA_CHARS <= RECLAIM_TRIGGER_RATIO) {
      cachedResult = { ...IDLE_RESULT, usageAfter: usageBefore };
      return cachedResult;
    }

    let removedKeys = 0;
    let freedChars = 0;
    // Collect the key names first: deleting while iterating shifts the `Storage.key(i)` index.
    for (const key of safeLocalStorage.keys()) {
      if (!key.startsWith(FIRESTORE_MUTATION_KEY_PREFIX)) continue;
      const value = safeLocalStorage.getItem(key);
      if (safeLocalStorage.removeItem(key)) {
        removedKeys += 1;
        freedChars += key.length + (value?.length ?? 0);
      }
    }

    cachedResult = {
      ran: true,
      removedKeys,
      freedChars,
      usageAfter: estimateLocalStorageUsage(),
    };
    return cachedResult;
  } catch {
    // The self-repair must never become a new startup failure.
    cachedResult = IDLE_RESULT;
    return cachedResult;
  }
}

/**
 * True when localStorage is still above the reclaim trigger after a pass.
 */
export function localStorageStillUnderPressure(): boolean {
  const usage = reclaimLocalStorageQuota().usageAfter ?? estimateLocalStorageUsage();
  if (usage === null) return false;
  return usage / LOCAL_STORAGE_QUOTA_CHARS > RECLAIM_TRIGGER_RATIO;
}

/** Drop leftover mutation-queue keys regardless of current usage. */
function forceReclaimMutationKeys(): number {
  let removed = 0;
  try {
    for (const key of safeLocalStorage.keys()) {
      if (!key.startsWith(FIRESTORE_MUTATION_KEY_PREFIX)) continue;
      if (safeLocalStorage.removeItem(key)) removed += 1;
    }
  } catch {
    /* The guard itself must never throw. */
  }
  return removed;
}

let guardInstalled = false;
let guardRecoveries = 0;

/**
 * Intercept QuotaExceededError on setItem and drop leftover mutation-queue keys.
 */
export function installLocalStorageQuotaGuard(): void {
  if (guardInstalled) return;
  guardInstalled = installGuard(() => {
    const removed = forceReclaimMutationKeys();
    if (removed > 0) guardRecoveries += 1;
    return removed;
  });
}

/** How many writes the quota guard has rescued, reported by storage-health. */
export function localStorageQuotaRecoveries(): number {
  return guardRecoveries;
}

/** Test only: reset the one-shot gate. */
export function __resetQuotaReclaimForTest(): void {
  cachedResult = null;
  guardRecoveries = 0;
}
