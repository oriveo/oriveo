// @vitest-environment jsdom
//
// Capability reachability for the subscription path (Codex / Grok subscriptions).
//
// Subscription models are not in the metadata catalog and never carry v2
// `capabilityControls`, so the web toggle and the reasoning tier pills render nowhere and
// nothing is ever injected outbound. An outbound implementation that copies the upstream
// declaration is dead code as long as that gate stays shut upstream.
//
// These cases pin the full chain once that gate is opened:
//   upstream /models declaration -> control verdict -> preference identity -> outbound intent
// Any link falling back to fail-closed turns this file red.

import { describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';

/** A model-facts table the test can rewrite: empty by default; the facts-fallback case puts one entry in it. */
const modelFactsTable: Record<string, { toolCall?: boolean }> = {};

vi.mock('../../metadata/metadata-client', async (importOriginal) => (await import('../../../__tests__/mocks/metadata-client')).metadataClientMock(importOriginal, {
  // The core fact about subscription models: they are not in the catalog.
  resolveCatalogModel: () => null,
  getModelFacts: (_providerKind: string, modelID: string) => modelFactsTable[modelID],
  getModelFactsRevision: () => (Object.keys(modelFactsTable).length ? 'facts-rev-1' : undefined),
  getModelTransport: () => undefined,
  getCapabilityRuntime: () => undefined,
  getMetadataRevision: () => undefined,
  getRelayRuntimeConfig: () => undefined,
  resolveGenerationProfileRef: () => undefined,
  getDeclaredReasoningLevels: () => [],
  getDeclaredReasoningDefaultLevel: () => undefined,
  subscriptionDeclaredReasoningLevels: (_providerKind: string, model: AIModel) =>
    model.upstreamReasoningLevels ?? [],
}));

vi.mock('../../../infra/storage/partition', () => ({ getActiveUIDSync: () => 'uid-1' }));

import { resolveModelCapabilityEvidence } from '../capability-evidence';
import { subscriptionTruthCandidates } from '../../capability/truth/subscription-truth-adapter';
import { presentCapabilityControl } from '../capability-control-presentation';
import { webPreferenceReachesTheWire } from '../capability-control-presentation';
import { capabilityRuntimeIdentity } from '../capability-preference-settings';
import { filterRequestCapabilityIntent } from '../stream-options';
import { resolveModelControlStatus } from '../model-control-capability-layout';

function codexProvider(): Provider {
  return {
    id: '11111111-1111-4111-8111-111111111111', kind: 'openAI', status: { kind: 'connected' },
    models: [], catalogModels: [], apiKey: '', apiKeyPreview: '',
    authMode: 'subscription',
    openAISubscription: { accessToken: 'at', accountID: 'acc-1', obtainedAt: 1 },
  } as unknown as Provider;
}

function grokProvider(): Provider {
  return {
    id: '22222222-2222-4222-8222-222222222222', kind: 'grok', status: { kind: 'connected' },
    models: [], catalogModels: [], apiKey: '', apiKeyPreview: '',
    authMode: 'subscription',
    grokSubscription: { accessToken: 'at', obtainedAt: 1 },
  } as unknown as Provider;
}

/** The shape built by `buildOpenAISubscriptionModels`: capability bits and the tier table are copied from the upstream /models declaration. */
function subscriptionModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-5.6-sol', name: 'GPT-5.6-Sol',
    capabilities: ['text', 'web', 'reasoning'],
    upstreamReasoningLevels: ['low', 'medium', 'high'],
    reasoningModeAvailable: true, isAvailable: true, isDefault: true, priceTier: '',
    ...overrides,
  } as unknown as AIModel;
}

describe('subscription path: control verdicts follow the upstream declaration', () => {
  it('makes the web control usable when upstream declares web search, rather than showing it as unadjustable', () => {
    // Falling back to unknown would render "upstream says it is supported" as a line of status text with no toggle to reach.
    const control = presentCapabilityControl(codexProvider(), subscriptionModel(), 'web');
    expect(control.state).toBe('auto_available');
    expect(control.availableIntents).toContain('automatic');
  });

  it('reports unavailable (definitely unsupported) rather than unknown when upstream declares no web search', () => {
    const control = presentCapabilityControl(
      codexProvider(),
      subscriptionModel({ capabilities: ['text'] }),
      'web',
    );
    expect(control.state).toBe('unavailable');
    expect(control.reasonCode).toBe('model_capability_absent');
  });

  it('computes available tiers with the same function used outbound: only tiers that map to a declared upstream value appear', () => {
    const control = presentCapabilityControl(codexProvider(), subscriptionModel(), 'reasoning');
    expect(control.state).toBe('auto_available');
    // Upstream declares only low/medium/high: max degrades to high, and the contract
    // guarantees degradation still lands on a legal value rather than silently sending
    // nothing, so it is a tier that really can go out.
    expect(control.availableIntents).toEqual(['low', 'balanced', 'deep', 'max']);
  });

  it('hides tiers that cannot be mapped when upstream declares a single one, rather than offering a control that does nothing', () => {
    // With only xhigh declared, fast maps to low/minimal/medium and matches none of them, so the tier must not appear.
    const control = presentCapabilityControl(
      codexProvider(),
      subscriptionModel({ upstreamReasoningLevels: ['xhigh'] }),
      'reasoning',
    );
    expect(control.availableIntents).toEqual(['max']);
  });

  it('reports the reasoning tier as unavailable when upstream declares no tier table, rather than offering a control that does nothing', () => {
    const control = presentCapabilityControl(
      codexProvider(),
      subscriptionModel({ upstreamReasoningLevels: [] }),
      'reasoning',
    );
    expect(control.state).toBe('unavailable');
    expect(control.reasonCode).toBe('upstream_parameter_not_declared');
  });

  it('keeps Grok subscription Responses web search constantly automatic, with a reasonCode marking always-on, presented as alwaysOn', () => {
    const control = presentCapabilityControl(
      grokProvider(), subscriptionModel({ upstreamApiBackend: 'responses' }), 'web',
    );
    expect(control.state).toBe('auto_available');
    expect(control.availableIntents).toEqual(['automatic']);
    expect(control.reasonCode).toBe('subscription_web_always_on');
    expect(resolveModelControlStatus(control)).toBe('alwaysOn');
    // Codex is unchanged: still a switch the user can flip.
    const codex = presentCapabilityControl(codexProvider(), subscriptionModel(), 'web');
    expect(codex.reasonCode).toBe('subscription_upstream_declared');
    expect(resolveModelControlStatus(codex)).toBe('automaticAvailable');
  });

  it('keeps reasoning tiers usable for a Grok subscription, since reasoning_effort is known to be accepted', () => {
    const control = presentCapabilityControl(grokProvider(), subscriptionModel(), 'reasoning');
    expect(control.state).toBe('auto_available');
    expect(control.availableIntents.length).toBeGreaterThan(0);
  });
});

describe('subscription path: preference identity is available so choices can be stored', () => {
  it('still resolves an identity for a subscription model that has no catalog transport', () => {
    // With a null identity the capability panel is entirely read-only and the user's choice can neither be stored nor read back.
    const identity = capabilityRuntimeIdentity(codexProvider(), subscriptionModel());
    expect(identity).not.toBeNull();
    expect(identity?.canonicalModelId).toBe('gpt-5.6-sol');
    // Codex uses /responses and Grok uses /chat/completions, so the transport for this path
    // is definite and needs no confirmation from the catalog.
    expect(identity?.finalTransport).toBe('openai_responses');
    expect(identity?.transportIdentity).toBeTruthy();
  });

  it('defaults a Grok subscription to Responses when nothing is declared', () => {
    const identity = capabilityRuntimeIdentity(grokProvider(), subscriptionModel());
    expect(identity?.finalTransport).toBe('openai_responses');
  });

  it('keeps the two paths on distinct identities so preferences do not leak across them', () => {
    const codex = capabilityRuntimeIdentity(codexProvider(), subscriptionModel());
    const grok = capabilityRuntimeIdentity(grokProvider(), subscriptionModel());
    expect(codex?.providerId).not.toBe(grok?.providerId);
  });
});

describe('subscription path: user intent really reaches the outbound request', () => {
  it('carries web intent through to the outbound gate', () => {
    localStorage.clear();
    // Production shape: the upstream /models snapshot sits in provider.models. A snapshot never fetched is state 1, and outbound fails closed (see the adapter cases below).
    const model = subscriptionModel();
    const provider = { ...codexProvider(), models: [model] };
    const identity = capabilityRuntimeIdentity(provider, model);
    // The second gate: whether the intent can reach the wire. It fails closed when the identity is null or the control is unavailable.
    const reaches = webPreferenceReachesTheWire({
      provider, model, transportIdentity: identity?.transportIdentity ?? '',
    });
    expect(reaches).toBe(true);

    const intent = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'automatic', webSearchEnabled: true,
      webReachesTheWire: reaches,
    });
    // A false here is the bug where the user turns web search on and nothing is ever sent.
    expect(intent.supportsWebSearch).toBe(true);
  });

  it('does not let web intent reach the outbound request for a model upstream never declared it for', () => {
    localStorage.clear();
    const model = subscriptionModel({ capabilities: ['text'] });
    const provider = { ...codexProvider(), models: [model] };
    const identity = capabilityRuntimeIdentity(provider, model);
    const reaches = webPreferenceReachesTheWire({
      provider, model, transportIdentity: identity?.transportIdentity ?? '',
    });
    expect(reaches).toBe(false);

    const intent = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'automatic', webSearchEnabled: true,
      webReachesTheWire: reaches,
    });
    expect(intent.supportsWebSearch).toBe(false);
  });

  it('carries the reasoning tier the user picked through to the outbound intent', () => {
    localStorage.clear();
    const model = subscriptionModel();
    const provider = { ...codexProvider(), models: [model] };
    const intent = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'deep', webSearchEnabled: false,
    });
    expect(intent.reasoning).toBe('deep');
  });

  it('injects no tier for automatic, leaving it to the upstream default_reasoning_level', () => {
    localStorage.clear();
    const model = subscriptionModel();
    const provider = { ...codexProvider(), models: [model] };
    const intent = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'automatic', webSearchEnabled: false,
    });
    expect(intent.reasoning).toBeUndefined();
  });
});

describe('subscription path: the capability projection copies the upstream snapshot (SubscriptionTruthAdapter)', () => {
  /** Production shape: subscription sync writes the upstream /models per-model declarations into provider.models and empties catalogModels. */
  function withSnapshot(provider: Provider, ...models: AIModel[]): Provider {
    return { ...provider, models, catalogModels: [] };
  }
  const resolve = (provider: Provider, model: AIModel, key: Parameters<typeof resolveModelCapabilityEvidence>[0]['key']) =>
    resolveModelCapabilityEvidence({ key, provider, model });

  // Vision reads the first-hand upstream input modalities (fixture subscription-facts.v1.json: a list containing image = auto, otherwise model_capability_absent);
  // web search reads the upstream capability bit.
  it('vision / web come from the upstream declaration: supported with the capability bit, unsupported without it, source always upstream_declaration', () => {
    const model = subscriptionModel({
      capabilities: ['text', 'web', 'image', 'reasoning'], upstreamInputModalities: ['text', 'image'],
    });
    const provider = withSnapshot(codexProvider(), model);
    for (const key of ['web_search', 'vision_input'] as const) {
      const resolution = resolve(provider, model, key);
      expect(resolution.support, key).toBe('supported');
      expect(resolution.source, key).toBe('upstream_declaration');
      expect(resolution.grade, key).toBe('declared');
      expect(resolution.requestPolicy, key).toBe('allow');
    }
    const plain = subscriptionModel({ capabilities: ['text'], upstreamInputModalities: ['text'] });
    const plainProvider = withSnapshot(codexProvider(), plain);
    for (const key of ['web_search', 'vision_input'] as const) {
      const resolution = resolve(plainProvider, plain, key);
      expect(resolution.support, key).toBe('unsupported');
      expect(resolution.source, key).toBe('upstream_declaration');
      // Upstream explicitly does not support it: not sent even when the user turns it on explicitly.
      expect(resolveModelCapabilityEvidence({ key, provider: plainProvider, model: plain, hasExplicitValue: true })
        .requestPolicy, key).toBe('omit_unsupported');
    }
  });

  it('the supported reasoning-tier set = the upstream declaration filtered by the same codexReasoningEffort used outbound', () => {
    const modes = ['fast', 'balanced', 'deep', 'max'] as const;
    const supportedModes = (model: AIModel) => modes.filter((mode) => (
      resolve(withSnapshot(codexProvider(), model), model, `reasoning_level/${mode}`).support === 'supported'
    ));
    // low/medium/high: max falls back to high along the degradation chain, so all four tiers can be sent.
    expect(supportedModes(subscriptionModel())).toEqual([...modes]);
    // Only xhigh: none of fast's candidates low/minimal/medium hit.
    expect(supportedModes(subscriptionModel({ upstreamReasoningLevels: ['xhigh'] }))).toEqual(['max']);
    // No tier table declared (model-facts is also empty under the mock): all unsupported, source recorded as model_facts.
    const silent = subscriptionModel({ upstreamReasoningLevels: undefined });
    expect(supportedModes(silent)).toEqual([]);
    const silentResolution = resolve(withSnapshot(codexProvider(), silent), silent, 'reasoning_level/deep');
    expect(silentResolution.support).toBe('unsupported');
    expect(silentResolution.source).toBe('model_facts');
    expect(resolve(withSnapshot(codexProvider(), subscriptionModel()), subscriptionModel(), 'reasoning_level/max').source)
      .toBe('upstream_declaration');
  });

  it('tool_call does not read the snapshot model toolCall bit: one carrying toolCall:false with no table entry is still unknown; a model outside the snapshot is catalog_absent per key', () => {
    const declared = subscriptionModel({ toolCall: false });
    const declaredProvider = withSnapshot(codexProvider(), declared);
    expect(subscriptionTruthCandidates(
      { provider: declaredProvider, model: declared, effectiveTransport: 'responses' }, ['tool_call'],
    )).toEqual([]);
    expect(resolve(declaredProvider, declared, 'tool_call'))
      .toMatchObject({ support: 'unknown', source: 'none', reasonCode: 'missing_evidence' });
    const undeclared = subscriptionModel();
    expect(resolve(withSnapshot(codexProvider(), undeclared), undeclared, 'tool_call'))
      .toMatchObject({ support: 'unknown', source: 'none', reasonCode: 'missing_evidence' });
    // A key with no candidate stays open-world: an explicit intent may pass (same as going through the official adapter before the split).
    expect(resolveModelCapabilityEvidence({
      key: 'tool_call', provider: withSnapshot(codexProvider(), undeclared), model: undeclared, hasExplicitValue: true,
    }).requestPolicy).toBe('allow_explicit_unverified');

    const provider = withSnapshot(codexProvider(), subscriptionModel());
    const stale = subscriptionModel({ id: 'gpt-retired', capabilities: ['text', 'web', 'image'] });
    for (const key of ['web_search', 'vision_input', 'reasoning_level/deep'] as const) {
      for (const hasExplicitValue of [false, true]) {
        expect(resolveModelCapabilityEvidence({ key, provider, model: stale, hasExplicitValue }), `${key} ${hasExplicitValue}`)
          .toMatchObject({ support: 'unknown', source: 'catalog_absent', requestPolicy: 'omit_unknown', reasonCode: 'catalog_absent' });
      }
    }
    // Empty snapshot (not fetched): no candidate, and not catalog_absent.
    expect(resolve(codexProvider(), stale, 'vision_input'))
      .toMatchObject({ support: 'unknown', source: 'none', reasonCode: 'missing_evidence' });
  });

  it('state 1 (snapshot not fetched): keys the catalog owns are not let through even with an explicit intent; tool_call is not the snapshot\'s, so open-world stays', () => {
    const unfetched = codexProvider();
    const model = subscriptionModel({ capabilities: ['text', 'web', 'image'] });
    for (const key of ['web_search', 'vision_input', 'reasoning_level/deep'] as const) {
      expect(resolveModelCapabilityEvidence({ key, provider: unfetched, model, hasExplicitValue: true }), key)
        .toMatchObject({ support: 'unknown', source: 'none', requestPolicy: 'omit_unknown', reasonCode: 'missing_evidence' });
    }
    expect(resolveModelCapabilityEvidence({ key: 'tool_call', provider: unfetched, model, hasExplicitValue: true })
      .requestPolicy).toBe('allow_explicit_unverified');
  });

  it('tool_call reads only the model-facts table (source model_facts); the snapshot model toolCall bit plays no part, independent of snapshot state', () => {
    const model = subscriptionModel({ id: 'grok-4.6' });
    modelFactsTable['grok-4.6'] = { toolCall: true };
    try {
      const inSnapshot = resolve(withSnapshot(grokProvider(), model), model, 'tool_call');
      expect(inSnapshot).toMatchObject({ support: 'supported', source: 'model_facts', grade: 'declared', requestPolicy: 'allow' });
      // A snapshot model carrying toolCall:false still takes the table (the subscription /models has no tool field, so that bit can only be a stale synced value).
      const declared = subscriptionModel({ id: 'grok-4.6', toolCall: false });
      expect(resolve(withSnapshot(grokProvider(), declared), declared, 'tool_call'))
        .toMatchObject({ support: 'supported', source: 'model_facts' });
      expect(subscriptionTruthCandidates(
        { provider: withSnapshot(grokProvider(), declared), model: declared, effectiveTransport: 'chat' }, ['tool_call'],
      )).toEqual([expect.objectContaining({ key: 'tool_call', support: 'supported', source: 'model_facts' })]);
      // A snapshot that has not been fetched still reads the table: tool_call is not the snapshot's.
      expect(resolve(grokProvider(), model, 'tool_call')).toMatchObject({ support: 'supported', source: 'model_facts' });
    } finally {
      delete modelFactsTable['grok-4.6'];
    }
  });
});

describe('subscription path: API key mode is unaffected', () => {
  it('keeps the same OpenAI provider on the catalog checks in API key mode, so the subscription branch does not bleed over', () => {
    const provider = { ...codexProvider(), authMode: 'apiKey' } as Provider;
    // Not found in the catalog (the mock returns null) means an honest unknown, exactly as before subscriptions existed.
    const control = presentCapabilityControl(provider, subscriptionModel(), 'web');
    expect(control.state).toBe('unknown');
  });
});
