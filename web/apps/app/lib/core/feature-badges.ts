/**
 * New-feature dots on entry rows.
 *
 * The registered id list mirrors shared/ui-contracts/feature-badges.v1.json; a unit test
 * compares the two entry by entry. The seen set is device-local only (never synced,
 * never part of preferences), stored through safeLocalStorage.
 */

import { safeLocalStorage } from '../infra/storage/web-storage';

export const FEATURE_BADGE_IDS = {
  settingsMemory: 'settings.memory.2026-10',
} as const;

export type FeatureBadgeId = (typeof FEATURE_BADGE_IDS)[keyof typeof FEATURE_BADGE_IDS];

export const REGISTERED_FEATURE_BADGE_IDS: readonly FeatureBadgeId[] = Object.values(FEATURE_BADGE_IDS);

export const FEATURE_BADGES_SEEN_KEY = 'oriveo.featureBadges.seen';

const listeners = new Set<() => void>();

function isRegistered(id: string): id is FeatureBadgeId {
  return (REGISTERED_FEATURE_BADGE_IDS as readonly string[]).includes(id);
}

function parseSeen(raw: string | null): string[] {
  if (!raw) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((value): value is string => typeof value === 'string') : [];
  } catch {
    return [];
  }
}

/** Reads the seen set and drops ids no longer registered, writing back when anything was dropped. */
function readSeen(): FeatureBadgeId[] {
  const raw = safeLocalStorage.getItem(FEATURE_BADGES_SEEN_KEY);
  const stored = parseSeen(raw);
  const pruned = [...new Set(stored.filter(isRegistered))];
  if (raw !== null && JSON.stringify(pruned) !== raw) {
    safeLocalStorage.setItem(FEATURE_BADGES_SEEN_KEY, JSON.stringify(pruned));
  }
  return pruned;
}

/** Whether the dot for `id` should show. Unavailable storage never shows a dot and never throws. */
export function isUnseen(id: FeatureBadgeId): boolean {
  if (!isRegistered(id)) return false;
  if (safeLocalStorage.availability() !== 'available') return false;
  return !readSeen().includes(id);
}

export function markSeen(id: FeatureBadgeId): void {
  if (!isRegistered(id)) return;
  if (safeLocalStorage.availability() !== 'available') return;
  const seen = readSeen();
  if (seen.includes(id)) return;
  safeLocalStorage.setItem(FEATURE_BADGES_SEEN_KEY, JSON.stringify([...seen, id]));
  listeners.forEach((listener) => listener());
}

/** Subscribe to seen-set changes (same tab via markSeen, other tabs via the storage event). */
export function subscribeFeatureBadges(listener: () => void): () => void {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    if (event.key === null || event.key === FEATURE_BADGES_SEEN_KEY) listener();
  };
  if (typeof window !== 'undefined') window.addEventListener('storage', onStorage);
  return () => {
    listeners.delete(listener);
    if (typeof window !== 'undefined') window.removeEventListener('storage', onStorage);
  };
}
