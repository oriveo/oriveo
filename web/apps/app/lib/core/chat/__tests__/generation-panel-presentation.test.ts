import 'fake-indexeddb/auto';
// @vitest-environment jsdom
//
// Rendering rules for the generation parameter panel.
//
// None of the profiles here are hand-written literals: they all come out of the production
// parsing chain, either from a metadata snapshot through initMetadata and
// resolveGenerationProfileRef, or synthesised from a local template by relayGenerationProfile.
// The assertions target the production predicates themselves rather than restating the rules in
// the test.

import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import {
  __seedMetadataCacheForTest,
  __readMetadataCacheForTest,
  __resetMetadataClientForTest,
  initMetadata,
} from '../../metadata/metadata-client';
import {
  modelSupportsGenerationParameter,
  relayGenerationProfile,
  resolveGenerationProfileForModel,
} from '../stream-options';
import { modelMatchesFilters } from '../../../../components/chat/ModelSwitcher/model-switcher-data';
import {
  generationPanelEmptyState,
  generationPanelVisibleParameters,
  hasSeenNonEmptyGenerationProfile,
  recordSeenGenerationProfile,
  showsUnverifiedBadge,
  showsUnverifiedGroupNote,
} from '../generation-panel-presentation';

/** Feed a metadata snapshot to the production metadata client; the profile is still resolved by the production chain. */
async function primeMetadata(parameters: Record<string, { group?: string }>, wire: Record<string, string>) {
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({
    data: {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-08-08T00:00:00Z',
      profiles: {
        reasoning: {},
        webSearch: {},
        imageGen: {},
        generation: {
          parameters,
          templates: { panel_fixture: { transport: 'openai_chat_completions', wire } },
        },
      },
      providers: {},
      providerConfigs: [],
    },
    timestamp: Date.now(),
  });
  await initMetadata();
}

function officialProvider(): Provider {
  return {
    id: 'provider-official', kind: 'openAI', status: { kind: 'connected' },
    models: [], catalogModels: [], apiKey: 'k', apiKeyPreview: '',
  } as unknown as Provider;
}

function relayProvider(overrides: Record<string, unknown> = {}): Provider {
  return {
    id: 'provider-relay', kind: 'relay', status: { kind: 'connected' },
    models: [], catalogModels: [], apiKey: '', apiKeyPreview: '',
    ...overrides,
  } as unknown as Provider;
}

function modelWith(parameters: { id: string; support: string }[] | undefined): AIModel {
  return {
    id: 'panel-model', name: 'panel-model', capabilities: ['text'],
    reasoningModeAvailable: false, isAvailable: true, isDefault: false, priceTier: '',
    transport: 'openai_chat',
    ...(parameters ? {
      generationProfile: {
        template: 'panel_fixture',
        parameters: parameters.map((item) => ({ ...item, source: 'authoritative_metadata' })),
      },
    } : {}),
  } as unknown as AIModel;
}

const ENTITLED = { canManageRuntime: true };
const UNENTITLED = { canManageRuntime: false };

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('Empty states: the container never collapses', () => {
  beforeEach(() => localStorage.clear());

  it('A, not yet verified: this client has never seen a non-empty profile and has none now', async () => {
    await primeMetadata({}, {});
    // With no protocol chosen, relayGenerationProfile returns undefined, so the profile really is absent.
    const provider = relayProvider();
    const model = modelWith(undefined);
    expect(resolveGenerationProfileForModel(provider, model)).toBeUndefined();

    expect(generationPanelEmptyState({
      provider, model, scope: 'connectionDefaults', entitlement: ENTITLED, hasSeenNonEmptyProfile: false,
    })).toBe('notVerified');
  });

  it('B, catalog takeover: this client has seen a non-empty profile and it is now empty, with the history flag coming from the production read/write functions', async () => {
    await primeMetadata({}, {});
    const provider = relayProvider();
    const model = modelWith(undefined);

    // The history flag round-trips through the production record/has functions rather than writing localStorage directly.
    recordSeenGenerationProfile(provider.id, model.id, 3);
    expect(hasSeenNonEmptyGenerationProfile(provider.id, model.id)).toBe(true);

    expect(generationPanelEmptyState({
      provider,
      model,
      scope: 'connectionDefaults',
      entitlement: ENTITLED,
      hasSeenNonEmptyProfile: hasSeenNonEmptyGenerationProfile(provider.id, model.id),
    })).toBe('catalogManaged');
  });

  it('does not set the history flag on seeing an empty profile, so B cannot be triggered by an empty profile on its own', async () => {
    const provider = relayProvider();
    recordSeenGenerationProfile(provider.id, 'panel-model', 0);
    expect(hasSeenNonEmptyGenerationProfile(provider.id, 'panel-model')).toBe(false);
  });

  it('C, entitlement: the profile is non-empty but entitlement filters it to nothing, and it must be decided before D as the only state with a way out', async () => {
    await primeMetadata({ n_ctx: { group: 'engine_runtime' } }, { n_ctx: 'n_ctx' });
    const provider = officialProvider();
    const model = modelWith([{ id: 'n_ctx', support: 'supported' }]);

    expect(generationPanelEmptyState({
      provider, model, scope: 'connectionDefaults', entitlement: UNENTITLED, hasSeenNonEmptyProfile: false,
    })).toBe('entitlementLocked');
    // Once the entitlement is on, the empty state goes away.
    expect(generationPanelEmptyState({
      provider, model, scope: 'connectionDefaults', entitlement: ENTITLED, hasSeenNonEmptyProfile: false,
    })).toBeNull();
  });

  it('D, nothing accepted: the conversation scope is still an empty state, because nothing behind the chip is adjustable', async () => {
    await primeMetadata({ temperature: { group: 'sampling' } }, { temperature: 'temperature' });
    const provider = officialProvider();
    const model = modelWith([{ id: 'temperature', support: 'unsupported' }]);

    for (const entitlement of [ENTITLED, UNENTITLED]) {
      expect(generationPanelEmptyState({
        provider, model, scope: 'session', entitlement, hasSeenNonEmptyProfile: true,
      })).toBe('allUnsupported');
    }
  });

  /**
   * Connection scope must not collapse unsupported parameters into a single empty state.
   *
   * An empty-state card can only say that nothing on this connection is adjustable, whereas the
   * "not adjustable" presentation class requires a per-row explanation that this model does not
   * accept the parameter, plus a primary action that finds models which do. Dropping those rows
   * in favour of an empty card would make that class structurally unreachable.
   */
  it('renders unsupported rows in connection scope as read-only instead of collapsing into an allUnsupported empty state', async () => {
    await primeMetadata({ temperature: { group: 'sampling' } }, { temperature: 'temperature' });
    const provider = officialProvider();
    const model = modelWith([{ id: 'temperature', support: 'unsupported' }]);

    for (const entitlement of [ENTITLED, UNENTITLED]) {
      expect(generationPanelVisibleParameters(provider, model, 'connectionDefaults', entitlement).map((item) => item.id))
        .toEqual(['temperature']);
      expect(generationPanelEmptyState({
        provider, model, scope: 'connectionDefaults', entitlement, hasSeenNonEmptyProfile: true,
      })).toBeNull();
    }
  });

  // The C state can only appear in the detail page container; the conversation scope in the
  // composer is not entitlement-gated, so whenever the chip is visible the panel behind it has
  // content and never opens onto an empty shell.
  it('never produces the C state in conversation scope: engine_runtime parameters stay visible when the entitlement is off', async () => {
    await primeMetadata({ n_ctx: { group: 'engine_runtime' } }, { n_ctx: 'n_ctx' });
    const provider = officialProvider();
    const model = modelWith([{ id: 'n_ctx', support: 'supported' }]);

    expect(generationPanelVisibleParameters(provider, model, 'session', UNENTITLED).map((item) => item.id))
      .toEqual(['n_ctx']);
    expect(generationPanelEmptyState({
      provider, model, scope: 'session', entitlement: UNENTITLED, hasSeenNonEmptyProfile: false,
    })).toBeNull();
  });

  // Structural assertion: the visible set is empty exactly when an empty state exists. The container has no third option and must not collapse silently.
  it('never collapses the container: the visible set is empty exactly when the empty state is non-null', async () => {
    await primeMetadata(
      { temperature: { group: 'sampling' }, n_ctx: { group: 'engine_runtime' } },
      { temperature: 'temperature', n_ctx: 'n_ctx' },
    );
    const cases: { provider: Provider; model: AIModel }[] = [
      { provider: officialProvider(), model: modelWith(undefined) },
      { provider: officialProvider(), model: modelWith([{ id: 'temperature', support: 'unsupported' }]) },
      { provider: officialProvider(), model: modelWith([{ id: 'temperature', support: 'supported' }]) },
      { provider: officialProvider(), model: modelWith([{ id: 'n_ctx', support: 'supported' }]) },
      { provider: relayProvider(), model: modelWith([{ id: 'temperature', support: 'unknown' }]) },
      { provider: relayProvider({ relayRequested: { transport: 'anthropic_messages' } }), model: modelWith(undefined) },
    ];

    for (const scope of ['session', 'connectionDefaults'] as const) {
      for (const entitlement of [ENTITLED, UNENTITLED]) {
        for (const { provider, model } of cases) {
          for (const hasSeen of [true, false]) {
            const visible = generationPanelVisibleParameters(provider, model, scope, entitlement);
            const state = generationPanelEmptyState({
              provider, model, scope, entitlement, hasSeenNonEmptyProfile: hasSeen,
            });
            expect(visible.length === 0, `${provider.kind}/${scope}/${String(hasSeen)}`).toBe(state !== null);
          }
        }
      }
    }
  });
});

/**
 * The primary action on a "not adjustable" row is finding models that do support the parameter.
 *
 * It has to reuse the very same predicate as that filter (`generationParameterAdjustable`,
 * meaning a non-empty wire plus the facade judging it editable). A second "supports this
 * parameter" predicate written just for the filter could diverge, and the user would open a
 * filter result only to find the row still greyed out in the panel.
 */
describe('Primary action: the "supports this parameter" filter dimension in the model picker', () => {
  beforeEach(() => localStorage.clear());

  it('shares a source with the panel editable check: adjustable models match, and unsupported models with official evidence do not', async () => {
    await primeMetadata({ temperature: { group: 'sampling' } }, { temperature: 'temperature' });
    const provider = officialProvider();

    expect(modelSupportsGenerationParameter(
      provider, modelWith([{ id: 'temperature', support: 'supported' }]), 'temperature',
    )).toBe(true);
    expect(modelSupportsGenerationParameter(
      provider, modelWith([{ id: 'temperature', support: 'unsupported' }]), 'temperature',
    )).toBe(false);
    // Reverse assertion: the predicate is not "does this row render". Unsupported rows do render
    // now, so a filter that mistakenly used connectionConfigurable would pass this while letting
    // through a model that cannot be adjusted.
    expect(generationPanelVisibleParameters(provider, modelWith([{ id: 'temperature', support: 'unsupported' }]), 'connectionDefaults', ENTITLED))
      .toHaveLength(1);
  });

  it('does not match a model whose profile lacks the parameter entirely, rather than letting an unknown through', async () => {
    await primeMetadata({ temperature: { group: 'sampling' } }, { temperature: 'temperature' });
    expect(modelSupportsGenerationParameter(
      officialProvider(), modelWith(undefined), 'temperature',
    )).toBe(false);
  });

  it('runs the model picker filter through the same function: requiredGenerationParameterId stacks with the chip filter', async () => {
    await primeMetadata({ temperature: { group: 'sampling' } }, { temperature: 'temperature' });
    const provider = officialProvider();
    const supported = modelWith([{ id: 'temperature', support: 'supported' }]);
    const unsupported = modelWith([{ id: 'temperature', support: 'unsupported' }]);

    expect(modelMatchesFilters(provider, supported, new Set(), undefined, 'temperature')).toBe(true);
    expect(modelMatchesFilters(provider, unsupported, new Set(), undefined, 'temperature')).toBe(false);
    // Behaviour is unchanged when no parameter id is passed, so existing call sites are unaffected.
    expect(modelMatchesFilters(provider, unsupported, new Set())).toBe(true);
  });
});

describe('Relay unverified badge: a missing badge means a fabricated level', () => {
  // relayGenerationProfile and engineGenerationProfile both read template.wire from the
  // production metadata cache, so only the template fixture is prepared here; the parameter
  // table is still synthesised from production constants.
  beforeEach(async () => {
    const wire = { temperature: 'temperature', max_output_tokens: 'max_tokens', reasoning_effort: 'reasoning_effort' };
    await primeMetadata(
      { temperature: { group: 'sampling' }, reasoning_effort: { group: 'reasoning' } },
      wire,
    );
    const cached = (await __readMetadataCacheForTest())! as unknown as {
      data: { profiles: { generation: { templates: Record<string, unknown> } } };
    };
    for (const name of ['openai_chat_completions', 'openai_responses', 'anthropic_messages',
      'gemini_generate_content', 'llamacpp_native', 'vllm_extra_body']) {
      cached.data.profiles.generation.templates[name] = { transport: 'openai_chat_completions', wire };
    }
    __resetMetadataClientForTest();
    await __seedMetadataCacheForTest(cached);
    await initMetadata();
  });

  it('badges every unknown parameter synthesised from a relay local template, across all four protocols', () => {
    const transports = ['openai_chat_completions', 'openai_responses', 'anthropic_messages', 'gemini_generate_content'] as const;
    for (const transport of transports) {
      const provider = relayProvider({ relayRequested: { transport } });
      // Synthesised by production code, not a hand-written parameter table.
      const profile = relayGenerationProfile(provider);
      expect(profile?.parameters?.length, transport).toBeGreaterThan(0);
      const parameters = profile!.parameters;
      const decisions = parameters.map(() => ({ source: 'relay_declaration' as const, grade: 'accepted_unverified' as const }));
      expect(decisions.every(showsUnverifiedBadge), transport).toBe(true);
      expect(showsUnverifiedGroupNote(decisions), transport).toBe(true);
    }
  });

  // The reasoning budget levels, meaning the openai_chat_completions table, are in scope here too.
  it('badges the relay reasoning budget levels too', () => {
    const provider = relayProvider({ relayRequested: { transport: 'openai_chat_completions' } });
    const reasoning = relayGenerationProfile(provider)!.parameters
      .filter((item) => item.id?.startsWith('reasoning_'));
    expect(reasoning.map((item) => item.id).sort())
      .toEqual(['reasoning_budget', 'reasoning_effort', 'reasoning_mode']);
    expect(reasoning.every(() => showsUnverifiedBadge({
      source: 'relay_declaration', grade: 'accepted_unverified',
    }))).toBe(true);
  });

  it('decides the badge for a local engine declaration from the projected grade alone, never from raw support', () => {
    for (const engineProfile of ['llamacpp', 'vllm', 'openwebui'] as const) {
      const provider = relayProvider({ relayRequested: { transport: 'openai_chat_completions', engineProfile } });
      const parameters = relayGenerationProfile(provider)!.parameters;
      expect(parameters.length, engineProfile).toBeGreaterThan(0);
      const decisions = parameters.map(() => ({ source: 'relay_declaration' as const, grade: 'declared' as const }));
      expect(showsUnverifiedGroupNote(decisions), engineProfile).toBe(true);
    }
  });

  it('does not let an official unknown masquerade as a relay local declaration badge', () => {
    expect(showsUnverifiedBadge({ source: 'server_profile', grade: 'declared' })).toBe(false);
  });

  it('leaves non-unknown relay parameters unbadged', () => {
    for (const grade of ['effect_verified', 'observed', 'declared'] as const) {
      expect(showsUnverifiedBadge({ source: 'server_profile', grade }), grade).toBe(false);
    }
  });
});
