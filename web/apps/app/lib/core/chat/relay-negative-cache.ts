/**
 * Local negative cache for Relay upstream rejection loops.
 *
 * Entry = connection x model x effective protocol x tier (image / file / toolCall / reasoningTier:<thinking tier>) + record time, expires after 7 days; only Relay shapes are collected,
 * and only on this device (not in cloud sync or backups). The writer is the send-side rejection loop; the readers are the image entry and the Relay capability truth adapter.
 * Fixture: `test-fixtures/relay/negative-cache.v1.json`; reasoning tier rejection is in `reasoning-tier.v1.json`.
 */
import { safeLocalStorage } from '../../infra/storage/web-storage';

export const RELAY_NEGATIVE_CACHE_STORAGE_KEY = 'oriveo.relay-negative-cache.v1';
export const RELAY_NEGATIVE_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** Relay reasoning tier (the raw ReasoningMode value, excluding automatic). */
export type RelayReasoningTier = 'fast' | 'balanced' | 'deep' | 'max';
export const RELAY_REASONING_TIERS: readonly RelayReasoningTier[] = ['fast', 'balanced', 'deep', 'max'];

export type RelayNegativeCacheKind = 'image' | 'file' | 'toolCall' | `reasoningTier:${RelayReasoningTier}`;

export interface RelayNegativeCacheModelKey {
  connectionId: string;
  modelId: string;
  /** Effective protocol (the value of `effectiveTransport(provider, model)`). */
  transport: string;
}

export interface RelayNegativeCacheKey extends RelayNegativeCacheModelKey {
  kind: RelayNegativeCacheKind;
}

interface StoredEntry extends RelayNegativeCacheKey {
  recordedAt: number;
}

const KINDS: ReadonlySet<string> = new Set<RelayNegativeCacheKind>([
  'image', 'file', 'toolCall',
  ...RELAY_REASONING_TIERS.map((tier) => `reasoningTier:${tier}` as const),
]);

function isStoredEntry(value: unknown): value is StoredEntry {
  if (typeof value !== 'object' || value === null) return false;
  const entry = value as Record<string, unknown>;
  return typeof entry.connectionId === 'string'
    && typeof entry.modelId === 'string'
    && typeof entry.transport === 'string'
    && typeof entry.kind === 'string' && KINDS.has(entry.kind)
    && typeof entry.recordedAt === 'number' && Number.isFinite(entry.recordedAt);
}

// Bad data / unavailable storage is always read as empty: an absent negative cache only makes entries show as usual and requests go out as usual, never a false rejection.
function readEntries(): StoredEntry[] {
  try {
    const raw = safeLocalStorage.getItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    const entries = (parsed as { entries?: unknown })?.entries;
    return Array.isArray(entries) ? entries.filter(isStoredEntry) : [];
  } catch {
    return [];
  }
}

function writeEntries(entries: StoredEntry[]): void {
  try {
    if (entries.length === 0) {
      safeLocalStorage.removeItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY);
      return;
    }
    safeLocalStorage.setItem(RELAY_NEGATIVE_CACHE_STORAGE_KEY, JSON.stringify({ version: 1, entries }));
  } catch {
    // A failed write does not affect sending; the next rejection writes again.
  }
}

function sameModel(entry: RelayNegativeCacheModelKey, key: RelayNegativeCacheModelKey): boolean {
  return entry.connectionId === key.connectionId
    && entry.modelId === key.modelId
    && entry.transport === key.transport;
}

function isLive(entry: StoredEntry, now: number): boolean {
  return now - entry.recordedAt < RELAY_NEGATIVE_CACHE_TTL_MS;
}

/** Record a rejection; the same key overwrites the record time, and expired entries are dropped along the way. */
export function recordRelayNegativeCache(key: RelayNegativeCacheKey, now = Date.now()): void {
  const kept = readEntries().filter((entry) => isLive(entry, now)
    && !(sameModel(entry, key) && entry.kind === key.kind));
  kept.push({
    connectionId: key.connectionId,
    modelId: key.modelId,
    transport: key.transport,
    kind: key.kind,
    recordedAt: now,
  });
  writeEntries(kept);
}

export function isRelayNegativeCached(key: RelayNegativeCacheKey, now = Date.now()): boolean {
  return readEntries().some((entry) => sameModel(entry, key) && entry.kind === key.kind && isLive(entry, now));
}

/** The tiers still within their validity period on this model's current protocol (in record order). */
export function relayNegativeCachedKinds(key: RelayNegativeCacheModelKey, now = Date.now()): RelayNegativeCacheKind[] {
  return readEntries().filter((entry) => sameModel(entry, key) && isLive(entry, now)).map((entry) => entry.kind);
}

/** Clear several tiers of this model's current protocol ("test capability" write-back clears image + toolCall; a user manually setting a tier clears that tier). */
export function clearRelayNegativeCache(
  key: RelayNegativeCacheModelKey,
  kinds: readonly RelayNegativeCacheKind[],
): void {
  const entries = readEntries();
  const kept = entries.filter((entry) => !(sameModel(entry, key) && kinds.includes(entry.kind)));
  if (kept.length !== entries.length) writeEntries(kept);
}

/** Clear a whole connection (re-detect / delete connection). */
export function clearRelayNegativeCacheConnection(connectionId: string): void {
  const entries = readEntries();
  const kept = entries.filter((entry) => entry.connectionId !== connectionId);
  if (kept.length !== entries.length) writeEntries(kept);
}
