import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';
import {
  ALL_RELAY_REQUESTED_FIELDS,
  PORTABLE_RELAY_REQUESTED_FIELDS,
  credentialFreeRelayRequested,
  stripRelayURLSecrets,
} from './portable-config';
import type { RelayRequestedConfig } from '../types/relay';

interface PortableContract {
  version: number;
  allFields: string[];
  portableFields: string[];
  localOnlyFields: Array<{ field: string; reason: string }>;
  cases: Array<{
    caseId: string;
    input: Record<string, unknown>;
    expect: Record<string, unknown>;
  }>;
}

function loadContract(): PortableContract {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'portable-config.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as PortableContract;
    }
    dir = path.dirname(dir);
  }
  throw new Error('portable-config.v1.json not found');
}

describe('portable-config.v1 outbound allowlist', () => {
  const contract = loadContract();

  it('registers every RelayRequestedConfig field as portable or local-only', () => {
    expect(contract.version).toBe(1);
    // The in-tree allowlist table is typed as `Record<keyof RelayRequestedConfig, boolean>`: adding
    // a field to the interface without declaring it in the table fails tsc outright, and changing
    // the table without updating the fixture fails here.
    expect([...ALL_RELAY_REQUESTED_FIELDS].sort()).toEqual([...contract.allFields].sort());
    expect([...PORTABLE_RELAY_REQUESTED_FIELDS].sort()).toEqual([...contract.portableFields].sort());
    expect([...contract.localOnlyFields.map((entry) => entry.field)].sort()).toEqual(
      contract.allFields.filter((field) => !contract.portableFields.includes(field)).sort(),
    );
  });

  it('never lets a local-only field reach the outbound copy', () => {
    const everything = Object.fromEntries(
      contract.allFields.map((field) => [field, `value-of-${field}`]),
    ) as unknown as RelayRequestedConfig;
    const portable = credentialFreeRelayRequested(everything) ?? {};
    for (const { field } of contract.localOnlyFields) {
      expect(portable).not.toHaveProperty(field);
    }
  });

  for (const item of contract.cases) {
    it(`${item.caseId} round-trips through the production sanitizer`, () => {
      const portable = credentialFreeRelayRequested(item.input as unknown as RelayRequestedConfig);
      expect(portable).toEqual(item.expect);
    });
  }
});

describe('stripRelayURLSecrets', () => {
  it('strips userInfo, query and fragment while preserving the route', () => {
    expect(stripRelayURLSecrets(
      'https://user:pass@relay.example.com/proxy/v1?api-key=secret#setup',
    )).toBe('https://relay.example.com/proxy/v1');
  });

  it('drops invalid URL values instead of syncing them', () => {
    expect(stripRelayURLSecrets('not a URL')).toBeUndefined();
  });
});
