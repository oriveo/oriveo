// @vitest-environment jsdom
//
// The outbound gate must ask whether the facade approves this send (requestPolicy) rather
// than whether the capability has been proven supported, because the latter always turns
// "we do not know" into "no".
// It also pins the explicitKeys wiring: turning on web search or picking a reasoning level
// in the composer is an explicit statement of intent, so the query must carry
// hasExplicitValue, or the rule is a no-op here.

import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { CapabilityEvidenceCandidate } from '@oriveo/core/providers/capability-evidence-facade';

vi.mock('../../metadata/metadata-client', () => ({
  resolveCatalogModel: () => null,
  getMetadataRevision: () => undefined,
  getRelayRuntimeConfig: () => undefined,
  resolveGenerationProfileRef: () => undefined,
  // In production the reasoning levels of the 15 official models come from a legacy profile sent by the server.
  getDeclaredReasoningLevels: () => ['fast', 'balanced', 'deep'],
  getDeclaredReasoningDefaultLevel: () => undefined,
}));

vi.mock('../../../infra/storage/partition', () => ({ getActiveUIDSync: () => 'uid-1' }));

import { filterRequestCapabilityIntent } from '../stream-options';
import { recordCapabilityRejection } from '../capability-recovery-runtime';

function officialProvider(): Provider {
  return {
    id: 'provider-1', kind: 'openAI', status: { kind: 'connected' },
    models: [], catalogModels: [], apiKey: 'sk', apiKeyPreview: '••',
  } as unknown as Provider;
}

function officialModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-5.4', name: 'GPT-5.4', capabilities: ['text'],
    reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: '$',
    transport: 'openai_chat',
    // In production 257 combinations are official_source_insufficient: there is simply no information about that capability.
    ...overrides,
  } as unknown as AIModel;
}

function unsupportedCandidate(key: string): CapabilityEvidenceCandidate {
  return {
    key,
    support: 'unsupported',
    source: 'server_typed',
    grade: 'machine_verified',
    scope: 'provider_model_transport',
    providerKind: 'openAI',
    modelId: 'gpt-5.4',
    transport: 'openai_chat',
  };
}

describe('filterRequestCapabilityIntent: the outbound gate consumes requestPolicy', () => {
  it('custom source rejection cannot suppress the same-owner official recipe intent', () => {
    localStorage.clear();
    const identity = {
      connectionId: '00000000-0000-4000-8000-000000000001',
      canonicalModelId: 'gpt-5.4',
      finalTransport: 'openai_responses',
      runtimeRevision: 'runtime-r7',
    };
    recordCapabilityRejection(identity, {
      version: 1,
      action: 'user_confirmed_resend_without_located_setting',
      source: 'custom',
      owners: ['web'],
      locatedPointers: [],
    });
    const result = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model: officialModel(),
      reasoningMode: 'automatic',
      webSearchEnabled: true,
      streamOptions: {
        supportsWebSearch: true,
        capabilityPreferences: { web: 'automatic' },
        capabilityRecoveryIdentity: identity,
      },
    });
    expect(result.supportsWebSearch).toBe(true);
    expect(result.capabilityPreferences?.web).toBe('automatic');
  });

  it('recipe rejection is dormant on normal send and only an explicit resend latch re-enables its owner', () => {
    localStorage.clear();
    const identity = {
      connectionId: '00000000-0000-4000-8000-000000000001',
      canonicalModelId: 'gpt-5.4',
      finalTransport: 'openai_responses',
      runtimeRevision: 'runtime-r7',
    };
    recordCapabilityRejection(identity, {
      version: 1,
      action: 'user_confirmed_resend_without_located_setting',
      source: 'provider_recipe',
      owners: ['web'],
      locatedPointers: ['/web_search_options'],
      recipeRef: 'fixture.web.v1',
    });
    const input = {
      provider: officialProvider(),
      model: officialModel(),
      reasoningMode: 'automatic' as const,
      webSearchEnabled: true,
    };
    const dormant = filterRequestCapabilityIntent({
      ...input,
      streamOptions: {
        supportsWebSearch: true,
        capabilityPreferences: { web: 'automatic' },
        capabilityRecoveryIdentity: identity,
      },
    });
    expect(dormant.supportsWebSearch).toBe(false);
    expect(dormant.capabilityPreferences?.web).toBe('off');

    const explicit = filterRequestCapabilityIntent({
      ...input,
      streamOptions: {
        supportsWebSearch: true,
        capabilityPreferences: { web: 'automatic' },
        capabilityRecoveryIdentity: identity,
        capabilityRecipeResendOwners: ['web'],
      },
    });
    expect(explicit.supportsWebSearch).toBe(true);
    expect(explicit.capabilityPreferences?.web).toBe('automatic');
  });

  it('legacy branch: web search the user explicitly turned on is still sent when there is no evidence either way', () => {
    const result = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model: officialModel(),
      reasoningMode: 'automatic',
      webSearchEnabled: true,
      streamOptions: { supportsWebSearch: true },
    });
    expect(result.supportsWebSearch).toBe(true);
  });

  it('legacy branch: a reasoning level the user explicitly picked is still sent, proving explicitKeys is really wired', () => {
    const result = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model: officialModel(),
      reasoningMode: 'deep',
      webSearchEnabled: false,
      streamOptions: {},
    });
    expect(result.reasoning).toBe('deep');
  });

  it('both branches are equally strict: the typed branch also goes through the facade instead of passing unconditionally', () => {
    const model = officialModel({
      capabilityEvidenceCandidates: [unsupportedCandidate('web_search')],
    } as Partial<AIModel>);
    const typed = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model,
      reasoningMode: 'automatic',
      webSearchEnabled: true,
      streamOptions: { supportsWebSearch: true, capabilityPreferences: { web: 'automatic' } },
    });
    expect(typed.supportsWebSearch).toBe(false);
    // A rejected intent must not slip back into dispatch through capabilityPreferences.
    expect(typed.capabilityPreferences?.web).toBe('off');

    const legacy = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model,
      reasoningMode: 'automatic',
      webSearchEnabled: true,
      streamOptions: { supportsWebSearch: true },
    });
    expect(legacy.supportsWebSearch).toBe(false);
  });

  it('typed branch: a definite not-supported backed by official evidence still blocks the reasoning level', () => {
    const result = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model: officialModel({
        capabilityEvidenceCandidates: [unsupportedCandidate('reasoning_level/deep')],
      } as Partial<AIModel>),
      reasoningMode: 'automatic',
      webSearchEnabled: false,
      streamOptions: { capabilityPreferences: { web: 'off', reasoningIntent: 'deep' } },
    });
    expect(result.reasoning).toBeUndefined();
    expect(result.capabilityPreferences?.reasoningIntent).toBeUndefined();
  });

  it('typed branch: without evidence the typed intent is sent and passed through verbatim for dispatch to compile', () => {
    const result = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model: officialModel(),
      reasoningMode: 'automatic',
      webSearchEnabled: true,
      streamOptions: { supportsWebSearch: true, capabilityPreferences: { web: 'force', reasoningIntent: 'deep' } },
    });
    expect(result.supportsWebSearch).toBe(true);
    expect(result.capabilityPreferences).toEqual({ web: 'force', reasoningIntent: 'deep' });
    expect(result.reasoning).toBe('deep');
  });

  it('turning reasoning off is an instruction, not a capability request, so off is always passed through', () => {
    const result = filterRequestCapabilityIntent({
      provider: officialProvider(),
      model: officialModel({
        capabilityEvidenceCandidates: [unsupportedCandidate('reasoning_level/deep')],
      } as Partial<AIModel>),
      reasoningMode: 'automatic',
      webSearchEnabled: false,
      streamOptions: { capabilityPreferences: { web: 'off', reasoningIntent: 'off' } },
    });
    expect(result.capabilityPreferences?.reasoningIntent).toBe('off');
    expect(result.reasoning).toBeUndefined();
  });
});
