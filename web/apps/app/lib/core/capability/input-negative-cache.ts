/**
 * Web negative cache v2 of input capabilities for all connections.
 *
 * Key = connection x model x effective protocol family x capability key (parameters are written `param:<name>`); value = recorded time + rejection signature id + the ruling revision at record time.
 * Expires after 7 days (only expiry deletes an entry); a read passes the current ruling revision, and a mismatch does not count: it returns null without deleting the entry.
 * Local only (not part of cloud sync or backup). v1 (`oriveo.relay-negative-cache.v1`) is neither read nor migrated.
 */
import { safeLocalStorage } from '../../infra/storage/web-storage';

export const INPUT_NEGATIVE_CACHE_STORAGE_KEY = 'oriveo.capability-negative-cache.v2';
export const INPUT_NEGATIVE_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** Capability key: the raw input capability key, or `param:<parameter name>`. */
export type InputNegativeCacheCapabilityKey = string;

export interface InputNegativeCacheKey {
  connectionId: string;
  modelId: string;
  wireFamily: string;
  capabilityKey: InputNegativeCacheCapabilityKey;
}

export interface InputNegativeCacheValue {
  recordedAt: number;
  signatureId: string;
  verdictRevision: string;
}

interface StoredEntry extends InputNegativeCacheKey, InputNegativeCacheValue {}

/** Parameter-type capability key. */
export function paramCapabilityKey(name: string): InputNegativeCacheCapabilityKey {
  return `param:${name}`;
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value !== '';
}

function isStoredEntry(value: unknown): value is StoredEntry {
  if (typeof value !== 'object' || value === null) return false;
  const entry = value as Record<string, unknown>;
  return isNonEmptyString(entry.connectionId)
    && isNonEmptyString(entry.modelId)
    && isNonEmptyString(entry.wireFamily)
    && isNonEmptyString(entry.capabilityKey)
    && isNonEmptyString(entry.signatureId)
    && isNonEmptyString(entry.verdictRevision)
    && typeof entry.recordedAt === 'number' && Number.isFinite(entry.recordedAt);
}

// Bad data / unavailable storage always reads as empty: an absent negative cache only means the entry point shows as usual and the request is sent as usual, never a wrong rejection.
function readEntries(): StoredEntry[] {
  try {
    const raw = safeLocalStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY);
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
      safeLocalStorage.removeItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY);
      return;
    }
    safeLocalStorage.setItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY, JSON.stringify({ version: 2, entries }));
  } catch {
    // A failed write does not affect sending; the next rejection writes again.
  }
}

function sameKey(entry: InputNegativeCacheKey, key: InputNegativeCacheKey): boolean {
  return entry.connectionId === key.connectionId
    && entry.modelId === key.modelId
    && entry.wireFamily === key.wireFamily
    && entry.capabilityKey === key.capabilityKey;
}

function isLive(entry: StoredEntry, now: number): boolean {
  return now - entry.recordedAt < INPUT_NEGATIVE_CACHE_TTL_MS;
}

/** Record one rejection; the same key is overwritten and expired entries are dropped along the way. */
export function recordInputNegativeCache(
  key: InputNegativeCacheKey,
  value: { signatureId: string; verdictRevision: string },
  now = Date.now(),
): void {
  const kept = readEntries().filter((entry) => isLive(entry, now) && !sameKey(entry, key));
  kept.push({
    connectionId: key.connectionId,
    modelId: key.modelId,
    wireFamily: key.wireFamily,
    capabilityKey: key.capabilityKey,
    recordedAt: now,
    signatureId: value.signatureId,
    verdictRevision: value.verdictRevision,
  });
  writeEntries(kept);
}

/**
 * Read a rejection that is still valid; when expired return null and delete the entry; when the ruling revision differs from the current one return null but keep the entry.
 */
export function readInputNegativeCache(
  key: InputNegativeCacheKey,
  currentVerdictRevision: string,
  now = Date.now(),
): InputNegativeCacheValue | null {
  const entries = readEntries();
  const hit = entries.find((entry) => sameKey(entry, key));
  if (!hit) return null;
  if (!isLive(hit, now)) {
    writeEntries(entries.filter((entry) => entry !== hit));
    return null;
  }
  // A revision mismatch only reads as null without deleting: a read surface with incomplete context computes the revision from another ruling, and deleting would make the send side that has the context lose the rejection record.
  if (hit.verdictRevision !== currentVerdictRevision) return null;
  return { recordedAt: hit.recordedAt, signatureId: hit.signatureId, verdictRevision: hit.verdictRevision };
}

/** Clear several entries (user manually sets an override / re-detects that key). */
export function clearInputNegativeCache(keys: readonly InputNegativeCacheKey[]): void {
  const entries = readEntries();
  const kept = entries.filter((entry) => !keys.some((key) => sameKey(entry, key)));
  if (kept.length !== entries.length) writeEntries(kept);
}

/** Clear a whole connection (re-detect / delete the connection). */
export function clearInputNegativeCacheConnection(connectionId: string): void {
  const entries = readEntries();
  const kept = entries.filter((entry) => entry.connectionId !== connectionId);
  if (kept.length !== entries.length) writeEntries(kept);
}

/** Ruling fields that take part in the revision. */
export interface InputVerdictLike {
  state: string;
  reasonCode?: string | null;
  wireFamily?: string | null;
  sourceRefs?: readonly string[] | null;
}

/** Canonical JSON: keys in lexicographic order, absent / null fields omitted, sourceRefs sorted. */
function canonicalVerdictJson(verdict: InputVerdictLike | null | undefined): string {
  const source: InputVerdictLike = verdict ?? { state: 'unknown' };
  const canonical: Record<string, unknown> = {};
  if (source.reasonCode != null) canonical.reasonCode = source.reasonCode;
  if (source.sourceRefs != null) canonical.sourceRefs = [...source.sourceRefs].sort();
  canonical.state = source.state;
  if (source.wireFamily != null) canonical.wireFamily = source.wireFamily;
  return JSON.stringify(canonical);
}

/** FNV-1a 32-bit over UTF-8 bytes, output as 8 lowercase hex digits. */
function fnv1a32Hex(text: string): string {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(text)) {
    hash ^= byte;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

/** Ruling revision: changes whenever any of the ruling state / reasonCode / wireFamily / sourceRefs changes. */
export function inputVerdictRevision(verdict: InputVerdictLike | null | undefined): string {
  return fnv1a32Hex(canonicalVerdictJson(verdict));
}
