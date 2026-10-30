import { describe, expect, it } from 'vitest';
import type { CatalogEntry } from '../search-catalog';
import {
  customFormFieldErrors,
  customServiceEditPlan,
  migratedDefaultSearchService,
  searchResultCount,
  searchServiceDisplayName,
  resolveDefaultSearchService,
  searchAddSheetSections,
  searchConsentLines,
  searchPriceSummary,
  searchServiceRowState,
  searchTestPresentation,
  RESULT_COUNT_CHOICES,
  RESULT_COUNT_DEFAULT,
  SEARXNG_SETUP_GUIDE_URL,
} from '../search-settings';
import { catalogEntry, loadContract } from './fixtures';

const settings = loadContract('shared/search-contracts/search-settings.v1.json');
const catalog: { services: CatalogEntry[] } = loadContract('shared/search-contracts/search_catalog_contract.v1.json').catalog;

const pick = (ids: string[]) => ids.map((id) => catalogEntry(catalog, id));
const entryOrNull = (id: string | undefined) => (id && catalog.services.some((s) => s.id === id) ? catalogEntry(catalog, id) : null);

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function eachCase(group: string, run: (c: any) => unknown) {
  const cases = settings[group];
  expect(cases.length).toBeGreaterThan(0);
  for (const c of cases) expect(run(c), c.caseId).toEqual(c.expect);
}

describe('external search settings page rules (search-settings.v1)', () => {
  it('constants match the fixture: count options, default count, SearXNG settings doc', () => {
    expect(RESULT_COUNT_CHOICES).toEqual(settings.constants.resultCountChoices);
    expect(RESULT_COUNT_DEFAULT).toBe(settings.constants.resultCountDefault);
    expect(SEARXNG_SETUP_GUIDE_URL).toBe(settings.constants.searxngSetupGuideUrl);
  });

  it('SRCH-SET-01 addSheetCases: reuse group, domestic / overseas groups, already added, catalog unavailable', () => {
    eachCase('addSheetCases', (c) => searchAddSheetSections({ ...c.input, entries: pick(c.input.serviceIds) }));
  });

  it('SRCH-SET-02 priceCases: currency prefix, non-currency pricing, free quota, number of other sites', () => {
    eachCase('priceCases', (c) => searchPriceSummary(pick([c.input.serviceId])[0], c.input.regionId));
  });

  it('SRCH-SET-03 rowCases: presets are judged by catalog -> withdrawn -> host -> connection -> key; custom services are only ever ready', () => {
    eachCase('rowCases', (c) => searchServiceRowState({ ...c.input, entry: entryOrNull(c.input.service.serviceId) }));
  });

  it('SRCH-SET-04 defaultCases: use the saved default if it still exists, otherwise the earliest one', () => {
    eachCase('defaultCases', (c) => ({ defaultId: resolveDefaultSearchService(c.input) }));
  });

  it('SRCH-SET-05 consentCases: consent sentences for preset / custom x mobile / Web', () => {
    eachCase('consentCases', (c) => searchConsentLines(c.input));
  });

  it('SRCH-SET-06 testCases: 0 results counts as a pass, duration rounded to 0.1 s, settings page actions', () => {
    eachCase('testCases', (c) => searchTestPresentation(c.input));
  });

  it('SRCH-SET-07 formCases: error codes attach to fields, only the first error per field, plaintext on LAN only warns', () => {
    eachCase('formCases', (c) => customFormFieldErrors(c.input));
    expect(() => customFormFieldErrors({ errors: ['no_such_code'] })).toThrow(/unmapped form error/);
  });

  it('SRCH-SET-08 countCases: anything not in 3 / 5 / 8 / 10 is treated as 5', () => {
    eachCase('countCases', (c) => ({ count: searchResultCount(c.input.stored) }));
  });

  it('SRCH-SET-09 nameCases: presets fall back catalog -> saved name -> serviceId; custom services use their own name', () => {
    eachCase('nameCases', (c) => ({ name: searchServiceDisplayName(c.input) }));
  });

  it('SRCH-SET-10 migrateDefaultCases: the guest default is carried over only if the account had no services', () => {
    eachCase('migrateDefaultCases', (c) => migratedDefaultSearchService(c.input));
  });

  it('SRCH-SET-11 editCases: rename-only saves directly; changing the source clears the key and shows the key field; the snapshot is retaken only when the reference changes', () => {
    eachCase('editCases', (c) => customServiceEditPlan(c.input));
  });
});
