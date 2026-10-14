import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { inferModelFamily } from './family-heuristics';
import {
  RELAY_CATALOG_GROUP_LABELS,
  RELAY_CATALOG_GROUP_OTHER,
  relayCatalogGroups,
} from './relay-catalog-grouping';

interface GroupCase {
  id: string;
  models: string[];
  serverFamilies: Record<string, string>;
  expected: { id: string; label: string | null; models: string[] }[];
}

interface GroupFixture {
  labels: Record<string, string>;
  cases: GroupCase[];
}

/** Cross-client shared source of truth: `shared/test-fixtures/relay/catalog-groups.v1.json`. */
const FIXTURE_PATH = resolve(__dirname, '../../../../../shared/test-fixtures/relay/catalog-groups.v1.json');
const fixture = JSON.parse(readFileSync(FIXTURE_PATH, 'utf8')) as GroupFixture;

describe('RD3-GROUP relay model library grouping (fixture catalog-groups.v1.json)', () => {
  it('RD3-GROUP the fixture has at least 5 cases, and the group-name table matches the fixture labels item by item', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(5);
    expect(RELAY_CATALOG_GROUP_LABELS).toEqual(fixture.labels);
    expect(RELAY_CATALOG_GROUP_OTHER).toBe('other');
  });

  for (const item of fixture.cases) {
    it(`RD3-GROUP-${item.id}`, () => {
      // Family = cached Server by-model family (the fixture injects by exact id) -> this client's heuristics.
      const family = (modelID: string) => item.serverFamilies[modelID] ?? inferModelFamily(modelID);
      const rows = item.models.map((id) => ({ id }));
      const groups = relayCatalogGroups(rows, family);
      expect(groups.map((group) => ({
        id: group.id,
        label: group.label,
        models: group.models.map((row) => row.id),
      }))).toEqual(item.expected);
      // Row objects are carried out as is (not copied, order unchanged).
      for (const group of groups) {
        for (const row of group.models) expect(rows).toContain(row);
      }
    });
  }
});
