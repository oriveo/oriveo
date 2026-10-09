/**
 * Model options main pane view model: status mark, two-line header, capability card row order and exceptions, blocked explanation, empty exits, banner, and chips.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';

vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...await importOriginal<typeof import('../../metadata/metadata-client')>(),
  getCapabilityRuntime: () => null,
}));

import { capabilityRejectionState, recordCapabilityRejection } from '../capability-recovery-runtime';
import type { ModelOptionCapabilityInput } from '../model-option-capability-shape';
import { resolveGenerationParameterOverridesWithSources, saveGenerationParameterOverrides } from '../generation-parameter-settings';
import { generationParameterRows } from '../generation-parameter-rows';
import { localEngineGenerationProfile } from '../local-engine-profiles';
import {
  modelOptionsPanelModel,
  reasoningTierAfterTap,
  type ModelOptionsPanelFacts,
} from '../model-options-panel-model';

function capability(overrides: Partial<ModelOptionCapabilityInput>): ModelOptionCapabilityInput {
  return {
    capability: 'reasoning',
    status: 'automaticAvailable',
    availableIntents: [],
    connection: 'official',
    isWritable: true,
    protocolUndecided: false,
    rejectedIntents: [],
    chatTemplateThinkingIsOn: false,
    supportsChatTemplate: false,
    ...overrides,
  };
}

const NO_NOTES = { overridden: false, riskTiers: [], upstreamRejected: false };

function facts(overrides: Partial<ModelOptionsPanelFacts> = {}): ModelOptionsPanelFacts {
  return {
    connection: 'official',
    connectionName: 'OpenRouter',
    transportLabel: 'Chat Completions',
    web: capability({ capability: 'web', availableIntents: ['automatic'] }),
    reasoning: capability({ availableIntents: ['off', 'low', 'deep'] }),
    chatTemplateState: 'off',
    hasAlternativeModels: { web: true, reasoning: true },
    hasReadOnlyReason: false,
    generationRows: [],
    notes: { web: NO_NOTES, reasoning: NO_NOTES },
    ...overrides,
  };
}

function custom(overrides: Partial<ModelOptionsPanelFacts> = {}): ModelOptionsPanelFacts {
  return facts({
    connection: 'custom',
    connectionName: 'My server',
    web: capability({ capability: 'web', status: 'unknown', connection: 'custom' }),
    reasoning: capability({ status: 'unknown', connection: 'custom', supportsChatTemplate: true }),
    ...overrides,
  });
}

const rowKinds = (model: ReturnType<typeof modelOptionsPanelModel>) => (
  model.card.kind === 'rows' ? model.card.rows.map((row) => `${row.capability}:${row.kind}`) : [model.card.kind]
);

beforeEach(() => localStorage.clear());

describe('status mark', () => {
  it('one of web search or thinking is cataloged → official configuration (same for custom connections)', () => {
    expect(modelOptionsPanelModel(facts()).mark).toBe('official');
    expect(modelOptionsPanelModel(custom({
      reasoning: capability({ status: 'automaticAvailable', connection: 'custom', availableIntents: ['off', 'low'] }),
    })).mark).toBe('official');
  });

  it('custom connection with neither cataloged → unverified', () => {
    expect(modelOptionsPanelModel(custom()).mark).toBe('unverified');
  });

  it('uncataloged model on an official connection → no mark', () => {
    expect(modelOptionsPanelModel(facts({
      web: capability({ capability: 'web', status: 'pending' }),
      reasoning: capability({ status: 'unknown' }),
    })).mark).toBeUndefined();
  });
});

describe('header second line', () => {
  it('declared engine → engine name; loopback address (also without a scheme) → local', () => {
    for (const apiBaseURL of ['http://127.0.0.1:8080/v1', 'localhost:11434', 'http://[::1]:1234']) {
      expect(modelOptionsPanelModel(custom({ engineProfile: 'llamacpp', apiBaseURL })).header).toEqual({
        connection: { kind: 'engine', name: 'llama.cpp' }, transport: { kind: 'local' },
      });
    }
    expect(modelOptionsPanelModel(custom({ engineProfile: 'openwebui' })).header.connection)
      .toEqual({ kind: 'engine', name: 'Open WebUI' });
  });

  it('no declared engine, not loopback → connection name · protocol name', () => {
    expect(modelOptionsPanelModel(facts({ apiBaseURL: 'https://openrouter.ai/api/v1' })).header).toEqual({
      connection: { kind: 'connection', name: 'OpenRouter' }, transport: { kind: 'protocol', label: 'Chat Completions' },
    });
  });
});

describe('capability card', () => {
  it('row order is web search then thinking', () => {
    expect(rowKinds(modelOptionsPanelModel(facts()))).toEqual(['web:toggle', 'reasoning:tiers']);
  });

  it('thinking comes first when it is a chat template toggle', () => {
    expect(rowKinds(modelOptionsPanelModel(custom()))).toEqual(['reasoning:toggle', 'web:disclosure']);
  });

  it('chat template toggle blocked / notSending → explanation card (cannot switch here) + link to additional request body', () => {
    for (const state of ['blocked', 'notSending'] as const) {
      const out = modelOptionsPanelModel(custom({ chatTemplateState: state }));
      expect(out.card.kind === 'rows' && out.card.rows[0]).toEqual({
        kind: 'chatTemplateBlocked', capability: 'reasoning', state, link: 'openAdditionalRequestBody',
      });
    }
  });

  it('no other model to switch to in the connection → drop the "see which models can be adjusted" link', () => {
    const out = modelOptionsPanelModel(facts({
      web: capability({ capability: 'web', status: 'unsupported' }),
      reasoning: capability({ status: 'unknown' }),
      hasAlternativeModels: { web: false, reasoning: false },
    }));
    expect(out.card.kind === 'rows' && out.card.rows.map((row) => 'link' in row ? row.link : undefined))
      .toEqual([undefined, undefined]);
    // The link stays when other models exist.
    const kept = modelOptionsPanelModel(facts({
      web: capability({ capability: 'web', status: 'unsupported' }),
      reasoning: capability({ status: 'unknown' }),
    }));
    expect(kept.card.kind === 'rows' && kept.card.rows.map((row) => 'link' in row ? row.link : undefined))
      .toEqual(['openSupportedModels', 'openSupportedModels']);
  });

  it('protocol undecided → the whole card has one job', () => {
    const out = modelOptionsPanelModel(custom({
      web: capability({ capability: 'web', status: 'unknown', connection: 'custom', protocolUndecided: true }),
      reasoning: capability({ status: 'unknown', connection: 'custom', protocolUndecided: true }),
    }));
    expect(out.card).toEqual({ kind: 'protocolUndecided', link: 'openConnectionProtocol' });
  });
});

describe('read-only banner', () => {
  it('hidden while the card has an operable control; shown when every row is read-only', () => {
    expect(modelOptionsPanelModel(facts({ hasReadOnlyReason: true })).showsReadOnlyBanner).toBe(false);
    expect(modelOptionsPanelModel(facts({
      hasReadOnlyReason: true,
      web: capability({ capability: 'web', availableIntents: ['automatic'], isWritable: false }),
      reasoning: capability({ availableIntents: ['off', 'low'], isWritable: false }),
    })).showsReadOnlyBanner).toBe(true);
    expect(modelOptionsPanelModel(facts()).showsReadOnlyBanner).toBe(false);
  });
});

describe('tapping a segment again', () => {
  it('without an automatic cell: tapping the selected tier returns to unselected; with an automatic cell: select as tapped, and automatic is stored as unselected', () => {
    expect(reasoningTierAfterTap(['off', 'low', 'deep'], 'low', 'low')).toBeUndefined();
    expect(reasoningTierAfterTap(['off', 'low', 'deep'], 'low', 'deep')).toBe('deep');
    expect(reasoningTierAfterTap(['automatic', 'low', 'deep'], 'low', 'low')).toBe('low');
    expect(reasoningTierAfterTap(['automatic', 'low', 'deep'], 'low', 'automatic')).toBeUndefined();
  });
});

describe('parameter card and notes strip', () => {
  it('parameters written through the production store → row model → at most 2 chips plus N more', () => {
    const llama = localEngineGenerationProfile('llamacpp', undefined)!;
    const scope = { providerId: 'p1', modelId: 'm1', conversationId: 'c1' };
    saveGenerationParameterOverrides(scope, {
      temperature: { state: 'value', value: 0.7 }, top_k: { state: 'value', value: 20 }, min_p: { state: 'value', value: 0.1 },
    } as never);
    const generationRows = generationParameterRows({
      parameterIds: llama.parameters.map((parameter) => parameter.id),
      profile: llama,
      resolved: resolveGenerationParameterOverridesWithSources(scope),
      editingLayers: ['transient', 'conversation'],
    });
    const out = modelOptionsPanelModel(facts({ generationRows }));
    expect(out.parameters.chips).toHaveLength(2);
    expect(out.parameters.moreCount).toBe(1);
  });

  it('custom field takeover / risk tiers / upstream rejection go into the notes strip', () => {
    const out = modelOptionsPanelModel(facts({
      notes: {
        web: { overridden: false, riskTiers: [], upstreamRejected: true },
        reasoning: { overridden: true, riskTiers: ['privacy_impacting'], upstreamRejected: false },
      },
    }));
    expect(out.notes.web).toEqual([{ kind: 'note', textKey: 'common.capabilityControlUpstreamRejected', tone: 'warning' }]);
    expect(out.notes.reasoning.map((entry) => entry.kind === 'note' ? entry.textKey : entry.kind)).toEqual([
      'common.customRequestFieldsActiveNote', 'common.capabilityRiskPrivacy', 'advancedSettingsLink',
    ]);
  });
});

describe('thinking tier rejected by upstream', () => {
  const identity = { connectionId: 'connection-a', canonicalModelId: 'model/a', finalTransport: 'openai_responses', runtimeRevision: 'runtime-r7' };
  const descriptor = {
    version: 1 as const, action: 'user_confirmed_resend_without_located_setting' as const, source: 'provider_recipe' as const,
    owners: ['reasoning' as const], locatedPointers: ['/reasoning/effort'], recipeRef: 'fixture.reasoning.v1',
  };
  const availableIntents = ['off', 'low', 'balanced', 'deep', 'max'];
  const reasoningFacts = (selectedIntent: string) => {
    // Rejected tiers and group dormancy come from the production readers; cache entries are not hand-built.
    const rejection = capabilityRejectionState(identity, 'reasoning', 'provider_recipe', availableIntents);
    return facts({
      reasoning: capability({ availableIntents, selectedIntent, rejectedIntents: rejection.rejectedIntents }),
      notes: { web: NO_NOTES, reasoning: { ...NO_NOTES, upstreamRejected: rejection.dormant } },
    });
  };

  it('a tier rejection recorded in production → the panel row shows it as rejected and falls back to the nearest tier, without the group-wide rejection note', () => {
    recordCapabilityRejection(identity, descriptor, Date.now(), { reasoningIntent: 'max' });
    const out = modelOptionsPanelModel(reasoningFacts('max'));
    const row = out.card.kind === 'rows' ? out.card.rows[1] : undefined;
    expect(row).toMatchObject({
      kind: 'tiers', options: ['off', 'low', 'balanced', 'deep'], selection: 'deep', rejected: ['max'],
      trailing: { kind: 'rejected', intent: 'max' },
      footnotes: [{ kind: 'rejectedFallback', rejected: 'max', fallback: 'deep' }],
    });
    expect(out.notes.reasoning).toEqual([]);
  });

  it('a rejection without a tier → tiers render as usual and the notes strip reports the whole group as rejected', () => {
    recordCapabilityRejection(identity, descriptor);
    const out = modelOptionsPanelModel(reasoningFacts('max'));
    const row = out.card.kind === 'rows' ? out.card.rows[1] : undefined;
    expect(row).toMatchObject({ kind: 'tiers', selection: 'max', rejected: [] });
    expect(out.notes.reasoning).toEqual([{ kind: 'note', textKey: 'common.capabilityControlUpstreamRejected', tone: 'warning' }]);
  });
});
