/**
 * Per-UID partitioning of the three local model-control tables.
 *
 * Attack surface: these tables key user preferences by connection x model x transport, and a
 * connection belongs to an account. With no UID dimension, A logs out, B logs in, and A records
 * sit untouched under the same origin - `exportCapabilityPreferenceSyncPayload` then pushes the
 * whole table into B cloud storage along with B sync. That is cross-account data leakage, not a
 * display glitch.
 *
 * Three things are locked here: (1) writes land on a per-UID key; (2) after a UID change the
 * previous account data is unreadable; (3) a pre-existing bare key migrates once to the current
 * UID, with the same semantics as `preferences.ts`.
 */
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
  capabilityRuntimeIdentity,
  displayCapabilityPreferences,
  encodeCapabilityTransportIdentity,
  exportCapabilityPreferenceSyncPayload,
  saveCapabilityPreferences,
} from '../capability-preference-settings';
import {
  deleteAllCapabilityPreferencesForConnection,
} from '../capability-preference-settings';
import {
  exportGenerationParameterSyncPayload,
  loadGenerationParameterOverrides,
  removeGenerationParameterScopes,
  saveGenerationParameterOverrides,
} from '../generation-parameter-settings';
import { loadCustomFragmentSettings, saveCustomFragmentSettings } from '../custom-fragment-settings';

const memory = new Map<string, string>();
// Change broadcasts run in a microtask, so the `window` stub needs `dispatchEvent`: without it the
// exception lands inside the microtask as an unhandled exception instead of failing this line.
vi.stubGlobal('window', { dispatchEvent: () => true });
vi.stubGlobal('localStorage', {
  getItem: (key: string) => memory.get(key) ?? null,
  setItem: (key: string, value: string) => { memory.set(key, value); },
  removeItem: (key: string) => { memory.delete(key); },
});

const transportIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r7');
const scope = {
  scope: 'connection_model' as const,
  providerId: 'a0000000-0000-0000-0000-000000000001',
  canonicalModelId: 'model-a',
  finalTransport: 'openai_responses',
  runtimeRevision: 'runtime-r7',
  transportIdentity,
};
const fragmentScope = {
  providerId: 'a0000000-0000-0000-0000-000000000001',
  modelId: 'model-a',
  transportIdentity,
  owner: 'generation' as const,
};
const parameterScope = { providerId: 'provider-a', modelId: 'model-a' };

describe('per-UID partitioning of the local model-control tables', () => {
  beforeEach(() => {
    memory.clear();
    partitionMocks.activeUID = 'guest';
  });

  it('typed preferences are written to a per-UID key, so another account cannot read them', () => {
    partitionMocks.activeUID = 'uid-a';
    saveCapabilityPreferences(scope, { web: 'automatic', reasoningIntent: 'deep' });
    expect([...memory.keys()]).toContain('oriveo.uid-a.capability-preference-settings.v2');
    expect(memory.has('oriveo.capability-preference-settings.v2')).toBe(false);

    partitionMocks.activeUID = 'uid-b';
    // Isolation has to cover reads and exports alike: the export is the step that puts data into someone else cloud storage.
    expect(displayCapabilityPreferences(scope)).toEqual({ web: 'off' });
    expect(exportCapabilityPreferenceSyncPayload().records).toEqual([]);

    partitionMocks.activeUID = 'uid-a';
    expect(displayCapabilityPreferences(scope).web).toBe('automatic');
  });

  it('a pre-existing bare key migrates once to the current UID: a real account consumes it, guest only copies it so the first account to log in still inherits it', () => {
    partitionMocks.activeUID = 'guest';
    saveCapabilityPreferences(scope, { web: 'force' });
    const seeded = memory.get('oriveo.guest.capability-preference-settings.v2')!;
    memory.clear();
    memory.set('oriveo.capability-preference-settings.v2', seeded);

    // Guest reads first (auth boot briefly hydrates the guest partition): it copies but keeps the bare key.
    expect(displayCapabilityPreferences(scope).web).toBe('force');
    expect(memory.has('oriveo.capability-preference-settings.v2')).toBe(true);

    // The first real account inherits the same data and consumes the bare key; later accounts do not inherit it.
    partitionMocks.activeUID = 'uid-a';
    expect(displayCapabilityPreferences(scope).web).toBe('force');
    expect(memory.has('oriveo.capability-preference-settings.v2')).toBe(false);

    partitionMocks.activeUID = 'uid-b';
    expect(displayCapabilityPreferences(scope).web).toBe('off');
  });

  it('custom request fields are partitioned too: they can carry business data, and cross-account visibility is a leak', () => {
    partitionMocks.activeUID = 'uid-a';
    saveCustomFragmentSettings(fragmentScope, { configurationMode: 'custom', raw: '{"top_p":0.5}' });
    expect([...memory.keys()]).toContain('oriveo.uid-a.local-custom-fragments.v2');

    partitionMocks.activeUID = 'uid-b';
    expect(loadCustomFragmentSettings(fragmentScope)).toEqual({ configurationMode: 'auto', raw: '' });
  });

  // Partitioning turns "a pre-existing bare key is inherited by whichever account arrives next"
  // into a new failure surface for one-shot migrations: the developer master-switch migration runs
  // at module load as guest, and guest keeps the bare key by design.
  it('the developer master-switch migration also lands on the bare key, so what an account inherits on login is not a batch of custom fields that would suddenly go out on the wire', async () => {
    memory.set('oriveo.local-custom-fragments.v2', JSON.stringify({
      'p\u0000m\u0000t\u0000generation': { configurationMode: 'custom', raw: '{"top_p":0.5}' },
    }));
    // The master switch was off: without it those custom fields would suddenly start going out on the wire, so they have to be disabled first.
    memory.set('oriveo.local-custom-fragment-developer-mode.v1', 'false');

    const { migrateRetiredCustomFragmentDeveloperGate } = await import('../custom-fragment-settings');
    partitionMocks.activeUID = 'guest';
    migrateRetiredCustomFragmentDeveloperGate();

    const legacy = JSON.parse(memory.get('oriveo.local-custom-fragments.v2')!) as Record<string, { configurationMode: string; raw: string }>;
    expect(legacy['p\u0000m\u0000t\u0000generation']).toEqual({ configurationMode: 'auto', raw: '{"top_p":0.5}' });

    // The first real account inherits the disabled copy, with the draft left as it is so the user can still see what they wrote in the editor.
    partitionMocks.activeUID = 'uid-a';
    expect(loadCustomFragmentSettings({ providerId: 'p', modelId: 'm', transportIdentity: 't', owner: 'generation' }))
      .toEqual({ configurationMode: 'auto', raw: '{"top_p":0.5}' });
  });

  it('generation parameters belong to the model-control domain and are partitioned the same way, since that table also goes into the sync envelope', () => {
    partitionMocks.activeUID = 'uid-a';
    saveGenerationParameterOverrides(parameterScope, { temperature: { state: 'value', value: 0.4 } });
    expect([...memory.keys()]).toContain('oriveo.uid-a.generation-parameter-settings.v1');

    partitionMocks.activeUID = 'uid-b';
    expect(loadGenerationParameterOverrides(parameterScope)).toBeUndefined();
  });

  it('partitioning only changes the local key prefix: the sync envelope schemaVersion and record shape do not change by a byte', () => {
    partitionMocks.activeUID = 'uid-a';
    saveCapabilityPreferences(scope, { web: 'automatic' });
    const payload = exportCapabilityPreferenceSyncPayload();
    expect(payload.schemaVersion).toBe(2);
    expect(Object.keys(payload.records[0]!).sort()).toEqual(
      ['canonicalModelId', 'mutationId', 'providerId', 'recordId', 'revision', 'scope', 'transportIdentity', 'web'],
    );
    // The recordId carries no UID dimension - it is a cross-client primary key, and partitioning must not leak into it.
    expect(payload.records[0]!.recordId).not.toContain('uid-a');
  });
});

/**
 * Locks the shape of a cross-account export and tombstone incident (contract
 * `*_sync.v1#accountScopeInvariants`).
 *
 * Observed in production: a new account `preferences/main` held 18 capability tombstones
 * referencing conversation ids belonging to the previous account, plus a revision 3 generation
 * draft record from that account minted into a revision 4 tombstone. Official providers use a
 * deterministic UUIDv5(kind|region), so the id is identical across accounts, and an action as
 * ordinary as "delete this provider" tombstones another account records in bulk and uploads them
 * together with that account conversation ids.
 *
 * What is locked: after a UID change the export is empty and a delete mints no tombstones. Every
 * assertion looks at the actual output of the production functions.
 */
describe('cross-account export and tombstone minting', () => {
  const CONNECTION = 'a0000000-0000-0000-0000-000000000001';
  const DRAFT_CONVERSATION = 'b0000000-0000-0000-0000-0000000000ff';

  const conversationScope = (conversationId: string) => ({
    scope: 'conversation_connection_model' as const,
    providerId: CONNECTION,
    canonicalModelId: 'model-a',
    finalTransport: 'openai_responses',
    runtimeRevision: 'runtime-r7',
    transportIdentity,
    conversationId,
  });

  /** Previous account conversations: 18 conversation-scoped capability records plus one revision 3 draft generation record. */
  function seedAccidentShapeForA(): string[] {
    partitionMocks.activeUID = 'uid-a';
    const conversationIds = Array.from(
      { length: 18 },
      (_, index) => `b0000000-0000-0000-0000-${String(index).padStart(12, '0')}`,
    );
    for (const conversationId of conversationIds) {
      saveCapabilityPreferences(conversationScope(conversationId), { web: 'automatic' });
    }
    // revision 3 means the same record was written three times, which in production is a user repeatedly tuning parameters in a draft conversation.
    for (const temperature of [0.1, 0.2, 0.3]) {
      saveGenerationParameterOverrides(
        { providerId: CONNECTION, modelId: 'model-a', conversationId: DRAFT_CONVERSATION },
        { temperature: { state: 'value', value: temperature } },
      );
    }
    return conversationIds;
  }

  beforeEach(() => {
    memory.clear();
    partitionMocks.activeUID = 'guest';
  });

  it('after a uid change both envelopes carry empty records and tombstones, so a new account first send contains nothing from the previous one', () => {
    seedAccidentShapeForA();
    // First prove that the data for A really exists, otherwise "empty" could just mean nothing was ever written.
    expect(exportCapabilityPreferenceSyncPayload().records).toHaveLength(18);
    const generationForA = exportGenerationParameterSyncPayload();
    expect(generationForA.records).toHaveLength(1);
    expect(generationForA.records[0]!.revision).toBe(3);

    partitionMocks.activeUID = 'uid-b';
    const capability = exportCapabilityPreferenceSyncPayload();
    expect(capability.records).toEqual([]);
    expect(capability.tombstones).toEqual([]);
    const generation = exportGenerationParameterSyncPayload();
    expect(generation.records).toEqual([]);
    expect(generation.tombstones).toEqual([]);
    expect(generation.presets).toEqual([]);
  });

  it('deleting the same deterministic provider under a new account mints no tombstone for the other account', () => {
    const conversationIds = seedAccidentShapeForA();

    partitionMocks.activeUID = 'uid-b';
    // An official provider has the same id across accounts, so B deleting "the same" connection is the step that really happens in production.
    removeGenerationParameterScopes({ providerId: CONNECTION });
    deleteAllCapabilityPreferencesForConnection(CONNECTION);

    expect(exportCapabilityPreferenceSyncPayload().tombstones).toEqual([]);
    expect(exportGenerationParameterSyncPayload().tombstones).toEqual([]);

    // A partition is untouched by the delete B performed: no tombstone was minted and no record was moved.
    partitionMocks.activeUID = 'uid-a';
    const capabilityForA = exportCapabilityPreferenceSyncPayload();
    expect(capabilityForA.records).toHaveLength(18);
    expect(capabilityForA.tombstones).toEqual([]);
    for (const record of capabilityForA.records) {
      expect(conversationIds).toContain(record.conversationId);
    }
  });
});

describe('capability preference draft slotting and reclamation', () => {
  beforeEach(() => {
    memory.clear();
    partitionMocks.activeUID = 'guest';
    vi.useRealTimers();
  });

  const identity = (canonicalModelId: string) => ({
    providerId: scope.providerId,
    canonicalModelId,
    finalTransport: 'openai_responses',
    runtimeRevision: 'runtime-r7',
    transportIdentity,
  });

  it('switching models inside one draft conversation does not overwrite the other: each model gets its own slot', async () => {
    const { loadCapabilityPreferenceDraft, saveCapabilityPreferenceDraft } = await import('../capability-preference-settings');
    saveCapabilityPreferenceDraft('draft-1', identity('model-a'), { web: 'automatic' });
    saveCapabilityPreferenceDraft('draft-1', identity('model-b'), { web: 'force' });

    expect(loadCapabilityPreferenceDraft('draft-1', identity('model-a'))).toEqual({ web: 'automatic' });
    expect(loadCapabilityPreferenceDraft('draft-1', identity('model-b'))).toEqual({ web: 'force' });
  });

  it('migration moves only the entry for the current identity and leaves the slots of other models untouched', async () => {
    const {
      loadCapabilityPreferenceDraft, saveCapabilityPreferenceDraft, migrateCapabilityPreferenceDraft,
    } = await import('../capability-preference-settings');
    saveCapabilityPreferenceDraft('draft-1', identity('model-a'), { web: 'automatic' });
    saveCapabilityPreferenceDraft('draft-1', identity('model-b'), { web: 'force' });

    migrateCapabilityPreferenceDraft('draft-1', { ...identity('model-a'), conversationId: 'b0000000-0000-0000-0000-000000000009' });

    expect(loadCapabilityPreferenceDraft('draft-1', identity('model-a'))).toBeUndefined();
    expect(loadCapabilityPreferenceDraft('draft-1', identity('model-b'))).toEqual({ web: 'force' });
    expect(displayCapabilityPreferences({
      ...identity('model-a'), conversationId: 'b0000000-0000-0000-0000-000000000009',
    }).web).toBe('automatic');
  });

  it('expired drafts are reclaimed; entries without a timestamp have no measurable age and are kept', async () => {
    const { loadCapabilityPreferenceDraft, saveCapabilityPreferenceDraft } = await import('../capability-preference-settings');
    saveCapabilityPreferenceDraft('draft-old', identity('model-a'), { web: 'automatic' });
    // Push the persisted timestamp back 31 days directly, changing only that one field rather than synthesizing a table shape.
    const key = 'oriveo.guest.capability-preference-drafts.v2';
    const stored = JSON.parse(memory.get(key)!) as Record<string, { updatedAt?: number }>;
    const [slot] = Object.keys(stored);
    stored[slot!]!.updatedAt = Date.now() - 31 * 24 * 60 * 60 * 1000;
    stored['legacy-bare-draft-id'] = JSON.parse(JSON.stringify(stored[slot!]));
    delete stored['legacy-bare-draft-id']!.updatedAt;
    memory.set(key, JSON.stringify(stored));

    expect(loadCapabilityPreferenceDraft('draft-old', identity('model-a'))).toBeUndefined();
    expect(loadCapabilityPreferenceDraft('legacy-bare-draft-id', identity('model-a'))).toEqual({ web: 'automatic' });
  });
});

describe('capabilityRuntimeIdentity is still produced by the production resolver, with partitioning out of the picture', () => {
  it('the three identity parts come from provider/model/metadata and carry no UID', () => {
    partitionMocks.activeUID = 'uid-a';
    const resolved = capabilityRuntimeIdentity(
      { id: scope.providerId, kind: 'relay', relayResolvedTransport: 'openai_responses' } as never,
      { id: 'model-a', canonicalModelId: 'model-a', transport: 'openai_responses' } as never,
    );
    expect(resolved?.transportIdentity).toBe(transportIdentity);
    expect(JSON.stringify(resolved)).not.toContain('uid-a');
  });
});
