import { classifyRelayKeyAccess } from './relay-key-access';

/**
 * Merging of per-key catalog fetches for a relay (fixture `key-binding.v1.json` catalogCases).
 * Used only when the connection has two or more keys; with one key, catalog refresh takes the original path. Pure function, no network.
 */

export type RelayKeyCatalogResult =
  | { ok: readonly string[] }
  | { status: number | null; body: string }
  | 'skipped';

export type RelayKeyCatalogStatus = 'ok' | 'invalid' | 'denied' | 'limited' | 'failed';

export interface RelayKeyCatalogEntry {
  id: string;
  relayListedByKeyIDs: string[];
}

export interface RelayKeyCatalogMerge {
  catalog: RelayKeyCatalogEntry[];
  /** The skipped key does not appear (status unchanged). */
  statuses: Record<string, RelayKeyCatalogStatus>;
}

/** What status to record for a key whose catalog fetch failed: invalid key / quota per the classifier, other 403 records denied, everything else (including network / decoding) records failed. */
export function relayKeyCatalogFailureStatus(status: number | null, body: string): RelayKeyCatalogStatus {
  if (status === null) return 'failed';
  const outcome = classifyRelayKeyAccess(status, body);
  if (outcome === 'key_invalid') return 'invalid';
  if (outcome === 'key_limited') return 'limited';
  return status === 403 ? 'denied' : 'failed';
}

/**
 * Merge in key order: a succeeded key contributes the ids fetched this time in upstream order, a failed or skipped key contributes entries that listed it in the last catalog (last order),
 * first appearance decides position. Listers = all keys listing that id (key order); an entry from last time with no lister is treated as listed by the primary key.
 * An id that no key lists leaves the catalog (enabled / manual models are covered by the caller's existing retention logic). A failure never clears entries that key listed last time.
 */
export function mergeRelayKeyCatalogs(
  keys: readonly string[],
  previous: readonly { id: string; relayListedByKeyIDs?: readonly string[] }[],
  results: Readonly<Record<string, RelayKeyCatalogResult | undefined>>,
): RelayKeyCatalogMerge {
  const primary = keys[0];
  const order: string[] = [];
  const listers = new Map<string, Set<string>>();
  const list = (id: string, key: string) => {
    let set = listers.get(id);
    if (!set) {
      set = new Set();
      listers.set(id, set);
      order.push(id);
    }
    set.add(key);
  };
  const statuses: Record<string, RelayKeyCatalogStatus> = {};
  for (const key of keys) {
    const result = results[key] ?? 'skipped';
    if (result !== 'skipped' && 'ok' in result) {
      for (const id of result.ok) list(id, key);
      statuses[key] = 'ok';
      continue;
    }
    for (const entry of previous) {
      const listed = entry.relayListedByKeyIDs ?? (primary ? [primary] : []);
      if (listed.includes(key)) list(entry.id, key);
    }
    if (result !== 'skipped') statuses[key] = relayKeyCatalogFailureStatus(result.status, result.body);
  }
  return {
    catalog: order.map((id) => ({
      id,
      relayListedByKeyIDs: keys.filter((key) => listers.get(id)!.has(key)),
    })),
    statuses,
  };
}
