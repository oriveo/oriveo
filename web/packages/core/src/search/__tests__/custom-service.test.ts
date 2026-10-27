import { describe, expect, it } from 'vitest';
import type { CatalogEntry } from '../search-catalog';
import {
  addressChangeClearsKey,
  buildSearchRequest,
  catalogOutageBehavior,
  CUSTOM_PROTOCOLS,
  CUSTOM_TIMEOUT_SEC,
  keyBindingOrigin,
  normalizeSearchKey,
  parseSearchResponse,
  parseServiceAddress,
  SEARXNG_SPEC,
  searxngPath,
  snapshotPresetMapping,
  validateCustomSearchService,
  WEB_ALLOWED_PORTS,
  type TransportSpec,
} from '../search-transport';
import { catalogEntry, loadContract, normalizeRequest } from './fixtures';

const custom = loadContract('shared/search-contracts/custom-service.v1.json');
const contract = loadContract('shared/search-contracts/search_catalog_contract.v1.json');
const catalog: { services: CatalogEntry[] } = contract.catalog;

describe('custom search service (custom-service.v1)', () => {
  it('constants match the fixture: protocol, built-in SearXNG mapping, timeout', () => {
    expect(custom.constants).toEqual({
      protocols: CUSTOM_PROTOCOLS,
      searxng: SEARXNG_SPEC,
      timeoutSec: CUSTOM_TIMEOUT_SEC,
      webAllowedPorts: WEB_ALLOWED_PORTS,
    });
  });

  it('SRCH-CUS-01 validateCases: form validation', () => {
    expect(custom.validateCases.length).toBeGreaterThan(0);
    for (const c of custom.validateCases) {
      expect(validateCustomSearchService(c.input), c.caseId).toEqual(c.expect);
    }
  });

  it('SRCH-CUS-02 bindingCases: key is bound to its source; key is cleared only when the source changes', () => {
    expect(custom.bindingCases.length).toBeGreaterThan(0);
    for (const c of custom.bindingCases) {
      const actual = {
        oldOrigin: keyBindingOrigin(c.input.old),
        nextOrigin: keyBindingOrigin(c.input.next),
        clearsKey: addressChangeClearsKey(c.input.old, c.input.next),
      };
      expect(actual, c.caseId).toEqual(c.expect);
    }
  });

  it('SRCH-CUS-03 snapshotCases: "same as X" snapshots that provider mapping (including per-site static params)', () => {
    expect(custom.snapshotCases.length).toBeGreaterThan(0);
    for (const c of custom.snapshotCases) {
      expect(snapshotPresetMapping(catalogEntry(catalog, c.input.serviceId), c.input.regionId), c.caseId).toEqual(c.expect);
    }
  });

  it('SRCH-CUS-04 requestCases: request construction for SearXNG / manual / same-as-X', () => {
    expect(custom.requestCases.length).toBeGreaterThan(0);
    for (const c of custom.requestCases) {
      const addr = parseServiceAddress(c.input.address);
      if (!addr) throw new Error(`${c.caseId}: fixture address invalid`);
      let spec: TransportSpec;
      let path: string;
      if (c.input.protocol === 'searxng') {
        spec = SEARXNG_SPEC;
        path = searxngPath(addr.path);
      } else if (c.input.protocol === 'manual') {
        spec = c.input.manual;
        path = addr.path || '/';
      } else if (c.input.protocol === 'same_as') {
        spec = snapshotPresetMapping(catalogEntry(catalog, c.input.presetId), c.input.regionId);
        path = addr.path || '/';
      } else {
        throw new Error(`${c.caseId}: unknown protocol ${c.input.protocol}`);
      }
      const req = buildSearchRequest(spec, { scheme: addr.scheme, host: addr.host, port: addr.port, path }, c.input);
      if ('skip' in req || c.expect.skip) expect(req, c.caseId).toEqual(c.expect);
      else expect(normalizeRequest(req), c.caseId).toEqual(normalizeRequest(c.expect));
    }
  });

  it('SRCH-CUS-05 responseCases: SearXNG sample replay and manual nested paths', () => {
    expect(custom.responseCases.length).toBeGreaterThan(0);
    for (const c of custom.responseCases) {
      const spec: TransportSpec = c.input.protocol === 'searxng' ? SEARXNG_SPEC : c.input.manual;
      expect(parseSearchResponse(spec, c.input.body, { count: c.input.count }), c.caseId).toEqual(c.expect);
    }
  });

  it('SRCH-CUS-07 keyCases: key is trimmed and only 1-1024 printable ASCII characters are accepted', () => {
    expect(custom.keyCases.length).toBeGreaterThan(0);
    for (const c of custom.keyCases) {
      expect(normalizeSearchKey(c.input.raw), c.caseId).toEqual(c.expect);
    }
  });

  it('SRCH-CUS-06 catalogUnavailableCases: which service kinds stay or go when the catalog is unavailable', () => {
    expect(custom.catalogUnavailableCases.length).toBeGreaterThan(0);
    for (const c of custom.catalogUnavailableCases) {
      expect(catalogOutageBehavior(c.input), c.caseId).toEqual(c.expect);
    }
  });
});
