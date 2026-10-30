// Shared test helpers: read the originals under shared/search-contracts, look up catalog entries by serviceId, normalize requests semantically.
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import type { CatalogEntry, CatalogRegion } from '../search-catalog';
import type { SearchRequest } from '../search-transport';

export const REPO_ROOT = resolve(__dirname, '../../../../../..');

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function loadContract(relativePath: string): any {
  return JSON.parse(readFileSync(resolve(REPO_ROOT, relativePath), 'utf8'));
}

/** Deep-copies a catalog entry so tests can modify site fields without touching the original. */
export function catalogEntry(catalog: { services: CatalogEntry[] }, serviceId: string): CatalogEntry {
  const entry = catalog.services.find((s) => s.id === serviceId);
  if (!entry) throw new Error(`fixture has no service ${serviceId}`);
  return structuredClone(entry);
}

export function catalogRegion(entry: CatalogEntry, regionId: string): CatalogRegion {
  const region = entry.regions.find((r) => r.id === regionId);
  if (!region) throw new Error(`service ${entry.id} has no region ${regionId}`);
  return region;
}

/** Request comparison basis: method, scheme://host[:port]/path, decoded query (unordered), headers, and JSON-semantic body. */
export function normalizeRequest(req: Pick<SearchRequest, 'method' | 'url' | 'headers' | 'body'>) {
  const url = new URL(req.url);
  const query = [...url.searchParams.entries()].map(([k, v]) => `${k}=${v}`).sort();
  return {
    method: req.method,
    endpoint: `${url.protocol}//${url.host}${url.pathname}`,
    query,
    headers: req.headers,
    body: req.body === null ? null : JSON.parse(JSON.stringify(req.body)),
  };
}
