import { describe, expect, it } from 'vitest';
import type { CatalogEntry } from '../search-catalog';
import { buildSearchRequest, classifySearchError, ERROR_CLASSES, parseSearchResponse, SEARXNG_SPEC, TOOL_MESSAGES } from '../search-transport';
import { catalogEntry, catalogRegion, loadContract, normalizeRequest } from './fixtures';

const contract = loadContract('shared/search-contracts/search_catalog_contract.v1.json');
const golden = loadContract('shared/search-contracts/transport-golden.v1.json');
const mapping = loadContract('shared/search-contracts/error-mapping.v1.json');

function catalogFor(ref: string): { services: CatalogEntry[] } {
  const [file, pointer] = ref.split('#');
  expect(file).toBe('search_catalog_contract.v1.json');
  return contract[pointer];
}

describe('json_http/v1 golden samples (transport-golden.v1)', () => {
  it('SRCH-TRN-01 builds requests from catalog entries and maps responses and errors', () => {
    const catalog = catalogFor(golden.catalogRef);
    const kinds = new Set<string>();
    for (const c of golden.cases) {
      kinds.add(c.kind);
      const entry = catalogEntry(catalog, c.serviceId);
      if (c.kind === 'request') {
        const region = catalogRegion(entry, c.regionId);
        const req = buildSearchRequest(entry.transport, { scheme: 'https', host: region.host, static: region.static }, c.input);
        if ('skip' in req || c.expect.skip) expect(req, c.caseId).toEqual(c.expect);
        else expect(normalizeRequest(req), c.caseId).toEqual(normalizeRequest(c.expect));
      } else if (c.kind === 'response') {
        expect(parseSearchResponse(entry.transport, c.body), c.caseId).toEqual(c.expect);
      } else if (c.kind === 'error') {
        expect(classifySearchError({ status: c.status, body: c.body, rules: entry.transport.errors }), c.caseId).toEqual(c.expect);
      } else {
        throw new Error(`unknown golden kind ${c.kind} in ${c.caseId}`);
      }
    }
    expect([...kinds].sort()).toEqual(['error', 'request', 'response']);
  });
});

describe('error mapping (error-mapping.v1)', () => {
  it('error classes and the fixed text returned to the model match the fixture verbatim', () => {
    expect(ERROR_CLASSES).toEqual(mapping.constants.classes);
    expect(TOOL_MESSAGES).toEqual(mapping.constants.toolMessages);
  });

  it('SRCH-ERR-01 generic rules + entry / protocol specific rules', () => {
    expect(mapping.cases.length).toBeGreaterThan(0);
    for (const c of mapping.cases) {
      const { serviceId, protocol, ...rest } = c.input;
      const rules = serviceId ? catalogEntry(contract.catalog, serviceId).transport.errors : protocol === 'searxng' ? SEARXNG_SPEC.errors : undefined;
      expect(classifySearchError({ ...rest, rules }), c.caseId).toEqual(c.expect);
    }
  });
});
