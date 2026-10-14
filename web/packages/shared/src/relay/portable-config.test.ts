import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';

import { describe, expect, it } from 'vitest';
import {
  ALL_RELAY_MODEL_FIELDS,
  ALL_RELAY_REQUESTED_FIELDS,
  ENGINE_DECLARATION_KEYS,
  LOCAL_ONLY_RELAY_MODEL_FIELDS,
  PORTABLE_RELAY_MODEL_FIELDS,
  PORTABLE_RELAY_REQUESTED_FIELDS,
  RELAY_CAPABILITY_OVERRIDE_KEYS,
  RELAY_MODEL_TRANSPORT_SOURCES,
  credentialFreeRelayRequested,
  sanitizeRelayModelFields,
  stripRelayURLSecrets,
} from './portable-config';
import type { AIModel } from '../types/models';
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
  modelFields: {
    all: string[];
    portable: string[];
    localOnly: string[];
    transportSources: string[];
    capabilityOverrideKeys: string[];
    engineDeclarationKeys: string[];
  };
  modelCases: Array<{
    caseId: string;
    model: Record<string, unknown>;
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

describe('RL2-DATA-01 Relay 2.0 model-level field registry and read-time sanitization', () => {
  const contract = loadContract();

  /** An ordinary model in this client's production shape; the JSON round trip simulates reading back from local storage / a backup file. */
  function baselineModel(): AIModel {
    return JSON.parse(JSON.stringify({
      id: 'relay-model',
      name: 'Relay Model',
      capabilities: ['text'],
      reasoningModeAvailable: false,
      isAvailable: true,
      isDefault: false,
      priceTier: '',
      isManual: true,
    } satisfies AIModel)) as AIModel;
  }

  it('RL2-DATA-01 the field registry of this client equals modelFields / allFields', () => {
    expect([...ALL_RELAY_MODEL_FIELDS].sort()).toEqual([...contract.modelFields.all].sort());
    expect([...PORTABLE_RELAY_MODEL_FIELDS].sort()).toEqual([...contract.modelFields.portable].sort());
    expect([...LOCAL_ONLY_RELAY_MODEL_FIELDS].sort()).toEqual([...contract.modelFields.localOnly].sort());
    expect([...RELAY_MODEL_TRANSPORT_SOURCES].sort()).toEqual(
      [...contract.modelFields.transportSources].sort(),
    );
    expect([...RELAY_CAPABILITY_OVERRIDE_KEYS].sort()).toEqual(
      [...contract.modelFields.capabilityOverrideKeys].sort(),
    );
    expect([...ENGINE_DECLARATION_KEYS].sort()).toEqual(
      [...contract.modelFields.engineDeclarationKeys].sort(),
    );
    expect([...ALL_RELAY_REQUESTED_FIELDS].sort()).toEqual([...contract.allFields].sort());
    expect(ALL_RELAY_REQUESTED_FIELDS).toContain('resolvedAPIBaseURLs');
    expect(PORTABLE_RELAY_REQUESTED_FIELDS).toContain('resolvedAPIBaseURLs');
  });

  for (const item of contract.modelCases) {
    it(`RL2-DATA-01 ${item.caseId} goes through the production sanitizer`, () => {
      const stored = JSON.parse(JSON.stringify({ ...baselineModel(), ...item.model })) as AIModel;
      const cleaned = sanitizeRelayModelFields(stored) as unknown as Record<string, unknown>;
      const relayKeys = Object.fromEntries(
        contract.modelFields.all.filter((field) => field in cleaned).map((field) => [field, cleaned[field]]),
      );
      // Missing key = undefined: the remaining Relay 2.0 keys after sanitizing must be exactly those in expect.
      expect(relayKeys).toEqual(item.expect);
      // Sanitizing touches only these three keys; the other model fields stay as is.
      for (const [key, value] of Object.entries(baselineModel())) {
        expect(cleaned[key]).toEqual(value);
      }
      // Reading again changes nothing (idempotent) and does not modify the input.
      expect(sanitizeRelayModelFields(cleaned as unknown as AIModel)).toEqual(cleaned);
      expect(stored).toEqual({ ...baselineModel(), ...item.model });
    });
  }

  it('RL2-DATA-01 fields of a non-object shape do not throw; the whole key is dropped', () => {
    const cleaned = sanitizeRelayModelFields({
      ...baselineModel(),
      relayTransport: 42,
      relayTransportSource: null,
      relayCapabilityOverrides: ['image'],
      engineDeclaration: [true],
    } as unknown as AIModel) as unknown as Record<string, unknown>;
    for (const field of contract.modelFields.all) expect(cleaned).not.toHaveProperty(field);
  });

  it('RK-2 multi-key three fields: well-formed values are kept as is; a wrong shape drops the whole key without throwing', () => {
    const kept = sanitizeRelayModelFields({
      ...baselineModel(),
      relayKeyID: 'k-b',
      relayListedByKeyIDs: ['initial', 'k-b'],
      relayDeniedKeyID: 'initial',
    } as AIModel) as unknown as Record<string, unknown>;
    expect(kept).toMatchObject({ relayKeyID: 'k-b', relayListedByKeyIDs: ['initial', 'k-b'], relayDeniedKeyID: 'initial' });

    const dropped = sanitizeRelayModelFields({
      ...baselineModel(),
      relayKeyID: 7,
      relayListedByKeyIDs: ['initial', 3],
      relayDeniedKeyID: '',
    } as unknown as AIModel) as unknown as Record<string, unknown>;
    expect(dropped).not.toHaveProperty('relayKeyID');
    expect(dropped).not.toHaveProperty('relayListedByKeyIDs');
    expect(dropped).not.toHaveProperty('relayDeniedKeyID');
    expect(dropped.id).toBe('relay-model');
  });
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
