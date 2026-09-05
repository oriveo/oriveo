import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';
const metadataMocks = vi.hoisted(() => ({
  getCapabilityRuntime: vi.fn(() => ({ revision: 'runtime-r7' })),
  resolveCatalogModel: vi.fn((modelId: string) => modelId === 'alias-model'
    ? { canonicalModelId: 'canonical-model', transport: 'openai_responses' }
    : null),
}));
vi.mock('../metadata/metadata-client', () => metadataMocks);
import {
  capabilityPreferenceRecordId, deleteCapabilityPreferences, exportCapabilityPreferenceSyncPayload,
  mergeCapabilityPreferenceSyncPayload, resolveCapabilityPreferences, saveCapabilityPreferences,
  loadCapabilityPreferenceDraft, saveCapabilityPreferenceDraft, migrateCapabilityPreferenceDraft,
  withCapabilityReasoningIntent, deleteAllCapabilityPreferencesForConnection,
  encodeCapabilityTransportIdentity, decodeCapabilityTransportIdentity,
  hasDormantLegacyCapabilityPreferences,
  capabilityRuntimeIdentity,
  displayCapabilityPreferences,
} from './capability-preference-settings';

const memory = new Map<string, string>();
vi.stubGlobal('window', {});
vi.stubGlobal('localStorage', { getItem: (k: string) => memory.get(k) ?? null, setItem: (k: string, v: string) => memory.set(k, v) });
vi.stubGlobal('crypto', { randomUUID: vi.fn(() => 'mutation-z') });
const transportIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r7');
const base = {
  scope: 'connection_model' as const,
  providerId: 'A0000000-0000-0000-0000-000000000001',
  canonicalModelId: 'Model/Case',
  finalTransport: 'openai_responses',
  runtimeRevision: 'runtime-r7',
  transportIdentity,
};
const fixture = JSON.parse(readFileSync(resolve(process.cwd(), '../../..', 'shared/model-contracts/capability_preference_sync.v1.json'), 'utf8'));
describe('capability_preference_sync.v1', () => {
  beforeEach(() => memory.clear());
  it('exports only flat typed records and a durable tombstone', () => {
    saveCapabilityPreferences(base, { web: 'force', reasoningIntent: 'deep' });
    const first = exportCapabilityPreferenceSyncPayload();
    expect(first).toMatchObject({ schemaVersion: 2, records: [{ recordId: `scope:model:a0000000-0000-0000-0000-000000000001:Model/Case:${transportIdentity}`, web: 'force', reasoningIntent: 'deep' }] });
    expect(Object.keys(first.records[0]).sort()).toEqual(['canonicalModelId','mutationId','providerId','reasoningIntent','recordId','revision','scope','transportIdentity','web']);
    deleteCapabilityPreferences(base);
    const removed = exportCapabilityPreferenceSyncPayload();
    expect(removed.records).toEqual([]);
    expect(removed.tombstones[0]).toMatchObject({ recordId: first.records[0].recordId, mutationId: 'mutation-z', revision: 2 });
  });
  it('rejects custom/aliases and lets the LWW tombstone beat a stale record', () => {
    const id = capabilityPreferenceRecordId(base);
    mergeCapabilityPreferenceSyncPayload({ schemaVersion: 2, records: [{ ...base, recordId: id, web: 'custom', revision: 99, mutationId: 'bad' }], tombstones: [{ recordId: id, revision: 2, mutationId: 'z' }] });
    mergeCapabilityPreferenceSyncPayload({ schemaVersion: 2, records: [{ ...base, recordId: id, web: 'automatic', reasoningIntent: 'high', revision: 100, mutationId: 'also-bad' }], tombstones: [] });
    expect(exportCapabilityPreferenceSyncPayload().records).toEqual([]);
    expect(exportCapabilityPreferenceSyncPayload().tombstones).toHaveLength(1);
  });
  it('uses all seven request-preference layers and preserves sparse off', () => {
    saveCapabilityPreferences({ ...base, scope: 'connection' }, { web: 'automatic', reasoningIntent: 'low' });
    saveCapabilityPreferences({ ...base, scope: 'connection_model' }, { web: 'off' });
    expect(resolveCapabilityPreferences(base)).toEqual({ web: 'off', reasoningIntent: 'low' });
    expect(resolveCapabilityPreferences({ ...base, singleSend: { web: 'force', reasoningIntent: 'max' } })).toEqual({ web: 'force', reasoningIntent: 'max' });
  });
  it('clears a previous reasoning rung when the UI returns to supplier default', () => {
    expect(withCapabilityReasoningIntent({ web: 'automatic', reasoningIntent: 'deep' }, undefined))
      .toEqual({ web: 'automatic' });
    expect(withCapabilityReasoningIntent({ web: 'automatic', reasoningIntent: 'deep' }, 'off'))
      .toEqual({ web: 'automatic', reasoningIntent: 'off' });
  });
  it('keeps two new-conversation drafts local until the first send assigns a real conversation id', () => {
    saveCapabilityPreferenceDraft('draft-a', base, { web: 'force' });
    saveCapabilityPreferenceDraft('draft-b', base, { web: 'off' });
    expect(loadCapabilityPreferenceDraft('draft-a', base)).toEqual({ web: 'force' });
    expect(exportCapabilityPreferenceSyncPayload().records).toEqual([]);
    migrateCapabilityPreferenceDraft('draft-a', { ...base, conversationId: 'B0000000-0000-0000-0000-000000000001' });
    expect(loadCapabilityPreferenceDraft('draft-a', base)).toBeUndefined();
    expect(resolveCapabilityPreferences({ ...base, conversationId: 'B0000000-0000-0000-0000-000000000001' })).toEqual({ web: 'force' });
    expect(resolveCapabilityPreferences({ ...base, conversationId: 'B0000000-0000-0000-0000-000000000002' })).toEqual({ web: 'off' });
  });
  it('consumes the frozen shared fixture: four flat records, canonical ids, and no raw custom', () => {
    for (const item of fixture.recordIdCases) expect(capabilityPreferenceRecordId(item)).toBe(item.recordId);
    mergeCapabilityPreferenceSyncPayload(fixture.payload);
    const payload = exportCapabilityPreferenceSyncPayload();
    expect(payload.records).toHaveLength(4);
    expect(payload.tombstones).toHaveLength(1);
    expect(JSON.stringify(payload)).not.toContain('custom');
    expect(payload.records.every((record) => !('values' in record) && !('raw' in record))).toBe(true);
    // A confirmed record written by iOS/Android is consumed by the Web send resolver;
    // legacy Skill fields are not a producer for this v1 record.
    expect(resolveCapabilityPreferences({
      providerId: '9A1195DE-3AF9-5888-ABC8-B8177C458C07', canonicalModelId: 'gpt-test',
      finalTransport: 'anthropic_messages', runtimeRevision: 'runtime-r7',
      skillId: '3FA85F64-5717-4562-B3FC-2C963F66AFA6',
      transportIdentity: encodeCapabilityTransportIdentity('anthropic_messages', 'runtime-r7'),
    })).toEqual({ web: 'automatic', reasoningIntent: 'off' });
  });
  it('rejects every frozen invalid tombstone instead of letting a remote id delete a record', () => {
    mergeCapabilityPreferenceSyncPayload({ schemaVersion: 2, records: [], tombstones: fixture.invalidTombstoneCases });
    expect(exportCapabilityPreferenceSyncPayload().tombstones).toEqual([]);
  });
  it('retains canonical tombstones when model ids or transport fingerprints contain colons', () => {
    mergeCapabilityPreferenceSyncPayload({ schemaVersion: 2, records: [], tombstones: [{
      recordId: `scope:model:9a1195de-3af9-5888-abc8-b8177c458c07:llama3:latest:${encodeCapabilityTransportIdentity('relay:ollama', 'runtime:latest')}`,
      revision: 2, mutationId: 'relay-colon-model',
    }] });
    expect(exportCapabilityPreferenceSyncPayload().tombstones).toHaveLength(1);
  });
  it('keeps legacy raw identity dormant and never mistakes LWW revision for runtime revision', () => {
    memory.set('oriveo.capability-preference-settings.v1', JSON.stringify({ records: [{ transportIdentity: 'openai_responses', revision: 7 }] }));
    expect(hasDormantLegacyCapabilityPreferences()).toBe(true);
    expect(exportCapabilityPreferenceSyncPayload()).toEqual({ schemaVersion: 2, records: [], tombstones: [] });
    expect(decodeCapabilityTransportIdentity('openai_responses')).toBeNull();
    expect(decodeCapabilityTransportIdentity(encodeCapabilityTransportIdentity('openai_responses', '7'))).toEqual({ finalTransport: 'openai_responses', runtimeRevision: '7' });
  });
  it('isolates model, final transport and runtime revision and tombstones all variants on connection deletion', () => {
    saveCapabilityPreferences(base, { web: 'force' });
    const switched = { ...base, runtimeRevision: 'runtime-r8', transportIdentity: encodeCapabilityTransportIdentity('openai_responses', 'runtime-r8') };
    // Only the recipe revision moved on the same protocol, so the stored preference is not silently
    // reset. A real protocol change still resets it.
    expect(resolveCapabilityPreferences(switched)).toEqual({ web: 'force' });
    saveCapabilityPreferences(switched, { web: 'automatic' });
    deleteAllCapabilityPreferencesForConnection(base.providerId);
    const payload = exportCapabilityPreferenceSyncPayload();
    expect(payload.records).toEqual([]);
    expect(payload.tombstones).toHaveLength(2);
    mergeCapabilityPreferenceSyncPayload({ schemaVersion: 2, records: [{
      ...base, recordId: capabilityPreferenceRecordId(base), web: 'force', revision: 1, mutationId: 'stale',
    }], tombstones: [] });
    expect(exportCapabilityPreferenceSyncPayload().records).toEqual([]);
  });
  it('takes official canonical model and transport from the same production catalog resolution', () => {
    const provider = { id: base.providerId, kind: 'openAI' } as never;
    const staleUIModel = { id: 'alias-model', canonicalModelId: 'stale-ui-canonical', transport: 'openai_chat' } as never;
    expect(capabilityRuntimeIdentity(provider, staleUIModel)).toMatchObject({
      canonicalModelId: 'canonical-model', finalTransport: 'openai_responses', runtimeRevision: 'runtime-r7',
    });
    expect(capabilityRuntimeIdentity(provider, staleUIModel, 'openai_chat')).toBeNull();
    expect(capabilityRuntimeIdentity(provider, { id: 'missing' } as never)).toBeNull();
    expect(capabilityRuntimeIdentity({ id: base.providerId, kind: 'relay', relayRequested: { transport: 'auto' } } as never, { id: 'local-model' } as never)).toBeNull();
  });
});

/**
 * Read ladder and display selection.
 *
 * The UI read and the send read must walk the same ladder over the same records and only diverge
 * at the final fold. Once "set as the default for this model" has written to `connection_model`, a
 * UI that still looks only at the conversation layer would report "never set" while the preference
 * is in fact active on every send.
 */
describe('display read ladder', () => {
  beforeEach(() => memory.clear());

  it('uses the same ladder as the send path: conversation > skill > connection x model > connection', () => {
    saveCapabilityPreferences({ ...base, scope: 'connection' }, { web: 'automatic', reasoningIntent: 'low' });
    saveCapabilityPreferences({ ...base, scope: 'connection_model' }, { web: 'force' });
    const conversationId = 'B0000000-0000-0000-0000-000000000001';

    // With only the connection and connection x model layers set, both sides agree; the read is not limited to the conversation layer.
    expect(displayCapabilityPreferences({ ...base, conversationId }))
      .toEqual(resolveCapabilityPreferences({ ...base, conversationId }));
    expect(displayCapabilityPreferences({ ...base, conversationId })).toEqual({ web: 'force', reasoningIntent: 'low' });

    // The conversation layer wins over the layers below it, and both sides still agree.
    saveCapabilityPreferences({ ...base, scope: 'conversation_connection_model', conversationId }, { web: 'off' });
    expect(displayCapabilityPreferences({ ...base, conversationId })).toEqual({ web: 'off', reasoningIntent: 'low' });
  });

  it('distinguishes never set, explicitly automatic, and explicitly off', () => {
    // Never set: the thinking level is undefined, which the UI renders as "automatic" selected, not 'off'.
    expect(displayCapabilityPreferences(base)).toEqual({ web: 'off' });
    expect('reasoningIntent' in displayCapabilityPreferences(base)).toBe(false);

    // Choosing "automatic" explicitly means injecting no level, so nothing is stored either. That is
    // the same state as never having set it, and both must render "automatic" selected, not "off".
    saveCapabilityPreferences(base, { web: 'automatic' });
    expect(displayCapabilityPreferences(base)).toEqual({ web: 'automatic' });

    // Choosing "off" explicitly reads back as 'off', which is distinguishable from the two states above.
    saveCapabilityPreferences(base, { web: 'automatic', reasoningIntent: 'off' });
    expect(displayCapabilityPreferences(base)).toEqual({ web: 'automatic', reasoningIntent: 'off' });
  });

  it('a singleSend override changes only the send result, not the value read back for the UI', () => {
    saveCapabilityPreferences({ ...base, scope: 'connection_model' }, { web: 'automatic' });
    // The outbound path forces web to off for this one send, while the UI still reads back the user's own choice.
    expect(resolveCapabilityPreferences({ ...base, singleSend: { web: 'off' } })).toEqual({ web: 'off' });
    expect(displayCapabilityPreferences(base)).toEqual({ web: 'automatic' });
  });
});

/**
 * Lazy forward-port of typed preferences across recipe revisions.
 *
 * Every new recipe the server publishes changes `runtimeRevision`, and preferences are keyed by
 * identity. Without forward-porting, the web search and thinking settings a user configured last
 * week would all read as "never set" one morning without them having touched anything.
 */
describe('typed preference forward-port matrix', () => {
  const older = base;
  const currentIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r9');
  const current = { ...base, runtimeRevision: 'runtime-r9', transportIdentity: currentIdentity };
  const conversationId = 'B0000000-0000-0000-0000-000000000001';
  const skillId = '3FA85F64-5717-4562-B3FC-2C963F66AFA6';
  const recordsFor = (transportIdentity: string) => exportCapabilityPreferenceSyncPayload()
    .records.filter((record) => record.transportIdentity === transportIdentity);

  beforeEach(() => memory.clear());

  it('forward-ports only when the transport is unchanged and just the revision moved', () => {
    saveCapabilityPreferences(older, { web: 'force', reasoningIntent: 'deep' });
    expect(resolveCapabilityPreferences(current)).toEqual({ web: 'force', reasoningIntent: 'deep' });

    // A different protocol is a different request contract (field names, available levels, schema), so carrying values across would mean guessing for the user.
    const otherTransport = {
      ...base, finalTransport: 'anthropic_messages',
      transportIdentity: encodeCapabilityTransportIdentity('anthropic_messages', 'runtime-r9'),
    };
    expect(resolveCapabilityPreferences(otherTransport)).toEqual({ web: 'off' });
  });

  it('forward-ports each scope independently, with no scope overriding another', () => {
    saveCapabilityPreferences({ ...older, scope: 'conversation_connection_model', conversationId }, { web: 'force' });
    saveCapabilityPreferences({ ...older, scope: 'skill_agent', skillId }, { web: 'automatic' });
    saveCapabilityPreferences({ ...older, scope: 'connection_model' }, { reasoningIntent: 'low', web: 'off' });
    saveCapabilityPreferences({ ...older, scope: 'connection' }, { web: 'automatic', reasoningIntent: 'max' });

    resolveCapabilityPreferences({ ...current, conversationId, skillId });

    const ported = recordsFor(currentIdentity);
    expect(ported.map((record) => record.scope).sort()).toEqual([
      'connection', 'connection_model', 'conversation_connection_model', 'skill_agent',
    ]);
    // A force at the conversation layer stays at the conversation layer; scopes never override each other.
    expect(ported.find((record) => record.scope === 'conversation_connection_model')?.web).toBe('force');
    expect(ported.find((record) => record.scope === 'connection_model')?.web).toBe('off');
    expect(ported.find((record) => record.scope === 'connection')?.reasoningIntent).toBe('max');
    // Ids outside the scope must not be written into a record: a connection-level record carrying a conversationId is dirty data its recordId cannot describe.
    expect(ported.find((record) => record.scope === 'connection_model')?.conversationId).toBeUndefined();
  });

  it('triggers on every read path, so display and resolve behave the same', () => {
    saveCapabilityPreferences(older, { web: 'force' });
    expect(displayCapabilityPreferences(current)).toEqual({ web: 'force' });
    expect(recordsFor(currentIdentity)).toHaveLength(1);
  });

  it('skips the forward-port when the target already has a record, and leaves the old record in place', () => {
    saveCapabilityPreferences(older, { web: 'force' });
    saveCapabilityPreferences(current, { web: 'off' });

    expect(resolveCapabilityPreferences(current)).toEqual({ web: 'off' });
    // The old record is left untouched so a rollback to the earlier recipe revision still picks it up.
    expect(recordsFor(base.transportIdentity)).toHaveLength(1);
    expect(recordsFor(base.transportIdentity)[0]!.web).toBe('force');
  });

  it('skips the forward-port when the current version has a tombstone, so a delete is not resurrected', () => {
    saveCapabilityPreferences(older, { web: 'force' });
    saveCapabilityPreferences(current, { web: 'automatic' });
    deleteCapabilityPreferences(current);

    expect(resolveCapabilityPreferences(current)).toEqual({ web: 'off' });
    expect(recordsFor(currentIdentity)).toEqual([]);
    expect(exportCapabilityPreferenceSyncPayload().tombstones).toHaveLength(1);
  });

  it('writes a valid versioned sync record that a stale remote write cannot overwrite', () => {
    saveCapabilityPreferences(older, { web: 'force' });
    resolveCapabilityPreferences(current);

    const ported = recordsFor(currentIdentity)[0]!;
    expect(ported.revision).toBeGreaterThan(0);
    expect(ported.mutationId).toBeTruthy();
    expect(ported.recordId).toBe(capabilityPreferenceRecordId(current));

    // A remote record with a lower revision on the same recordId must not overwrite it, which shows LWW protection is not bypassed by rewriting the key.
    mergeCapabilityPreferenceSyncPayload({
      schemaVersion: 2,
      records: [{ ...current, recordId: ported.recordId, web: 'off', revision: ported.revision - 1 || 1, mutationId: 'aaa' }],
      tombstones: [],
    });
    expect(recordsFor(currentIdentity)[0]!.web).toBe('force');
  });

  it('is idempotent: repeated reads add no second record and do not bump revision', () => {
    saveCapabilityPreferences(older, { web: 'force' });
    resolveCapabilityPreferences(current);
    const first = recordsFor(currentIdentity)[0]!;

    for (let index = 0; index < 5; index += 1) {
      resolveCapabilityPreferences(current);
      displayCapabilityPreferences(current);
    }

    expect(recordsFor(currentIdentity)).toHaveLength(1);
    expect(recordsFor(currentIdentity)[0]!.revision).toBe(first.revision);
    expect(recordsFor(currentIdentity)[0]!.mutationId).toBe(first.mutationId);
  });

  it('leaves exactly one correct record after 16 reads in the same tick', () => {
    saveCapabilityPreferences(older, { web: 'force', reasoningIntent: 'balanced' });
    const results = Array.from({ length: 16 }, () => resolveCapabilityPreferences(current));

    expect(results.every((value) => value.web === 'force' && value.reasoningIntent === 'balanced')).toBe(true);
    expect(recordsFor(currentIdentity)).toHaveLength(1);
  });

  it('takes the user last expression: an edited older revision beats an intermediate revision that was only forward-ported', () => {
    const middleIdentity = encodeCapabilityTransportIdentity('openai_responses', 'runtime-r8');
    const middle = { ...base, runtimeRevision: 'runtime-r8', transportIdentity: middleIdentity };
    saveCapabilityPreferences(older, { web: 'automatic' });
    // The intermediate revision goes live and one read carries the value over.
    expect(resolveCapabilityPreferences(middle)).toEqual({ web: 'automatic' });
    // After a rollback the user sets force on the older revision, which therefore carries the higher revision.
    saveCapabilityPreferences(older, { web: 'force' });

    expect(resolveCapabilityPreferences(current)).toEqual({ web: 'force' });
  });
});
