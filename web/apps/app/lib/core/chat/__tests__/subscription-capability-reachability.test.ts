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

vi.mock('../../metadata/metadata-client', () => ({
  // The core fact about subscription models: they are not in the catalog.
  resolveCatalogModel: () => null,
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

import { presentCapabilityControl } from '../capability-control-presentation';
import { webPreferenceReachesTheWire } from '../capability-control-presentation';
import { capabilityRuntimeIdentity } from '../capability-preference-settings';
import { filterRequestCapabilityIntent } from '../stream-options';

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

  it('keeps Grok subscription Responses web search constantly automatic', () => {
    const control = presentCapabilityControl(
      grokProvider(), subscriptionModel({ upstreamApiBackend: 'responses' }), 'web',
    );
    expect(control.state).toBe('auto_available');
    expect(control.availableIntents).toEqual(['automatic']);
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
    const provider = codexProvider();
    const model = subscriptionModel();
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
    const provider = codexProvider();
    const model = subscriptionModel({ capabilities: ['text'] });
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
    const provider = codexProvider();
    const model = subscriptionModel();
    const intent = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'deep', webSearchEnabled: false,
    });
    expect(intent.reasoning).toBe('deep');
  });

  it('injects no tier for automatic, leaving it to the upstream default_reasoning_level', () => {
    localStorage.clear();
    const provider = codexProvider();
    const model = subscriptionModel();
    const intent = filterRequestCapabilityIntent({
      provider, model, reasoningMode: 'automatic', webSearchEnabled: false,
    });
    expect(intent.reasoning).toBeUndefined();
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
