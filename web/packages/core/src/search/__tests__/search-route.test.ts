import { describe, expect, it } from 'vitest';
import { SEARCH_CATALOG_SNAPSHOT_VIEW } from '../catalog-snapshot';
import type { CatalogEntry } from '../search-catalog';
import {
  oneTapReuseTarget,
  planSearchCalls,
  regenerateSearchPolicy,
  resolveSearchSource,
  resolveSearchTurnPath,
  resolveWebSearchRoute,
  resolveWebSearchState,
  searchServiceSelectable,
  searchSourcePickerItems,
  searchSourceStorageKey,
  updateSearchSource,
  webSearchCardPresentation,
} from '../search-route';
import { loadContract } from './fixtures';

const route = loadContract('shared/search-contracts/web-route-resolution.v1.json');
// One-tap entries come from this client's built-in catalog snapshot (the one in the app bundle), not a separate copy
const snapshotServices = (SEARCH_CATALOG_SNAPSHOT_VIEW as { data: { services: CatalogEntry[] } }).data.services;
const fromSnapshot = (ids: string[]) =>
  ids.map((id) => {
    const e = snapshotServices.find((s) => s.id === id);
    if (!e) throw new Error(`snapshot has no service ${id}`);
    return e;
  });

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function eachCase(group: string, run: (c: any) => unknown) {
  const cases = route[group];
  expect(cases.length).toBeGreaterThan(0);
  for (const c of cases) expect(run(c), c.caseId).toEqual(c.expect);
}

describe('web search card and route resolution (web-route-resolution.v1)', () => {
  it('SRCH-ROUTE-01 cases: web search row and the route for this turn', () => {
    eachCase('cases', (c) => resolveWebSearchRoute(c.input));
  });

  it('SRCH-ROUTE-02 turnCases: tool calling falls back to pre-search; which web-search field goes in the request', () => {
    eachCase('turnCases', (c) => resolveSearchTurnPath(c.input));
  });

  it('SRCH-ROUTE-03 selectableCases: withdrawn entries and an unavailable catalog do not count as selectable services', () => {
    eachCase('selectableCases', (c) => ({ selectable: searchServiceSelectable(c.input.status) }));
  });

  it('SRCH-ROUTE-04 oneTapCases: same provider first, host picks the site, null when the catalog is unavailable', () => {
    eachCase('oneTapCases', (c) => ({ target: oneTapReuseTarget({ ...c.input, entries: fromSnapshot(c.input.serviceIds ?? []) }) }));
  });

  it('SRCH-ROUTE-05 sourceCases: read route by conversation source, with a one-time fallback notice', () => {
    eachCase('sourceCases', (c) => resolveSearchSource(c.input));
    expect(searchSourceStorageKey('conv-1')).toBe('conversationSource:conv-1');
  });

  it('SRCH-ROUTE-06 sourceUpdateCases: write path for choosing a source and confirming the notice', () => {
    eachCase('sourceUpdateCases', (c) => ({ nextStored: updateSearchSource(c.input) }));
  });

  it('SRCH-ROUTE-07 pickerCases: rows and selection of the "Search method" sheet', () => {
    eachCase('pickerCases', (c) => ({ items: searchSourcePickerItems(c.input) }));
  });

  it('SRCH-ROUTE-08 cardCases: web card copy keys, toggle, links, and primary/secondary actions', () => {
    eachCase('cardCases', (c) => webSearchCardPresentation(c.input));
  });

  it('SRCH-ROUTE-09 stateCases: combined entry for panel and send (shape, toggle, external hint shown once, native field suppressed)', () => {
    eachCase('stateCases', (c) => resolveWebSearchState(c.input));
  });

  it('SRCH-CALL-01 callCases: at most 3 requests per reply; 408 / 502 / 503 retry once and count toward the cap', () => {
    eachCase('callCases', (c) => planSearchCalls(c.input));
  });

  it('SRCH-CALL-02 regenerateCases: regenerate / edit-and-resend reuse the last results by default; only an explicit re-search searches again', () => {
    eachCase('regenerateCases', (c) => regenerateSearchPolicy(c.input));
  });
});
