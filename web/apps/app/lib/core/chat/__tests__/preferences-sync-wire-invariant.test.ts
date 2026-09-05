/**
 * Cross-client wire invariants, defined by `shared/model-contracts/*_sync.v1.json#wireInvariants`.
 *
 * The envelope each client encodes from the same content must match field for field: the same sort
 * order, the same capacity and truncation direction, the same top-level keys, and the same "null
 * means omitted". If any of these differ, the side that reads the other's envelope decides the
 * other one is behind and rewrites it, and the other side rewrites it back - an endless ping-pong
 * over identical content that differs only in order or key set (observed with 18 tombstones whose
 * contents matched exactly and differed only in array order).
 *
 * Assertions always run against the actual output of the production functions (export / merge),
 * never against an envelope synthesized by this test.
 */
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

const metadataMocks = vi.hoisted(() => ({
  getCapabilityRuntime: vi.fn(() => ({ revision: 'runtime-r7' })),
  resolveCatalogModel: vi.fn(() => null),
}));
vi.mock('../../metadata/metadata-client', () => metadataMocks);

import {
  exportCapabilityPreferenceSyncPayload, mergeCapabilityPreferenceSyncPayload,
} from '../capability-preference-settings';
import {
  exportGenerationParameterSyncPayload, mergeGenerationParameterSyncPayload,
} from '../generation-parameter-settings';

/**
 * Key-order-independent comparison, matching how a JSON envelope behaves once it has made a round
 * trip: map key order carries no information, a key whose value is `undefined` is the same as an
 * absent key, arrays are compared in order, and everything else is compared by strict equality.
 */
function envelopeEquals(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((item, index) => envelopeEquals(item, b[index]));
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const left = a as Record<string, unknown>;
    const right = b as Record<string, unknown>;
    const leftKeys = Object.keys(left).filter((key) => left[key] !== undefined);
    const rightKeys = Object.keys(right).filter((key) => right[key] !== undefined);
    if (leftKeys.length !== rightKeys.length) return false;
    return leftKeys.every(
      (key) => right[key] !== undefined && envelopeEquals(left[key], right[key]),
    );
  }
  return false;
}

const memory = new Map<string, string>();
vi.stubGlobal('window', {});
vi.stubGlobal('localStorage', {
  getItem: (k: string) => memory.get(k) ?? null,
  setItem: (k: string, v: string) => memory.set(k, v),
  removeItem: (k: string) => memory.delete(k),
  clear: () => memory.clear(),
});

const contract = (name: string) => JSON.parse(readFileSync(
  resolve(process.cwd(), '../../..', `shared/model-contracts/${name}`), 'utf8',
));
const capability = contract('capability_preference_sync.v1.json').wireInvariants;
const generation = contract('generation_parameter_sync.v1.json').wireInvariants;

const TRANSPORT = 'r1.b3BlbmFpX2NoYXQ.cnVudGltZS1yNw';
const PROVIDER = '9a1195de-3af9-5888-abc8-b8177c458c07';
const tombstone = (recordId: string, index: number) => ({
  recordId, revision: 2, mutationId: `00000000-0000-4000-8000-${String(index).padStart(12, '0')}`,
});

describe('capability_preference_sync.v1#wireInvariants', () => {
  beforeEach(() => memory.clear());

  it('keeps top-level keys constant, so even an empty envelope carries schemaVersion and empty arrays', () => {
    const exported = exportCapabilityPreferenceSyncPayload();
    expect(Object.keys(exported).sort()).toEqual([...capability.alwaysPresentTopLevelKeys.keys].sort());
    const merged = mergeCapabilityPreferenceSyncPayload({ schemaVersion: 2, records: [], tombstones: [] });
    expect(Object.keys(merged).sort()).toEqual([...capability.alwaysPresentTopLevelKeys.keys].sort());
  });

  it('orders across the ~/z boundary by code point as the contract requires, and an already converged envelope needs no rewrite', () => {
    const { unordered, codePointOrder } = capability.orderingBoundaryCase as {
      unordered: string[]; codePointOrder: string[];
    };
    const remote = {
      schemaVersion: 2,
      records: [],
      tombstones: codePointOrder.map((id, index) => tombstone(id, index)),
    };
    const merged = mergeCapabilityPreferenceSyncPayload(remote);
    expect(merged.tombstones?.map((item) => item.recordId)).toEqual(codePointOrder);
    expect(envelopeEquals(remote, merged)).toBe(true);
    // An out-of-order envelope converges to the contract order; that single rewrite is legitimate
    // self-healing rather than the start of a ping-pong.
    memory.clear();
    const shuffled = { schemaVersion: 2, records: [], tombstones: unordered.map((id, i) => tombstone(id, i)) };
    const convergent = mergeCapabilityPreferenceSyncPayload(shuffled);
    expect(convergent.tombstones?.map((item) => item.recordId)).toEqual(codePointOrder);
  });

  it('normalizes away optional fields the remote wrote as explicit null instead of propagating them', () => {
    const remote = {
      schemaVersion: 2,
      tombstones: [],
      records: [{
        recordId: `scope:model:${PROVIDER}:gpt-test:${TRANSPORT}`,
        scope: 'connection_model',
        providerId: PROVIDER,
        canonicalModelId: 'gpt-test',
        conversationId: null,
        skillId: null,
        transportIdentity: TRANSPORT,
        web: 'off',
        reasoningIntent: null,
        revision: 2,
        mutationId: '00000000-0000-4000-8000-000000000102',
      }],
    };
    const merged = mergeCapabilityPreferenceSyncPayload(remote);
    expect(merged.records).toHaveLength(1);
    for (const field of capability.omitWhenNull.recordFields as string[]) {
      expect(Object.keys(merged.records[0]!)).not.toContain(field);
    }
  });

  it('does not discard an existing Android envelope that lacks schemaVersion', () => {
    // The kotlinx encoder in Android 1.2.6 and earlier omits schemaVersion when it equals the default.
    const remote = { records: [], tombstones: [tombstone(`scope:model:${PROVIDER}:legacy-model:${TRANSPORT}`, 7)] };
    const merged = mergeCapabilityPreferenceSyncPayload(remote);
    expect(merged.tombstones?.map((item) => item.recordId)).toEqual([`scope:model:${PROVIDER}:legacy-model:${TRANSPORT}`]);
  });

  // The outbound gate itself lives in `publish` and its behavior is driven by
  // `preferences-sync-empty-envelope.test.ts`; what is locked here is the shape of its condition:
  // an empty local export must be exactly a zero-information envelope, and one with tombstones
  // must not.
  it('puts an empty local export exactly on the emptyEnvelopeNeverOutbound condition, while one with tombstones falls outside it', () => {
    expect(capability.emptyEnvelopeNeverOutbound).toContain(' ');
    const empty = exportCapabilityPreferenceSyncPayload();
    expect(empty.records).toEqual([]);
    expect(empty.tombstones).toEqual([]);

    const withTombstone = mergeCapabilityPreferenceSyncPayload({
      schemaVersion: 2, records: [], tombstones: [tombstone(`scope:model:${PROVIDER}:m0:${TRANSPORT}`, 1)],
    });
    expect(withTombstone.tombstones).toHaveLength(1);
  });

  it('truncates tombstones from the tail after sorting, at the contract capacity', () => {
    const limit = capability.capacity.tombstones.limit as number;
    expect(capability.capacity.tombstones.keep).toBe('tail');
    const ids = Array.from({ length: limit + 50 }, (_, i) => `scope:model:${PROVIDER}:m${String(i).padStart(4, '0')}:${TRANSPORT}`);
    const merged = mergeCapabilityPreferenceSyncPayload({
      schemaVersion: 2, records: [], tombstones: ids.map((id, i) => tombstone(id, i)),
    });
    expect(merged.tombstones).toHaveLength(limit);
    expect(merged.tombstones?.map((item) => item.recordId)).toEqual([...ids].sort().slice(-limit));
  });
});

describe('generation_parameter_sync.v1#wireInvariants', () => {
  beforeEach(() => memory.clear());

  it('keeps top-level keys constant, with export and merge sharing one shape', () => {
    const keys = [...generation.alwaysPresentTopLevelKeys.keys].sort();
    expect(Object.keys(exportGenerationParameterSyncPayload()).sort()).toEqual(keys);
    expect(Object.keys(mergeGenerationParameterSyncPayload(undefined)).sort()).toEqual(keys);
  });

  it('orders across the ~/z boundary by code point, with export and merge agreeing', () => {
    const { codePointOrder } = capability.orderingBoundaryCase as { codePointOrder: string[] };
    const remote = {
      schemaVersion: 1, records: [], presets: [],
      tombstones: codePointOrder.map((id, index) => tombstone(id, index)),
    };
    const merged = mergeGenerationParameterSyncPayload(remote);
    expect(merged.tombstones.map((item) => item.recordId)).toEqual(codePointOrder);
    expect(envelopeEquals(remote, merged)).toBe(true);
    expect(exportGenerationParameterSyncPayload().tombstones.map((item) => item.recordId)).toEqual(codePointOrder);
  });

  it('puts an empty local export exactly on the emptyEnvelopeNeverOutbound condition, with the extra presets dimension for generation', () => {
    expect(generation.emptyEnvelopeNeverOutbound).toContain('presets');
    const empty = exportGenerationParameterSyncPayload();
    expect(empty.records).toEqual([]);
    expect(empty.presets).toEqual([]);
    expect(empty.tombstones).toEqual([]);
  });

  it('normalizes away optional fields the remote wrote as explicit null instead of propagating them', () => {
    const remote = {
      schemaVersion: 1, presets: [], tombstones: [],
      records: [{
        recordId: `scope:model:${PROVIDER}:gpt-test`,
        scope: 'model_default',
        providerId: PROVIDER,
        modelId: 'gpt-test',
        conversationId: null,
        profileKey: 'openai_chat_completions||gpt-test',
        values: { temperature: { state: 'value', value: 0.4 } },
        revision: 2,
        mutationId: '00000000-0000-4000-8000-000000000102',
      }],
    };
    const merged = mergeGenerationParameterSyncPayload(remote);
    expect(merged.records).toHaveLength(1);
    expect(Object.keys(merged.records[0]!)).not.toContain('conversationId');
  });
});
