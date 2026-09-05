import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Per-field revalidation, dormant state, and how scoped records are handled after a transport
// correction.
//
// No profile object is hand-written in this file. Profiles always come from the production
// resolution chain (metadata fixture -> `resolveGenerationProfileRef` -> `relayGenerationProfile`),
// stored values always come from the production writer `saveGenerationParameterOverrides`, and
// the final body comes from the production relay send path.

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { sendRelayStream, type RelayOrchestratorDeps } from '@oriveo/core/providers/relay-orchestrator';
import {
  __seedMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../../metadata/metadata-client';
import { buildProviderStreamOptions, buildStreamOptionsFromIntent, resolveGenerationProfileForModel } from '../stream-options';
import {
  activeGenerationParameterIds,
  partitionGenerationParameterValues,
} from '../generation-parameter-lifecycle';
import {
  applyGenerationParameterPreset,
  generationParameterProfileFingerprint,
  listGenerationParameterPresets,
  loadGenerationParameterOverrides,
  resolveGenerationParameterOverrides,
  saveGenerationParameterOverrides,
  saveGenerationParameterPreset,
  valueOverride,
} from '../generation-parameter-settings';
import { beginCapabilityEvidenceIdentityIfAbsent } from '../../providers/capability-evidence-identity';

const contract = JSON.parse(readFileSync(resolve(
  process.cwd(),
  '../../..',
  'shared/model-contracts/generation_parameter_contract.v1.json',
), 'utf8')) as {
  lifecycleRules: { outboundParity: string; lifecycle: string[]; presets: string[] };
  lifecycleCases: {
    caseId: string;
    intent: {
      providerKind: string;
      parameterId: string;
      declared: boolean;
      storedState: 'value' | 'omit';
      support?: string;
      wire?: string;
    };
    expect: { lifecycle: 'active' | 'dormant' };
  }[];
};

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-08-08T00:00:00Z',
  profiles: {
    reasoning: {},
    webSearch: {},
    imageGen: {},
    generation: {
      parameters: {
        temperature: { group: 'sampling', valueSchema: 'number', portability: 'portable' },
        max_output_tokens: { group: 'budget', valueSchema: 'integer', portability: 'portable' },
        frequency_penalty: { group: 'repetition', valueSchema: 'number', portability: 'transport_scoped' },
        top_k: { group: 'sampling', valueSchema: 'integer', portability: 'engine_scoped' },
      },
      templates: {
        openai_chat_completions: {
          transport: 'openai_chat_completions',
          wire: {
            temperature: 'temperature',
            max_output_tokens: 'max_tokens',
            frequency_penalty: 'frequency_penalty',
            top_k: 'top_k',
          },
        },
        anthropic_messages: {
          transport: 'anthropic_messages',
          wire: { temperature: 'temperature', max_output_tokens: 'max_tokens', top_k: 'top_k' },
        },
      },
    },
  },
  providers: {},
  providerConfigs: [],
};

function relayProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'relay-p5b',
    kind: 'relay',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-relay',
    apiKeyPreview: '••',
    baseURLText: 'https://relay.example/v1',
    relayRequested: { transport: 'openai_chat_completions' },
    ...overrides,
  } as Provider;
}

const model = {
  id: 'my-private-model',
  name: 'my-private-model',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: false,
  priceTier: '',
} as AIModel;

function scopeOf(provider: Provider) {
  return {
    providerId: provider.id,
    modelId: model.id,
    profileFingerprint: generationParameterProfileFingerprint(provider, model),
  };
}

/** Hand production StreamOptions to the production relay send path and capture the body actually sent. */
async function outboundBody(provider: Provider, options: ReturnType<typeof buildProviderStreamOptions>) {
  let captured: Record<string, unknown> | undefined;
  const deps: RelayOrchestratorDeps = {
    transport: {
      fetch: async (_url, init) => {
        captured = JSON.parse(String(init.body)) as Record<string, unknown>;
        return new Response(JSON.stringify({ choices: [{ message: { content: 'ok' } }] }), { status: 200 });
      },
    },
    buildFetchArgs: (url, headers) => ({ url, headers }),
    getRelayRuntimeConfig: () => null,
  };
  const handle = sendRelayStream(
    'sk-relay',
    model.id,
    [{ role: 'user', content: 'hello' }],
    provider.baseURLText,
    { ...options, relayStream: false },
    deps,
  );
  await handle.stream.getReader().read();
  expect(captured, 'the production relay send path issued no request').toBeDefined();
  return captured!;
}

beforeEach(async () => {
  localStorage.clear();
  beginCapabilityEvidenceIdentityIfAbsent('guest', 'relay-p5b');
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({
    data: METADATA_FIXTURE,
    timestamp: Date.now(),
  });
  await initMetadata();
});

describe('lifecycleCases consumed by production conditions', () => {
  it('keeps production coverage of active and dormant in the shared lifecycleCases contract', () => {
    expect(contract.lifecycleCases.length).toBeGreaterThanOrEqual(14);
    expect(contract.lifecycleCases.some((item) => item.expect.lifecycle === 'active')).toBe(true);
    expect(contract.lifecycleCases.some((item) => item.expect.lifecycle === 'dormant')).toBe(true);
  });

  it('lifecycleRules share the outbound gate: the active set equals the parameters a production profile really sends', () => {
    const provider = relayProvider();
    // Profiles all come from the production resolution chain; nothing is hand-written here.
    const profile = resolveGenerationProfileForModel(provider, model)!;
    const declared = profile.parameters.map((parameter) => parameter.id!);
    const active = activeGenerationParameterIds(provider, model, Object.fromEntries(
      declared.map((id) => [id, valueOverride(1)]),
    ));

    // The local relay template yields all unknown with a complete wire mapping, so by the documented exception they are all active.
    expect(declared.length).toBeGreaterThan(0);
    for (const id of declared) {
      expect(active.has(id), id).toBe(Boolean(profile.wire[id]));
    }
  });

  it('profiles.generation remains authoritative when legacy generation candidates disagree', () => {
    const provider = relayProvider();
    const unsupportedModel: AIModel = {
      ...model,
      capabilityEvidenceCandidates: [
        {
          key: 'generation_parameter/temperature', support: 'unsupported', source: 'operator_override', grade: 'operator',
          scope: 'provider_model_transport', providerKind: 'relay', modelId: model.id,
          transport: 'openai_chat',
        },
        {
          key: 'generation_parameter/temperature', support: 'unknown', source: 'runtime_observation', grade: 'observed',
          scope: 'provider_model_transport', providerKind: 'relay', modelId: model.id,
          transport: 'openai_chat', policy: 'runtime_rejected',
        },
      ],
    };
    expect(activeGenerationParameterIds(provider, unsupportedModel, {
      temperature: valueOverride(0.4),
    })).toContain('temperature');
  });

  it('a malformed capability namespace cannot poison the generation profile matrix', () => {
    const malformedModel: AIModel = { ...model, capabilityEvidenceViewMalformed: true };
    expect(activeGenerationParameterIds(relayProvider(), malformedModel, {
      temperature: valueOverride(0.4),
    })).toContain('temperature');
  });
});

describe('per-parameter revalidation by id after a profile change', () => {
  it('keeps compatible values in effect, turns incompatible ones dormant, and silently replaces neither', () => {
    const before = relayProvider();
    saveGenerationParameterOverrides(scopeOf(before), {
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });

    // Runtime probing corrects transport from one concrete value to another, which is the real window here.
    const after = relayProvider({ relayResolvedTransport: 'anthropic_messages' });
    expect(generationParameterProfileFingerprint(after, model))
      .not.toBe(generationParameterProfileFingerprint(before, model));

    // 1. The record must still read back - exactly what an all-or-nothing record-level invalidation loses.
    const stored = loadGenerationParameterOverrides(scopeOf(after));
    expect(stored).toEqual({
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });

    // 2. Per-field decision: temperature is still in the anthropic template, frequency_penalty is not.
    const partition = partitionGenerationParameterValues({ provider: after, model, values: stored! });
    expect(partition.active).toEqual({ temperature: valueOverride(0.4) });
    expect(partition.dormantIds).toEqual(['frequency_penalty']);
    // 3. No silent substitution: the dormant value is kept as-is and not clamped to something else.
    expect(partition.dormant.frequency_penalty).toEqual(valueOverride(0.5));
  });

  it('restores compatible values automatically once the profile matches again, with no user action', () => {
    const before = relayProvider();
    saveGenerationParameterOverrides(scopeOf(before), {
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });

    const corrected = relayProvider({ relayResolvedTransport: 'anthropic_messages' });
    expect(partitionGenerationParameterValues({
      provider: corrected, model, values: loadGenerationParameterOverrides(scopeOf(corrected))!,
    }).dormantIds).toEqual(['frequency_penalty']);

    // Transport is corrected back, by switching upstream back or by a re-probe: the value was never deleted, so it returns as soon as the condition changes.
    const restored = relayProvider({ relayResolvedTransport: 'openai_chat_completions' });
    const partition = partitionGenerationParameterValues({
      provider: restored, model, values: loadGenerationParameterOverrides(scopeOf(restored))!,
    });
    expect(partition.dormantIds).toEqual([]);
    expect(partition.active).toEqual({
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });
  });
});

describe('preset identity carries no profile fingerprint and values are handled per field', () => {
  it('still lists and applies a preset after a protocol change', () => {
    const before = relayProvider();
    const preset = saveGenerationParameterPreset({
      name: 'Precise',
      ...scopeOf(before),
      values: { temperature: valueOverride(0.4), frequency_penalty: valueOverride(0.5) },
    });
    // The fingerprint really did change, which is the case a record-level invalidation would drop entirely.
    const after = relayProvider({ relayResolvedTransport: 'anthropic_messages' });
    expect(generationParameterProfileFingerprint(after, model)).not.toBe(preset.profileFingerprint);

    expect(listGenerationParameterPresets(scopeOf(after)).map((item) => item.id)).toEqual([preset.id]);
    expect(applyGenerationParameterPreset(preset, scopeOf(after))).toEqual({
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });
  });

  it('never trims by the local active decision when saving or applying: dormant values stay and go out again once the profile returns', async () => {
    const after = relayProvider({ relayResolvedTransport: 'anthropic_messages' });
    // The panel's current values come from the production write and read chain, and the production partition decides which are dormant; the test does not decide that itself.
    saveGenerationParameterOverrides(scopeOf(after), {
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });
    const panelValues = loadGenerationParameterOverrides(scopeOf(after))!;
    const partition = partitionGenerationParameterValues({ provider: after, model, values: panelValues });
    expect(partition.dormantIds).toEqual(['frequency_penalty']);

    const preset = saveGenerationParameterPreset({ name: 'Precise', ...scopeOf(after), values: panelValues });
    // Trimming dormant values would let one device's profile switch a value off for another device.
    expect(preset.values.frequency_penalty).toEqual(valueOverride(0.5));

    const restored = relayProvider({ relayResolvedTransport: 'openai_chat_completions' });
    const applied = applyGenerationParameterPreset(preset, scopeOf(restored))!;
    saveGenerationParameterOverrides(scopeOf(restored), applied);
    const resolved = resolveGenerationParameterOverrides({
      ...scopeOf(restored),
      reasoningMode: 'automatic',
      activeParameterIds: activeGenerationParameterIds(restored, model, applied),
    });
    const body = await outboundBody(restored, buildProviderStreamOptions(
      restored,
      buildStreamOptionsFromIntent(model, 'automatic', false, resolved),
      model,
    ));
    expect(body.frequency_penalty).toBe(0.5);
  });

  it('still maps only portable semantics across models', () => {
    const provider = relayProvider();
    const preset = saveGenerationParameterPreset({
      name: 'Precise',
      ...scopeOf(provider),
      values: { temperature: valueOverride(0.4) },
    });
    const otherModel = { providerId: provider.id, modelId: 'another-model' };
    expect(applyGenerationParameterPreset(preset, otherModel)).toBeUndefined();
    expect(listGenerationParameterPresets({ ...otherModel, portableParameterIds: ['top_p'] })).toEqual([]);
    expect(applyGenerationParameterPreset(preset, otherModel, { temperature: 'temperature' }))
      .toEqual({ temperature: valueOverride(0.4) });
  });
});

describe('handling of old scoped records after relayResolvedTransport is corrected at runtime', () => {
  it('migrates old records to the new scope with per-field decisions and never sends dormant values', async () => {
    const before = relayProvider();
    saveGenerationParameterOverrides(scopeOf(before), {
      temperature: valueOverride(0.4),
      frequency_penalty: valueOverride(0.5),
    });

    const after = relayProvider({ relayResolvedTransport: 'anthropic_messages' });
    const resolved = resolveGenerationParameterOverrides({
      ...scopeOf(after),
      reasoningMode: 'automatic',
      activeParameterIds: activeGenerationParameterIds(after, model, loadGenerationParameterOverrides(scopeOf(after))),
    });
    // Dormant values are already blocked during evaluation rather than relying on a downstream drop (the conflicts/requires assertions run before anything is dropped).
    expect(resolved).toEqual({ temperature: valueOverride(0.4) });

    const streamOptions = buildProviderStreamOptions(
      after,
      buildStreamOptionsFromIntent(model, 'automatic', false, resolved),
      model,
    );
    const body = await outboundBody(after, streamOptions);
    expect(body.temperature).toBe(0.4);
    expect(body.frequency_penalty).toBeUndefined();
  });

  it('merges old fingerprint records into one after saving to the new scope, leaving no remnants', () => {
    const before = relayProvider();
    saveGenerationParameterOverrides(scopeOf(before), { temperature: valueOverride(0.4) });

    const after = relayProvider({ relayResolvedTransport: 'anthropic_messages' });
    saveGenerationParameterOverrides(scopeOf(after), { temperature: valueOverride(0.9) });

    const raw = JSON.parse(localStorage.getItem('oriveo.guest.generation-parameter-settings.v1')!) as {
      scopes: { providerId: string; modelId?: string; profileFingerprint?: string }[];
    };
    const mine = raw.scopes.filter((item) => item.providerId === before.id && item.modelId === model.id);
    expect(mine).toHaveLength(1);
    expect(mine[0].profileFingerprint).toBe(generationParameterProfileFingerprint(after, model));
    expect(loadGenerationParameterOverrides(scopeOf(before))).toEqual({ temperature: valueOverride(0.9) });
  });
});
