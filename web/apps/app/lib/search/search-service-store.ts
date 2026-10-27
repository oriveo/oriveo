/**
 * Local persistence layer for external search services (external search service contract section 11).
 *
 * One independent IndexedDB per account partition (`oriveo-search--<uid>`, the same approach as the MCP store `oriveo-mcp--<uid>`):
 * service list + search keys + local keys (default service id). Keys are on par with BYOK: kept only in this browser, partitioned by account; excluded from lib/backup exports
 * and from account sync (this store has no sync slot, and backup reads only the main partition store).
 *
 * - Preset services store the bound host (boundHost) and the key is bound to that host; when a model connection is reused, only the connection reference is stored, never a key.
 * - A custom service's key is bound to the address's keyBindingOrigin: when the origin changes the key is cleared immediately (a path change does not clear it).
 *
 * Every function takes `uid` explicitly and never reads the "current partition": a write for account A can never land in B's store at the moment of an account switch.
 */

import { openDB, type DBSchema, type IDBPDatabase } from 'idb';
import {
  addressChangeClearsKey,
  keyBindingOrigin,
  normalizeSearchKey,
  type CustomProtocol,
  type TransportSpec,
} from '@oriveo/core/search/search-transport';
import { migratedDefaultSearchService } from '@oriveo/core/search/search-settings';
import { searchSourceStorageKey, type StoredSearchSource } from '@oriveo/core/search/search-route';
import { openWithStaleSchemaRecovery, reportIDBUpgradeBlocked } from '../infra/storage/idb-lifecycle';
import { getSearchDBName } from '../infra/storage/partition';

export { getSearchDBName };

// v2: added the meta table (local keys such as the default service id)
export const SEARCH_DB_VERSION = 2;

const DEFAULT_SERVICE_META_KEY = 'defaultServiceId';

export interface StoredPresetSearchService {
  id: string;
  kind: 'preset';
  serviceId: string;
  /** displayName from the catalog at save time: keeps a name when the catalog is unavailable or the entry was withdrawn (fallback for searchServiceDisplayName) */
  name?: string;
  regionId: string;
  /** The site's host in the catalog when saved (or re-confirmed); differing from the current catalog = host_changed, no key sent */
  boundHost: string;
  /** Connection reference (provider id) when a model connection is reused; with it no key is stored */
  connectionRef: string | null;
  /** Detail page "Advanced > Results per search" (one of RESULT_COUNT_CHOICES); default = RESULT_COUNT_DEFAULT */
  resultCount?: number;
  createdAt: number;
  updatedAt: number;
  /** A half-finished add flow: not migrated from guest into an account. Default = confirmed */
  pendingAdd?: boolean;
}

export interface StoredCustomSearchService {
  id: string;
  kind: 'custom';
  name: string;
  protocol: CustomProtocol;
  address: string;
  /** Snapshot of a manual mapping / "Same as X" mapping; null for SearXNG */
  mapping: TransportSpec | null;
  /** Detail page "Advanced > Results per search" (one of RESULT_COUNT_CHOICES); default = RESULT_COUNT_DEFAULT */
  resultCount?: number;
  createdAt: number;
  updatedAt: number;
  /** A half-finished add flow: not migrated from guest into an account. Default = confirmed */
  pendingAdd?: boolean;
}

export type StoredSearchService = StoredPresetSearchService | StoredCustomSearchService;

interface StoredSearchKey {
  key: string;
  /** Preset = boundHost; custom = keyBindingOrigin(address) */
  boundTo: string;
}

interface SearchDBSchema extends DBSchema {
  services: { key: string; value: StoredSearchService };
  credentials: { key: string; value: StoredSearchKey };
  /** Local key-values (default service id, per-conversation search source JSON): same partition as the service list, not synced and not in backups */
  meta: { key: string; value: string };
}

type SearchDB = IDBPDatabase<SearchDBSchema>;

/** Save result: when the key is non-compliant (key_empty / key_invalid, as judged by normalizeSearchKey) nothing is written. */
export type SaveSearchServiceResult = { ok: true } | { ok: false; error: 'key_empty' | 'key_invalid' };

/** Key option: string = normalized and written; null = cleared; undefined = untouched. */
function normalizedKeyOption(key: string | null | undefined): { ok: true; key: string | null | undefined } | { ok: false; error: 'key_empty' | 'key_invalid' } {
  if (key === null || key === undefined) return { ok: true, key };
  const normalized = normalizeSearchKey(key);
  return normalized.ok ? { ok: true, key: normalized.key } : normalized;
}

const connections = new Map<string, Promise<SearchDB>>();

export function openSearchDB(uid: string): Promise<SearchDB> {
  const cached = connections.get(uid);
  if (cached) return cached;
  const name = getSearchDBName(uid);
  let opened: SearchDB | null = null;
  const promise = openWithStaleSchemaRecovery(() => openDB<SearchDBSchema>(name, SEARCH_DB_VERSION, {
    upgrade(db, oldVersion) {
      if (oldVersion < 1) {
        db.createObjectStore('services', { keyPath: 'id' });
        db.createObjectStore('credentials');
      }
      if (oldVersion < 2) {
        db.createObjectStore('meta');
      }
    },
    blocked: (currentVersion, blockedVersion) => reportIDBUpgradeBlocked(name, currentVersion, blockedVersion),
    // Another tab wants to upgrade / delete the partition: yield and drop the cache
    blocking: () => {
      opened?.close();
      connections.delete(uid);
    },
  })).then((db) => {
    opened = db;
    return db;
  });
  promise.catch(() => connections.delete(uid));
  connections.set(uid, promise);
  return promise;
}

/** Close and discard a partition's connection (call before deleting the store and between tests). */
export async function closeSearchDB(uid: string): Promise<void> {
  const cached = connections.get(uid);
  connections.delete(uid);
  if (cached) (await cached.catch(() => null))?.close();
}

export async function listSearchServices(uid: string): Promise<StoredSearchService[]> {
  const all = await (await openSearchDB(uid)).getAll('services');
  return all.sort((a, b) => a.createdAt - b.createdAt);
}

export async function getSearchService(uid: string, id: string): Promise<StoredSearchService | null> {
  return (await (await openSearchDB(uid)).get('services', id)) ?? null;
}

/**
 * Save a preset service. `key`: string = normalized, written and bound to boundHost; null = cleared; undefined = untouched.
 * When reusing a connection (connectionRef non-empty) no key is ever stored. Re-confirming the host saves with the new boundHost, and any existing key is rebound with it.
 */
export async function savePresetSearchService(
  uid: string,
  service: StoredPresetSearchService,
  options: { key?: string | null } = {},
): Promise<SaveSearchServiceResult> {
  const keyOption = normalizedKeyOption(options.key);
  if (!keyOption.ok) return keyOption;
  const db = await openSearchDB(uid);
  const tx = db.transaction(['services', 'credentials'], 'readwrite');
  const credentials = tx.objectStore('credentials');
  await tx.objectStore('services').put(service);
  if (service.connectionRef || keyOption.key === null) {
    await credentials.delete(service.id);
  } else if (typeof keyOption.key === 'string') {
    await credentials.put({ key: keyOption.key, boundTo: service.boundHost }, service.id);
  } else {
    const existing = await credentials.get(service.id);
    if (existing && existing.boundTo !== service.boundHost) {
      await credentials.put({ ...existing, boundTo: service.boundHost }, service.id);
    }
  }
  await tx.done;
  return { ok: true };
}

/**
 * Save a custom service. If the address's origin (scheme://host[:port]) changed, the old key is cleared first;
 * `key`: string = normalized, written and bound to the new address's origin; null = cleared; undefined = untouched.
 */
export async function saveCustomSearchService(
  uid: string,
  service: StoredCustomSearchService,
  options: { key?: string | null } = {},
): Promise<SaveSearchServiceResult> {
  const keyOption = normalizedKeyOption(options.key);
  if (!keyOption.ok) return keyOption;
  const origin = keyBindingOrigin(service.address);
  const db = await openSearchDB(uid);
  const tx = db.transaction(['services', 'credentials'], 'readwrite');
  const services = tx.objectStore('services');
  const credentials = tx.objectStore('credentials');
  const previous = await services.get(service.id);
  if (previous?.kind === 'custom' && addressChangeClearsKey(previous.address, service.address)) {
    await credentials.delete(service.id);
  }
  await services.put(service);
  if (keyOption.key === null || !origin) {
    await credentials.delete(service.id);
  } else if (typeof keyOption.key === 'string') {
    await credentials.put({ key: keyOption.key, boundTo: origin }, service.id);
  }
  await tx.done;
  return { ok: true };
}

/**
 * Fetch the key before a request. Preset: given only when the bound host matches the service record; custom: if the key's bound origin differs from the current address it is cleared and null is returned.
 */
export async function readSearchServiceKey(uid: string, id: string): Promise<string | null> {
  const db = await openSearchDB(uid);
  const service = await db.get('services', id);
  const stored = await db.get('credentials', id);
  if (!service || !stored) return null;
  if (service.kind === 'preset') {
    if (service.connectionRef) return null;
    return stored.boundTo === service.boundHost ? stored.key : null;
  }
  if (stored.boundTo !== keyBindingOrigin(service.address)) {
    await db.delete('credentials', id);
    return null;
  }
  return stored.key;
}

/** Delete a service together with its key; if it was the stored default id, clear that key too. */
export async function removeSearchService(uid: string, id: string): Promise<void> {
  const db = await openSearchDB(uid);
  const tx = db.transaction(['services', 'credentials', 'meta'], 'readwrite');
  await tx.objectStore('services').delete(id);
  await tx.objectStore('credentials').delete(id);
  const meta = tx.objectStore('meta');
  if ((await meta.get(DEFAULT_SERVICE_META_KEY)) === id) await meta.delete(DEFAULT_SERVICE_META_KEY);
  await tx.done;
}

/**
 * The stored default service id (as-is; it may point at a deleted service). The UI always derives the default via resolveDefaultSearchService(ids in storage order, this).
 */
export async function getDefaultSearchServiceId(uid: string): Promise<string | null> {
  return (await (await openSearchDB(uid)).get('meta', DEFAULT_SERVICE_META_KEY)) ?? null;
}

/** Set as default; null = cleared (falls back to the earliest service in storage order). No write if the value is unchanged. */
export async function setDefaultSearchServiceId(uid: string, id: string | null): Promise<void> {
  const db = await openSearchDB(uid);
  const tx = db.transaction('meta', 'readwrite');
  const current = (await tx.store.get(DEFAULT_SERVICE_META_KEY)) ?? null;
  if (current !== id) {
    if (id === null) await tx.store.delete(DEFAULT_SERVICE_META_KEY);
    else await tx.store.put(id, DEFAULT_SERVICE_META_KEY);
  }
  await tx.done;
}

// ── Per-conversation search source (section 4a) ─────────────────────────────────────────

/**
 * Read the search source stored for a conversation (the `stored` input of `resolveSearchSource`, as-is; a bad value counts as never stored).
 * Key `searchSourceStorageKey(conversation id)`, in the meta table of the same partition store as the service list: not synced, not in backups.
 */
export async function getConversationSearchSource(uid: string, conversationId: string): Promise<unknown> {
  const raw = await (await openSearchDB(uid)).get('meta', searchSourceStorageKey(conversationId));
  if (typeof raw !== 'string') return null;
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    return null;
  }
}

/** Write a conversation's search source; null = delete the key. Call only after `resolveSearchSource().changed` is true or a user action (`updateSearchSource`). */
export async function setConversationSearchSource(uid: string, conversationId: string, value: StoredSearchSource | null): Promise<void> {
  const db = await openSearchDB(uid);
  const key = searchSourceStorageKey(conversationId);
  if (value === null) await db.delete('meta', key);
  else await db.put('meta', JSON.stringify(value), key);
}

/** Delete a conversation's source together with the conversation; no write if it was never stored. */
export async function deleteConversationSearchSource(uid: string, conversationId: string): Promise<void> {
  const db = await openSearchDB(uid);
  const key = searchSourceStorageKey(conversationId);
  if ((await db.get('meta', key)) !== undefined) await db.delete('meta', key);
}

// ── guest -> account migration ─────────────────────────────────────────────────────

async function guestSearchDBExists(): Promise<boolean> {
  const databases = typeof indexedDB.databases === 'function' ? await indexedDB.databases() : [];
  return databases.some((database) => database.name === getSearchDBName('guest'));
}

/**
 * Whether the guest partition has any fully added search service (one of the criteria at sign-in for "does the guest have data worth carrying over").
 * If the guest store does not exist it is not created; half-finished entries do not count.
 */
export async function hasGuestSearchServices(): Promise<boolean> {
  if (!(await guestSearchDBExists())) return false;
  return (await (await openSearchDB('guest')).getAll('services')).some((service) => !service.pendingAdd);
}

/**
 * Copy the guest partition's search services together with their keys into the account partition (same rule as providers / MCP: the caller only invokes it when the cloud is empty).
 * Entries whose id already exists in the target are skipped; half-finished ones are not carried. Keys travel with the service, and the binding (boundHost / keyBindingOrigin) is preserved as-is.
 * If the guest store does not exist it is not created. Returns the number of services copied.
 */
export async function migrateGuestSearchData(targetUid: string, conversationIds: readonly string[] = []): Promise<number> {
  if (!targetUid || targetUid === 'guest') return 0;
  if (!(await guestSearchDBExists())) return 0;
  const guest = await openSearchDB('guest');
  const guestServices = await guest.getAll('services');
  // Sources are migrated even when the guest has no services: a source follows its conversation, independent of the service list.
  const keys = new Map<string, StoredSearchKey>();
  for (const service of guestServices) {
    const stored = await guest.get('credentials', service.id);
    if (stored) keys.set(service.id, stored);
  }
  const guestDefault = (await guest.get('meta', DEFAULT_SERVICE_META_KEY)) ?? null;
  const guestSources: Array<[string, string]> = [];
  for (const conversationId of conversationIds) {
    const value = await guest.get('meta', searchSourceStorageKey(conversationId));
    if (typeof value === 'string') guestSources.push([conversationId, value]);
  }

  const db = await openSearchDB(targetUid);
  const tx = db.transaction(['services', 'credentials', 'meta'], 'readwrite');
  const services = tx.objectStore('services');
  const credentials = tx.objectStore('credentials');
  const meta = tx.objectStore('meta');
  const existingIds = new Set((await services.getAllKeys()).map(String));
  const migratedIds: string[] = [];
  let copied = 0;
  for (const service of guestServices) {
    if (existingIds.has(service.id) || service.pendingAdd) continue;
    await services.put(service);
    const stored = keys.get(service.id);
    if (stored) await credentials.put(stored, service.id);
    migratedIds.push(service.id);
    copied += 1;
  }
  // Default id: carry over the guest's effective default (migratedDefaultSearchService) only when the account originally had no services
  const confirmedGuest = guestServices.filter((s) => !s.pendingAdd).sort((a, b) => a.createdAt - b.createdAt);
  const plan = migratedDefaultSearchService({
    accountServiceIds: [...existingIds],
    guestServiceIds: confirmedGuest.map((s) => s.id),
    guestStoredDefault: guestDefault,
    migratedIds,
  });
  if (plan.set) await meta.put(plan.id, DEFAULT_SERVICE_META_KEY);
  // Conversations migrated along carry their sources; existing ones in the account are not overwritten.
  for (const [conversationId, value] of guestSources) {
    const key = searchSourceStorageKey(conversationId);
    if ((await meta.get(key)) === undefined) await meta.put(value, key);
  }
  await tx.done;
  return copied;
}
