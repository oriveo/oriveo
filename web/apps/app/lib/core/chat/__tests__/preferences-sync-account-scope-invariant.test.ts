/**
 * Cross-client account boundary invariants (single source of truth:
 * `shared/model-contracts/*_sync.v1.json#accountScopeInvariants`).
 *
 * The local storage for these envelopes has to be bound to one account context, otherwise an
 * everyday action such as deleting an official provider tombstones the previous account's records in
 * bulk and pushes them onto the new account's cloud document. The shape observed in production was
 * 18 tombstones in the new account's `preferences/main` referencing **conversation ids from the old
 * account**, plus a revision 3 draft record from the old account recast as a revision 4 tombstone.
 *
 * Every assertion targets the **actual output of the production functions** (export, save, delete,
 * partitioned read and write) rather than an envelope synthesized by this test, and the contract
 * fields are read from the JSON, so changing the contract turns this red on the spot.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const partitionMocks = vi.hoisted(() => ({ activeUID: 'guest' }));
vi.mock('../../../infra/storage/partition', () => ({
  getActiveUIDSync: () => partitionMocks.activeUID,
}));
vi.mock('../../metadata/metadata-client', () => ({
  getCapabilityRuntime: () => ({ revision: 'runtime-r7' }),
  resolveCatalogModel: () => null,
}));

import {
  encodeCapabilityTransportIdentity,
  exportCapabilityPreferenceSyncPayload,
  saveCapabilityPreferences,
} from '../capability-preference-settings';
import {
  exportGenerationParameterSyncPayload,
  saveGenerationParameterOverrides,
} from '../generation-parameter-settings';
import {
  clearPartitionedStoreForUID,
  readPartitionedStore,
} from '../../../infra/storage/partitioned-local-store';

const contract = (name: string) => JSON.parse(readFileSync(
  resolve(process.cwd(), '../../..', `shared/model-contracts/${name}`), 'utf8',
));
const capabilityInvariants = contract('capability_preference_sync.v1.json').accountScopeInvariants;
const generationInvariants = contract('generation_parameter_sync.v1.json').accountScopeInvariants;

const transportIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r7');
const CONNECTION = 'a0000000-0000-0000-0000-000000000001';
const scope = {
  scope: 'connection_model' as const,
  providerId: CONNECTION,
  canonicalModelId: 'model-a',
  finalTransport: 'openai_responses',
  runtimeRevision: 'runtime-r7',
  transportIdentity,
};
const parameterScope = { providerId: CONNECTION, modelId: 'model-a' };

const UID_A = 'uid-a';
const UID_B = 'uid-b';

beforeEach(() => {
  localStorage.clear();
  partitionMocks.activeUID = 'guest';
});

describe('accountScopeInvariants - both envelopes declare the same account boundary', () => {
  it('the two contracts are synonymous clause by clause, since all clients read the same semantics', () => {
    expect(generationInvariants.legacyBareKeyClaim).toBe(capabilityInvariants.legacyBareKeyClaim);
    expect(generationInvariants.guestPromotion).toBe(capabilityInvariants.guestPromotion);
    expect(generationInvariants.boundaryReset.signOut).toBeTruthy();
  });
});

describe('legacyBareKeyClaim - a bare key belongs to the first account only when this machine has never had a real one', () => {
  it('the contract text itself says a machine that has already seen a real account deletes rather than inherits on sign-in', () => {
    expect(capabilityInvariants.legacyBareKeyClaim).toContain(' ');
    expect(capabilityInvariants.legacyBareKeyClaim).toContain(' ');
  });

  it('the first real account inherits and consumes the bare key', () => {
    localStorage.setItem('oriveo.capability-preference-settings.v2', '{"records":[" "]}');
    partitionMocks.activeUID = UID_A;

    expect(readPartitionedStore('capability-preference-settings.v2')).toBe('{"records":[" "]}');
    expect(localStorage.getItem('oriveo.capability-preference-settings.v2')).toBeNull();
  });

  it('once the machine watermark is set to A, neither B nor guest inherits and the bare key is deleted outright', () => {
    // A lands on this machine first, setting the account watermark.
    partitionMocks.activeUID = UID_A;
    readPartitionedStore('capability-preference-settings.v2');

    // The legacy bare key in the other table is only read now; it belongs to A and must not be handed to a later account.
    localStorage.setItem('oriveo.generation-parameter-settings.v1', '{"scopes":["A  "]}');
    partitionMocks.activeUID = UID_B;
    expect(readPartitionedStore('generation-parameter-settings.v1')).toBeNull();
    expect(localStorage.getItem('oriveo.generation-parameter-settings.v1')).toBeNull();

    localStorage.setItem('oriveo.generation-parameter-settings.v1', '{"scopes":["A  "]}');
    partitionMocks.activeUID = 'guest';
    expect(readPartitionedStore('generation-parameter-settings.v1')).toBeNull();
    expect(localStorage.getItem('oriveo.generation-parameter-settings.v1')).toBeNull();
  });
});

describe('guestPromotion - state written while in guest does not follow the sign-in into a real account', () => {
  it('the contract declares it not_migrated', () => {
    expect(capabilityInvariants.guestPromotion).toContain('not_migrated');
  });

  it('typed preferences and generation parameters written as guest do not appear in the real account export envelope', () => {
    partitionMocks.activeUID = 'guest';
    saveCapabilityPreferences(scope, { web: 'force' });
    saveGenerationParameterOverrides(parameterScope, { temperature: { state: 'value', value: 0.7 } });
    expect(exportCapabilityPreferenceSyncPayload().records).toHaveLength(1);

    partitionMocks.activeUID = UID_A;
    expect(exportCapabilityPreferenceSyncPayload().records).toEqual([]);
    expect(exportGenerationParameterSyncPayload().records).toEqual([]);
  });
});

describe('boundaryReset.signOut - clears all sync-visible state and the account stamp', () => {
  it('the contract requires clearing records, the tombstones ledger and presets/drafts together', () => {
    expect(capabilityInvariants.boundaryReset.signOut).toContain('records');
    expect(capabilityInvariants.boundaryReset.signOut).toContain('tombstones');
    expect(capabilityInvariants.revisionBaselineNotInherited).toContain('revision ledger');
  });

  it('after the reset both envelopes are empty and the revision baseline is not inherited by the next account', () => {
    partitionMocks.activeUID = UID_A;
    // Raise the revision to 3: writing the same record repeatedly is exactly what tuning parameters looks like in production.
    for (const value of [0.1, 0.2, 0.3]) {
      saveGenerationParameterOverrides(parameterScope, { temperature: { state: 'value', value } });
    }
    saveCapabilityPreferences(scope, { web: 'automatic' });
    expect(exportGenerationParameterSyncPayload().records[0]!.revision).toBe(3);

    clearPartitionedStoreForUID(UID_A);

    expect(exportCapabilityPreferenceSyncPayload()).toEqual({
      schemaVersion: 2, records: [], tombstones: [],
    });
    expect(exportGenerationParameterSyncPayload()).toEqual({
      schemaVersion: 1, records: [], presets: [], tombstones: [],
    });

    // The ledger is clean too: the first write after a reset starts at revision 1 rather than continuing from 4.
    saveGenerationParameterOverrides(parameterScope, { temperature: { state: 'value', value: 0.9 } });
    expect(exportGenerationParameterSyncPayload().records[0]!.revision).toBe(1);
  });
});
