// @vitest-environment jsdom

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  exportGenerationParameterSettingsJSON,
  exportGenerationParameterSyncPayload,
  generationParameterProfileFingerprint,
  importGenerationParameterSettingsJSON,
  loadConnectionGenerationParameterDefaults,
  loadGenerationParameterOverrides,
  mergeGenerationParameterSyncPayload,
  migrateGenerationParameterSession,
  removeGenerationParameterScopes,
  resolveGenerationParameterOverrides,
  saveGenerationParameterOverrides,
  saveConnectionGenerationParameterDefaults,
  valueOverride,
  applyGenerationParameterPreset,
  listGenerationParameterPresets,
  saveGenerationParameterPreset,
} from './generation-parameter-settings';

const modelScope = { providerId: 'provider-a', modelId: 'model-a' };
const syncFixture = JSON.parse(readFileSync(resolve(
  process.cwd(),
  '../../..',
  'shared/model-contracts/generation_parameter_sync.v1.json',
), 'utf8')) as {
  schemaVersion: number;
  payload: unknown;
  idCasing: {
    canonicalCases: { caseId: string; input: string; canonical: string }[];
    recordIdCases: {
      caseId: string;
      scope: 'connection_default' | 'model_default' | 'conversation_override';
      providerId: string;
      modelId?: string;
      conversationId?: string;
      recordId: string;
    }[];
  };
};

// Canonical UUIDs in this project are uppercase (see id-utils.normalizeUUID and the deterministic provider id rules).
const UPPER_PROVIDER = '9A1195DE-3AF9-5888-ABC8-B8177C458C07';
const UPPER_CONVERSATION = '7C9E6679-7425-40DE-944B-E07FC1F90AE7';

afterEach(() => localStorage.clear());

describe('generation parameter local settings', () => {
  it('stores per provider and model on this device only, and treats 0 as an explicit value', () => {
    saveGenerationParameterOverrides(modelScope, { temperature: valueOverride(0) });

    expect(loadGenerationParameterOverrides(modelScope)).toEqual({
      temperature: { state: 'value', value: 0 },
    });
    expect(loadGenerationParameterOverrides({ providerId: 'provider-b', modelId: 'model-a' })).toBeUndefined();
  });

  it('resolves transient over the conversation override over the model default, and omit does not fall back', () => {
    saveGenerationParameterOverrides(modelScope, {
      temperature: valueOverride(0.7),
      top_p: valueOverride(0.9),
    });
    saveGenerationParameterOverrides({ ...modelScope, conversationId: 'conversation-a' }, {
      temperature: { state: 'omit' },
      top_p: { state: 'inherit' },
    });

    expect(resolveGenerationParameterOverrides({ ...modelScope, conversationId: 'conversation-a' })).toEqual({
      temperature: { state: 'omit' },
      top_p: { state: 'value', value: 0.9 },
    });
    expect(resolveGenerationParameterOverrides({
      ...modelScope,
      conversationId: 'conversation-a',
      transient: { temperature: valueOverride(0.2) },
    })).toEqual({
      temperature: { state: 'value', value: 0.2 },
      top_p: { state: 'value', value: 0.9 },
    });
  });

  it('reuses a connection-level default across models at a lower priority than the model default', () => {
    saveConnectionGenerationParameterDefaults('provider-a', {
      temperature: valueOverride(0.6),
      top_p: valueOverride(0.8),
    });
    saveGenerationParameterOverrides(modelScope, { temperature: valueOverride(0.2) });

    expect(resolveGenerationParameterOverrides(modelScope)).toEqual({
      temperature: valueOverride(0.2),
      top_p: valueOverride(0.8),
    });
    expect(resolveGenerationParameterOverrides({ providerId: 'provider-a', modelId: 'model-b' })).toEqual({
      temperature: valueOverride(0.6),
      top_p: valueOverride(0.8),
    });
  });

  // The three reasoning entries at connection scope are not a read-only projection: they really go
  // out on the wire. Priority is an explicit conversation-level reasoning chip, then the
  // connection-level reasoning default, then the profile default. Asserting that reasoning is
  // skipped for every scope was the source of read-back false positives.
  describe('scope priority for the reasoning group', () => {
    it('lets the connection-scope reasoning default go out while the chip stays on Auto', () => {
      saveGenerationParameterOverrides(modelScope, {
        reasoning_effort: valueOverride('high'),
        temperature: valueOverride(0.4),
      });

      expect(resolveGenerationParameterOverrides({ ...modelScope, reasoningMode: 'automatic' })).toEqual({
        reasoning_effort: valueOverride('high'),
        temperature: valueOverride(0.4),
      });
      // A caller that passes no reasoningMode is equivalent to Auto and must not swallow the user's value.
      expect(resolveGenerationParameterOverrides(modelScope)).toEqual({
        reasoning_effort: valueOverride('high'),
        temperature: valueOverride(0.4),
      });
    });

    it('yields the whole connection-level reasoning group when the chip selects a level, leaving other parameters alone', () => {
      saveGenerationParameterOverrides(modelScope, {
        reasoning_effort: valueOverride('high'),
        reasoning_budget: valueOverride(2048),
        temperature: valueOverride(0.4),
      });

      expect(resolveGenerationParameterOverrides({ ...modelScope, reasoningMode: 'deep' })).toEqual({
        temperature: valueOverride(0.4),
      });
    });

    it('keeps reasoning out of conversation scope, transient or override, since the chip is the only write entry', () => {
      saveGenerationParameterOverrides(
        { ...modelScope, conversationId: 'conversation-a' },
        { reasoning_effort: valueOverride('low') },
      );

      expect(resolveGenerationParameterOverrides({
        ...modelScope,
        conversationId: 'conversation-a',
        reasoningMode: 'automatic',
        transient: { reasoning_effort: valueOverride('max' as unknown as number) },
      })).toBeUndefined();
    });
  });

  it('drops the scope when no explicit value remains, and falls back to empty on a corrupt cache', () => {
    saveGenerationParameterOverrides(modelScope, { temperature: valueOverride(0.1) });
    saveGenerationParameterOverrides(modelScope, { temperature: { state: 'inherit' } });
    expect(loadGenerationParameterOverrides(modelScope)).toBeUndefined();

    localStorage.setItem('oriveo.guest.generation-parameter-settings.v1', '{invalid');
    expect(resolveGenerationParameterOverrides(modelScope)).toBeUndefined();
  });

  // Treating a fingerprint change as making the whole record unreadable is the record-level
  // all-or-nothing invalidation the contract forbids, and it is what produced orphan records that
  // exported and merged fine yet could never be read back on the device that wrote them.
  // Storage now reads back every stored value for a logical scope, and compatibility is decided per
  // parameter id in `generation-parameter-lifecycle`.
  it('still reads a record back after a Relay endpoint or protocol fingerprint change, migrating the fingerprint on the next save', () => {
    const first = { ...modelScope, profileFingerprint: 'endpoint-a|openai_chat_completions' };
    const second = { ...modelScope, profileFingerprint: 'endpoint-b|anthropic_messages' };
    saveGenerationParameterOverrides(first, { temperature: valueOverride(0.4) });

    expect(loadGenerationParameterOverrides(first)?.temperature).toEqual(valueOverride(0.4));
    expect(loadGenerationParameterOverrides(second)?.temperature).toEqual(valueOverride(0.4));

    saveGenerationParameterOverrides(second, { temperature: valueOverride(0.9) });
    const stored = JSON.parse(localStorage.getItem('oriveo.guest.generation-parameter-settings.v1')!) as {
      scopes: { modelId?: string; profileFingerprint?: string }[];
    };
    // Migrate rather than coexist: one record per logical scope, with the fingerprint replaced.
    expect(stored.scopes.filter((item) => item.modelId === modelScope.modelId)).toHaveLength(1);
    expect(stored.scopes[0].profileFingerprint).toBe(second.profileFingerprint);
  });

  // Outbound side: dormant values stay in storage and sync, but the evaluation chain blocks them once it has activeParameterIds.
  it('blocks dormant values via activeParameterIds without affecting parameters that still apply', () => {
    saveGenerationParameterOverrides(modelScope, {
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });

    expect(resolveGenerationParameterOverrides({
      ...modelScope,
      activeParameterIds: new Set(['temperature']),
    })).toEqual({ temperature: valueOverride(0.4) });
    // Storage is untouched: retention is what dormant means, so the value must not be deleted in passing.
    expect(loadGenerationParameterOverrides(modelScope)?.frequency_penalty).toEqual(valueOverride(0.5));
    // Sync still carries it as usual; deletion only ever happens through a tombstone.
    expect(exportGenerationParameterSyncPayload().records[0]?.values).toEqual({
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });
  });

  it('reads the conversation and model layers through the same environment fingerprint in the resolver', () => {
    const scoped = { ...modelScope, profileFingerprint: 'ep_hash|openai_chat_completions|vllm|model-a' };
    saveGenerationParameterOverrides(scoped, { top_p: valueOverride(0.8) });
    saveGenerationParameterOverrides({ ...scoped, conversationId: 'conversation-a' }, { temperature: valueOverride(0.2) });

    expect(resolveGenerationParameterOverrides({ ...scoped, conversationId: 'conversation-a' })).toEqual({
      temperature: valueOverride(0.2),
      top_p: valueOverride(0.8),
    });
  });

  it('keeps the raw Relay request URL out of the environment fingerprint and prefers the resolved transport', () => {
    const fingerprint = generationParameterProfileFingerprint({
      id: 'relay-a', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: '', apiKeyPreview: '',
      baseURLText: 'https://user:secret@box.local/v1?token=private',
      relayResolvedTransport: 'anthropic_messages',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'auto' },
    }, { id: 'private-model', name: 'Private', capabilities: [], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '' });

    expect(fingerprint).toContain('anthropic_messages');
    expect(fingerprint).not.toContain('box.local');
    expect(fingerprint).not.toContain('secret');
    expect(fingerprint).not.toContain('token');
  });

  it('migrates a draft conversation to a real one atomically and cascades deletes', () => {
    const scoped = { ...modelScope, profileFingerprint: 'ep_hash|chat||model-a' };
    saveGenerationParameterOverrides({ ...scoped, conversationId: 'draft-a' }, { temperature: valueOverride(0.3) });
    migrateGenerationParameterSession({ ...scoped, fromConversationId: 'draft-a', toConversationId: 'conversation-a' });

    expect(loadGenerationParameterOverrides({ ...scoped, conversationId: 'draft-a' })).toBeUndefined();
    expect(loadGenerationParameterOverrides({ ...scoped, conversationId: 'conversation-a' })?.temperature).toEqual(valueOverride(0.3));
    removeGenerationParameterScopes({ conversationId: 'conversation-a' });
    expect(loadGenerationParameterOverrides({ ...scoped, conversationId: 'conversation-a' })).toBeUndefined();
  });

  it('binds a preset stably to a model and profile, excluding runtime settings and never copying implicitly across models', () => {
    const preset = saveGenerationParameterPreset({
      name: 'Precise',
      providerId: 'provider-a',
      modelId: 'model-a',
      profileFingerprint: 'fingerprint-a',
      values: {
        temperature: valueOverride(0.2),
        context_length: valueOverride(32_768),
      },
    });
    expect(listGenerationParameterPresets({
      providerId: 'provider-a', modelId: 'model-a', profileFingerprint: 'fingerprint-a',
    })).toHaveLength(1);
    expect(preset.values).toEqual({ temperature: valueOverride(0.2) });
    expect(applyGenerationParameterPreset(preset, {
      providerId: 'provider-a', modelId: 'model-b', profileFingerprint: 'fingerprint-b',
    })).toBeUndefined();
    expect(applyGenerationParameterPreset(preset, {
      providerId: 'provider-a', modelId: 'model-b', profileFingerprint: 'fingerprint-b',
    }, { temperature: 'sampling_temperature' })).toEqual({
      sampling_temperature: valueOverride(0.2),
    });
    expect(listGenerationParameterPresets({
      providerId: 'provider-a', modelId: 'model-b', profileFingerprint: 'fingerprint-b',
      portableParameterIds: ['temperature'],
    })).toEqual([preset]);
    expect(listGenerationParameterPresets({
      providerId: 'provider-a', modelId: 'model-b', profileFingerprint: 'fingerprint-b',
      portableParameterIds: ['top_p'],
    })).toEqual([]);

    removeGenerationParameterScopes({ providerId: 'provider-a', modelId: 'model-a' });
    expect(listGenerationParameterPresets({
      providerId: 'provider-a', modelId: 'model-a', profileFingerprint: 'fingerprint-a',
    })).toEqual([]);
  });

  it('accepts a synced preset without profileFingerprint but rejects the wrong type', () => {
    const stored = {
      scopes: [],
      presets: [{
        id: 'preset-from-sync',
        name: 'Synced',
        providerId: 'provider-a',
        modelId: 'model-a',
        syncProfileKey: 'openai_chat_completions||model-a',
        values: { temperature: valueOverride(0.3) },
        createdAt: 1,
        updatedAt: 2,
        revision: 3,
        mutationId: 'remote-a',
      }],
      tombstones: [],
    };
    localStorage.setItem('oriveo.guest.generation-parameter-settings.v1', JSON.stringify(stored));

    expect(listGenerationParameterPresets({ providerId: 'provider-a', modelId: 'model-a' }))
      .toHaveLength(1);
    expect(exportGenerationParameterSyncPayload().presets.map((item) => item.id))
      .toEqual(['preset-from-sync']);

    localStorage.setItem('oriveo.guest.generation-parameter-settings.v1', JSON.stringify({
      ...stored,
      presets: [{ ...stored.presets[0], profileFingerprint: 42 }],
    }));
    expect(listGenerationParameterPresets({ providerId: 'provider-a', modelId: 'model-a' }))
      .toEqual([]);
    expect(exportGenerationParameterSyncPayload().presets).toEqual([]);
  });

  it('exports only non-sensitive generation parameters, leaking no endpoint, runtime setting or custom text', () => {
    saveGenerationParameterOverrides({
      ...modelScope,
      profileFingerprint: 'ep_secret|openai_chat_completions|ollama|model-a',
    }, {
      temperature: valueOverride(0.3),
      context_length: valueOverride(32_768),
      stop: valueOverride(['private prompt'] as never),
      json_schema: valueOverride('{"private":true}'),
      custom_secret: valueOverride('secret'),
    });

    const exported = exportGenerationParameterSettingsJSON();
    expect(exported).toContain('temperature');
    expect(exported).not.toContain('ep_secret');
    expect(exported).not.toContain('context_length');
    expect(exported).not.toContain('private prompt');
    expect(exported).not.toContain('json_schema');
    expect(exported).not.toContain('custom_secret');
  });

  it('merges import and export deterministically by revision plus mutationId, so an old device cannot revive a delete tombstone', () => {
    const initial = {
      schemaVersion: 1 as const,
      records: [{
        recordId: 'scope:model:provider-a:model-a',
        scope: 'model_default' as const,
        providerId: 'provider-a',
        modelId: 'model-a',
        profileKey: 'openai_chat_completions||model-a',
        values: { temperature: valueOverride(0.4) },
        revision: 2,
        mutationId: 'device-a',
      }],
      presets: [],
      tombstones: [],
    };
    importGenerationParameterSettingsJSON(JSON.stringify(initial));
    expect(loadGenerationParameterOverrides({
      ...modelScope,
      profileFingerprint: 'different-endpoint|openai_chat_completions||model-a',
    })?.temperature).toEqual(valueOverride(0.4));

    const deleted = mergeGenerationParameterSyncPayload({
      ...initial,
      records: [],
      tombstones: [{ recordId: initial.records[0].recordId, revision: 3, mutationId: 'device-b' }],
    });
    expect(deleted.records).toEqual([]);
    expect(exportGenerationParameterSyncPayload().records).toEqual([]);

    const staleReplay = mergeGenerationParameterSyncPayload(initial);
    expect(staleReplay.records).toEqual([]);
    expect(staleReplay.tombstones).toHaveLength(1);
  });

  it('keeps the updatedAt of scope and preset on a no-op sync, refreshing only for a newer remote revision', () => {
    saveGenerationParameterOverrides({
      ...modelScope,
      profileFingerprint: 'endpoint|openai_chat_completions||model-a',
    }, { temperature: valueOverride(0.4) });
    saveGenerationParameterPreset({
      name: 'Precise',
      providerId: 'provider-a',
      modelId: 'model-a',
      profileFingerprint: 'endpoint|openai_chat_completions||model-a',
      values: { temperature: valueOverride(0.4) },
    });
    const key = 'oriveo.guest.generation-parameter-settings.v1';
    const stored = JSON.parse(localStorage.getItem(key)!) as {
      scopes: Array<{ updatedAt?: number }>;
      presets: Array<{ updatedAt: number }>;
    };
    const oldButLive = Date.now() - 179 * 24 * 60 * 60 * 1000;
    stored.scopes[0]!.updatedAt = oldButLive;
    stored.presets[0]!.updatedAt = oldButLive - 1;
    localStorage.setItem(key, JSON.stringify(stored));

    const wire = exportGenerationParameterSyncPayload();
    mergeGenerationParameterSyncPayload(wire);
    const afterNoOp = JSON.parse(localStorage.getItem(key)!) as typeof stored;
    expect(afterNoOp.scopes[0]!.updatedAt).toBe(oldButLive);
    expect(afterNoOp.presets[0]!.updatedAt).toBe(oldButLive - 1);
    expect(loadGenerationParameterOverrides(modelScope)?.temperature).toEqual(valueOverride(0.4));

    const remote = structuredClone(wire);
    remote.records[0]!.revision += 1;
    remote.records[0]!.mutationId = 'remote-newer';
    remote.records[0]!.values = { temperature: valueOverride(0.9) };
    mergeGenerationParameterSyncPayload(remote);
    const afterRemote = JSON.parse(localStorage.getItem(key)!) as typeof stored;
    expect(afterRemote.scopes[0]!.updatedAt).toBeGreaterThan(oldButLive);
    expect(loadGenerationParameterOverrides(modelScope)?.temperature).toEqual(valueOverride(0.9));
  });

  it('does not revive an expired scope when replaying a same-version remote on day 181, and only a higher revision refreshes the TTL', () => {
    saveGenerationParameterOverrides({
      ...modelScope,
      profileFingerprint: 'endpoint|openai_chat_completions||model-a',
    }, { temperature: valueOverride(0.4) });
    // Take the same-version remote through the production export path first, then simulate local time advancing to day 181.
    const sameVersionRemote = exportGenerationParameterSyncPayload();
    const key = 'oriveo.guest.generation-parameter-settings.v1';
    const stored = JSON.parse(localStorage.getItem(key)!) as {
      scopes: Array<{ updatedAt?: number }>;
    };
    const expiredAt = Date.now() - 181 * 24 * 60 * 60 * 1000;
    stored.scopes[0]!.updatedAt = expiredAt;
    localStorage.setItem(key, JSON.stringify(stored));

    expect(loadGenerationParameterOverrides(modelScope)).toBeUndefined();
    expect(exportGenerationParameterSyncPayload().records).toEqual([]);
    mergeGenerationParameterSyncPayload(sameVersionRemote);
    const afterReplay = JSON.parse(localStorage.getItem(key)!) as typeof stored;
    expect(afterReplay.scopes[0]!.updatedAt).toBe(expiredAt);
    expect(loadGenerationParameterOverrides(modelScope)).toBeUndefined();
    expect(exportGenerationParameterSyncPayload().records).toEqual([]);

    const newerRemote = structuredClone(sameVersionRemote);
    newerRemote.records[0]!.revision += 1;
    newerRemote.records[0]!.mutationId = 'remote-new-fact';
    newerRemote.records[0]!.values = { temperature: valueOverride(0.9) };
    mergeGenerationParameterSyncPayload(newerRemote);
    expect(loadGenerationParameterOverrides(modelScope)?.temperature).toEqual(valueOverride(0.9));
    const afterNewFact = JSON.parse(localStorage.getItem(key)!) as typeof stored;
    expect(afterNewFact.scopes[0]!.updatedAt).toBeGreaterThan(expiredAt);
  });

  it('reads the shared v1 sync fixture and round-trips import and export', () => {
    expect(syncFixture.schemaVersion).toBe(1);
    const merged = mergeGenerationParameterSyncPayload(syncFixture.payload);
    expect(exportGenerationParameterSyncPayload()).toEqual(merged);
    expect(JSON.parse(exportGenerationParameterSettingsJSON())).toEqual(merged);
  });

  // -- ID case round-trip -------------------------------------------------

  it('still reads settings locally after export, merge and write-back, so lowercase wire ids cannot pollute the local uppercase canonical form', () => {
    const scope = { providerId: UPPER_PROVIDER, modelId: 'gpt-test' };
    saveGenerationParameterOverrides(scope, { temperature: valueOverride(0.4) });
    saveConnectionGenerationParameterDefaults(UPPER_PROVIDER, { top_p: valueOverride(0.8) });
    saveGenerationParameterOverrides(
      { ...scope, conversationId: UPPER_CONVERSATION },
      { top_k: valueOverride(40) },
    );

    // Take the wire payload through the production export path, then feed it back verbatim into the production merge path, as convergeRemote does.
    const wire = exportGenerationParameterSyncPayload();
    expect(wire.records.every((record) => record.providerId === UPPER_PROVIDER.toLowerCase())).toBe(true);
    expect(wire.records.every((record) => record.recordId === record.recordId.toLowerCase())).toBe(true);

    mergeGenerationParameterSyncPayload(wire);

    // Looking it up with the real uppercase provider.id after write-back must still hit.
    expect(loadGenerationParameterOverrides(scope)?.temperature).toEqual(valueOverride(0.4));
    expect(loadConnectionGenerationParameterDefaults(UPPER_PROVIDER)?.top_p).toEqual(valueOverride(0.8));
    expect(resolveGenerationParameterOverrides({
      providerId: UPPER_PROVIDER,
      modelId: 'gpt-test',
      conversationId: UPPER_CONVERSATION,
    })).toEqual({
      top_k: valueOverride(40),
      temperature: valueOverride(0.4),
      top_p: valueOverride(0.8),
    });
  });

  it('reconciles recordId across clients: a recordId derived from an uppercase provider UUID is byte-identical to the shared fixture', () => {
    // Tombstones carry the canonical cases: they do not switch bucket on a `preset:` prefix, so one loop covers every shape.
    for (const testCase of syncFixture.idCasing.canonicalCases) {
      const merged = mergeGenerationParameterSyncPayload({
        schemaVersion: 1,
        records: [],
        presets: [],
        tombstones: [{ recordId: testCase.input, revision: 1, mutationId: 'device-canonical' }],
      });
      expect(merged.tombstones.map((item) => item.recordId), testCase.caseId).toEqual([testCase.canonical]);
      localStorage.clear();
    }

    for (const testCase of syncFixture.idCasing.recordIdCases) {
      if (testCase.scope === 'connection_default') {
        saveConnectionGenerationParameterDefaults(testCase.providerId, { temperature: valueOverride(0.5) });
      } else {
        saveGenerationParameterOverrides({
          providerId: testCase.providerId,
          modelId: testCase.modelId!,
          ...(testCase.conversationId ? { conversationId: testCase.conversationId } : {}),
        }, { temperature: valueOverride(0.5) });
      }
      const exported = exportGenerationParameterSyncPayload().records;
      expect(exported.map((record) => record.recordId), testCase.caseId).toEqual([testCase.recordId]);
      localStorage.clear();
    }
  });

  it('merges an existing remote uppercase recordId with the local lowercase record into one, and lets a tombstone block revival', () => {
    const scope = { providerId: UPPER_PROVIDER, modelId: 'gpt-test' };
    saveGenerationParameterOverrides(scope, { temperature: valueOverride(0.4) });
    const canonicalRecordId = exportGenerationParameterSyncPayload().records[0]!.recordId;
    const legacyRecordId = `scope:model:${UPPER_PROVIDER}:gpt-test`;
    expect(legacyRecordId).not.toBe(canonicalRecordId);

    // The remote is an existing record written by an older web client with an uppercase recordId and provider id.
    const merged = mergeGenerationParameterSyncPayload({
      schemaVersion: 1,
      records: [{
        recordId: legacyRecordId,
        scope: 'model_default',
        providerId: UPPER_PROVIDER,
        modelId: 'gpt-test',
        values: { temperature: valueOverride(0.9) },
        revision: 5,
        mutationId: 'device-legacy',
      }],
      presets: [],
      tombstones: [],
    });
    expect(merged.records).toHaveLength(1);
    expect(merged.records[0]!.recordId).toBe(canonicalRecordId);
    expect(loadGenerationParameterOverrides(scope)?.temperature).toEqual(valueOverride(0.9));

    // A tombstone with an existing uppercase recordId must also suppress a record that has already been canonicalized.
    const deleted = mergeGenerationParameterSyncPayload({
      schemaVersion: 1,
      records: [],
      presets: [],
      tombstones: [{ recordId: legacyRecordId, revision: 6, mutationId: 'device-legacy-delete' }],
    });
    expect(deleted.records).toEqual([]);
    expect(loadGenerationParameterOverrides(scope)).toBeUndefined();

    // An old device replaying an old revision with an uppercase recordId must not revive it.
    const replay = mergeGenerationParameterSyncPayload({
      schemaVersion: 1,
      records: [{
        recordId: legacyRecordId,
        scope: 'model_default',
        providerId: UPPER_PROVIDER,
        modelId: 'gpt-test',
        values: { temperature: valueOverride(0.9) },
        revision: 5,
        mutationId: 'device-legacy',
      }],
      presets: [],
      tombstones: [],
    });
    expect(replay.records).toEqual([]);
  });
});
