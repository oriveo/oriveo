/**
 * An empty envelope must never go outbound (single source of truth:
 * `shared/model-contracts/*_sync.v1.json#wireInvariants.emptyEnvelopeNeverOutbound`).
 *
 * Firestore `set(merge)` **replaces** array fields wholesale: pushing a `records: []` /
 * `tombstones: []` clears the account's whole cloud envelope. An all-empty envelope itself carries
 * zero information - a legitimate "everything deleted" always carries tombstones, so this gate
 * loses no user intent.
 *
 * The assertions drive the production publish path (the `publish` triggered by save / delete /
 * remove) rather than an envelope synthesized by this test; whether anything went outbound is
 * observed through the mocked `getSyncAdapter().didUpdatePreferences`.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const partitionMocks = vi.hoisted(() => ({ activeUID: 'uid-a' }));
vi.mock('../../../infra/storage/partition', () => ({
  getActiveUIDSync: () => partitionMocks.activeUID,
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  getCapabilityRuntime: () => ({ revision: 'runtime-r7' }),
  resolveCatalogModel: () => null,
}));

const adapterMocks = vi.hoisted(() => ({ didUpdatePreferences: vi.fn() }));
vi.mock('../../sync-port', () => ({
  getSyncAdapter: () => ({ didUpdatePreferences: adapterMocks.didUpdatePreferences }),
}));

import {
  deleteCapabilityPreferences,
  encodeCapabilityTransportIdentity,
  saveCapabilityPreferences,
} from '../capability-preference-settings';
import {
  removeGenerationParameterScopes,
  saveGenerationParameterOverrides,
} from '../generation-parameter-settings';
import { clearPartitionedStoreForUID } from '../../../infra/storage/partitioned-local-store';

const contract = (name: string) => JSON.parse(readFileSync(
  resolve(process.cwd(), '../../..', `shared/model-contracts/${name}`), 'utf8',
));
const capabilityWire = contract('capability_preference_sync.v1.json').wireInvariants;
const generationWire = contract('generation_parameter_sync.v1.json').wireInvariants;

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

/** publish goes through a microtask plus a dynamic import; both levels have to be let through before the result is visible. */
async function flushPublish(): Promise<void> {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
  await new Promise((done) => setTimeout(done, 0));
}

function outboundPayloads(field: string): unknown[] {
  return adapterMocks.didUpdatePreferences.mock.calls
    .map(([patch]) => (patch as Record<string, unknown>)[field])
    .filter((value) => value !== undefined);
}

beforeEach(() => {
  localStorage.clear();
  adapterMocks.didUpdatePreferences.mockClear();
  partitionMocks.activeUID = 'uid-a';
});

describe('emptyEnvelopeNeverOutbound - contract text', () => {
  it('both envelopes declare this rule and both name the wholesale replacement of set(merge)', () => {
    for (const wire of [capabilityWire, generationWire]) {
      expect(wire.emptyEnvelopeNeverOutbound).toBeTruthy();
      expect(wire.emptyEnvelopeNeverOutbound).toContain('wholesale');
      expect(wire.emptyEnvelopeNeverOutbound).toContain('tombstones');
    }
    // The generation criterion has one more dimension, presets (the envelope has that extra section).
    expect(generationWire.emptyEnvelopeNeverOutbound).toContain('presets');
  });
});

describe('capability_preference_sync - an empty envelope does not go outbound', () => {
  it('the device is cleared by an account boundary reset after publish was queued -> silently skipped, no empty array pushed over the cloud', async () => {
    // publish is deferred by a microtask: the write is queued, and the partition is cleared before
    // the flush. The uid has not changed at this point, so the outbound uid assertion cannot stop
    // it; only this empty-envelope gate can.
    saveCapabilityPreferences(scope, { web: 'automatic' });
    clearPartitionedStoreForUID('uid-a');
    await flushPublish();

    expect(outboundPayloads('capabilityPreferenceSettings')).toEqual([]);
  });

  it('an envelope with only tombstones goes outbound as usual ("everything deleted" is a real intent and must not be hit by mistake)', async () => {
    deleteCapabilityPreferences(scope);
    await flushPublish();

    const [payload] = outboundPayloads('capabilityPreferenceSettings') as {
      records: unknown[]; tombstones: unknown[];
    }[];
    expect(payload).toBeDefined();
    expect(payload!.records).toEqual([]);
    expect(payload!.tombstones).toHaveLength(1);
  });

  it('goes outbound as usual when there are records', async () => {
    saveCapabilityPreferences(scope, { web: 'force' });
    await flushPublish();

    const [payload] = outboundPayloads('capabilityPreferenceSettings') as { records: unknown[] }[];
    expect(payload!.records).toHaveLength(1);
  });
});

describe('generation_parameter_sync - an empty envelope does not go outbound', () => {
  it('deleting a connection that has no records on this device -> silently skipped (deleting an official provider after an account switch has exactly this shape)', async () => {
    // `removeGenerationParameterScopes` still runs writeSettings + publish when nothing matched,
    // which is the all-empty outbound path this module can really reach.
    removeGenerationParameterScopes({ providerId: CONNECTION });
    await flushPublish();

    expect(outboundPayloads('generationParameterSettings')).toEqual([]);
  });

  it('an envelope with only tombstones goes outbound as usual', async () => {
    // Saving a scope that never had a value as "all inherit" is a delete intent and lands as one tombstone.
    saveGenerationParameterOverrides(parameterScope, {});
    await flushPublish();

    const [payload] = outboundPayloads('generationParameterSettings') as {
      records: unknown[]; presets: unknown[]; tombstones: unknown[];
    }[];
    expect(payload).toBeDefined();
    expect(payload!.records).toEqual([]);
    expect(payload!.presets).toEqual([]);
    expect(payload!.tombstones).toHaveLength(1);
  });

  it('goes outbound as usual when there are records', async () => {
    saveGenerationParameterOverrides(parameterScope, { temperature: { state: 'value', value: 0.4 } });
    await flushPublish();

    const [payload] = outboundPayloads('generationParameterSettings') as { records: unknown[] }[];
    expect(payload!.records).toHaveLength(1);
  });
});
