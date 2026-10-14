import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayModelTransport, RelayRequestedConfig } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';

vi.mock('../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import {
  __relayLazyReprobesSettledForTest,
  applyRelayKeyOperation,
  __setRelayLazyProbeStateForTest,
  clearRelayLazyProbeStates,
  enableProviderModelWithProbe,
  redetectRelayModels,
  relayLazyProbeState,
} from '../relay-model-probe-ops';
import { refreshRelayCatalogInStore } from '../providers/provider-sync';
import { updateProviderKey } from '../provider-ops';
import { replaceProviderModels } from '../provider-model-ops';
import { promoteRelayTransportOnDelivered } from '../providers/relay-model-observed';
import { reportSendCompletion } from '../chat/send-completion';
import { rememberRelayCatalogEndpointTypes } from '../providers/relay-probe-candidates';
import {
  capabilityRejectionIsDormant,
  locateCapabilityRecovery,
  recordCapabilityRejection,
  recordToolCallSupportFalse,
  toolCallSupportIsRememberedFalse,
} from '../chat/capability-recovery-runtime';

/* ── Fixture (source of truth): shared/test-fixtures/relay/probe-orchestration.v1.json ── */

type ShortTransport = 'chat' | 'responses' | 'messages' | 'gemini';
interface FixtureModel {
  id: string;
  supportedEndpointTypes?: string[];
  relayTransport?: RelayModelTransport;
  relayTransportSource?: AIModel['relayTransportSource'];
  relayCapabilityOverrides?: AIModel['relayCapabilityOverrides'];
}
interface FixtureScenario {
  caseId: string;
  test: string;
  connection?: { baseURL: string; transport: RelayRequestedConfig['transport'] };
  models?: FixtureModel[];
  enable?: string;
  defaultModel?: string;
  ping?: Record<string, string>;
  before?: Array<FixtureModel & { outcome: 'delivered' | 'failed'; after: Partial<FixtureModel> }>;
  expect?: {
    pings: Array<[string, ShortTransport]>;
    enabled: string[];
    connectionTransport: RelayRequestedConfig['transport'];
    resolvedAPIBaseURLs?: Record<string, string>;
    negativeCacheEntriesForConnection?: number;
    models: Record<string, Partial<FixtureModel>>;
  };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'probe-orchestration.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as {
        probeOutcomeRules: { pass: string[]; routeRejected: string[]; inconclusive: string[] };
        scenarios: FixtureScenario[];
      };
    }
    dir = path.dirname(dir);
  }
  throw new Error('probe-orchestration.v1.json not found');
})();

/* The route-level 403 response body takes the registered phrase from negative-cache.v1.json (same criterion as the negative-cache rules). */
const routePhrase = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'negative-cache.v1.json');
    if (existsSync(candidate)) {
      return (JSON.parse(readFileSync(candidate, 'utf8')) as { protocolFallbackRules: { phrases: string[] } })
        .protocolFallbackRules.phrases[0]!;
    }
    dir = path.dirname(dir);
  }
  throw new Error('negative-cache.v1.json not found');
})();

const OUTCOME_STATUS: Readonly<Record<string, number>> = {
  http_400: 400, http_401: 401, http_403: 403, http_403_route: 403, http_404: 404, http_405: 405,
  http_415: 415, http_422: 422, http_429: 429, http_5xx: 502,
};

/** A probe outcome from the fixture -> the fake relay response; an unknown outcome name throws, so a new outcome is not silently treated as 404 and passes green. */
function respondOutcome(outcome: string): Response {
  if (outcome === 'ok') {
    return new Response('{"id":"ok"}', { status: 200, headers: { 'Content-Type': 'application/json' } });
  }
  if (outcome === 'network') throw new TypeError('Failed to fetch');
  if (outcome === 'html_200') {
    return new Response('<!doctype html><html><body><div id="root"></div></body></html>', {
      status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  }
  const status = OUTCOME_STATUS[outcome];
  if (status === undefined) throw new Error(`unknown probe outcome in fixture: ${outcome}`);
  // The phrase deliberately uses different casing: matching is case-insensitive.
  const message = outcome === 'http_403_route' ? `This group ${routePhrase.toUpperCase()}` : `upstream said ${outcome}`;
  return new Response(JSON.stringify({ error: { message } }), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}

/* RL2-PROBE-06 T5: add / enable / re-detect send no capability test request at all (built-in image and tools leave the device only when the user taps the button). */
const capabilityFixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'capability-test.v1.json');
    if (existsSync(candidate)) {
      return JSON.parse(readFileSync(candidate, 'utf8')) as { builtins: { imagePNGBase64: string; tool: { name: string } } };
    }
    dir = path.dirname(dir);
  }
  throw new Error('capability-test.v1.json not found');
})();

function expectNoCapabilityTestRequests() {
  const bodies = vi.mocked(fetch).mock.calls.map(([, init]) => String(init?.body ?? ''));
  expect(bodies.some((body) => body.includes(capabilityFixture.builtins.imagePNGBase64))).toBe(false);
  expect(bodies.some((body) => body.includes(capabilityFixture.builtins.tool.name))).toBe(false);
}

const scenarios = (prefix: string) => fixture.scenarios.filter((item) => item.caseId.startsWith(prefix));
const scenario = (caseId: string) => fixture.scenarios.find((item) => item.caseId === caseId)!;

/* ── Fake relay: the production pingRelay / catalog sync really call fetch; here the protocol is recognized by URL ── */

function upstreamOf(input: RequestInfo | URL, init?: RequestInit): string {
  return new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input instanceof Request ? input.url : input);
}

function protocolOf(url: string): ShortTransport | 'models' | undefined {
  if (/\/models$/.test(url)) return 'models';
  if (url.endsWith('/chat/completions')) return 'chat';
  if (url.endsWith('/responses')) return 'responses';
  if (url.endsWith('/messages')) return 'messages';
  if (/:(?:stream)?generateContent/i.test(url)) return 'gemini';
  return undefined;
}

function modelOf(url: string, init?: RequestInit): string {
  const gemini = /\/models\/([^/:]+):/.exec(url);
  if (gemini) return decodeURIComponent(gemini[1]!);
  try {
    return String((JSON.parse(String(init?.body ?? '{}')) as { model?: unknown }).model ?? '');
  } catch {
    return '';
  }
}

function installFakeRelay(s: FixtureScenario): Array<[string, ShortTransport]> {
  const pings: Array<[string, ShortTransport]> = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = upstreamOf(input, init);
    const protocol = protocolOf(url);
    if (protocol === 'models') {
      const data = (s.models ?? []).map((item) => ({
        id: item.id,
        object: 'model',
        ...(item.supportedEndpointTypes ? { supported_endpoint_types: item.supportedEndpointTypes } : {}),
      }));
      return new Response(JSON.stringify({ object: 'list', data }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    if (!protocol) return new Response('not found', { status: 404 });
    const modelID = modelOf(url, init);
    pings.push([modelID, protocol]);
    return respondOutcome(s.ping?.[`${modelID}@${protocol}`] ?? 'http_404');
  });
  return pings;
}

/* ── Construction ── */

const PROVIDER_ID = 'relay-1';

function makeModel(item: FixtureModel, isDefault = false): AIModel {
  return {
    id: item.id,
    name: item.id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault,
    priceTier: '',
    ...(item.relayTransport ? { relayTransport: item.relayTransport } : {}),
    ...(item.relayTransportSource ? { relayTransportSource: item.relayTransportSource } : {}),
    ...(item.relayCapabilityOverrides ? { relayCapabilityOverrides: item.relayCapabilityOverrides } : {}),
  };
}

function makeRelayProvider(s: FixtureScenario, models: AIModel[], overrides: Partial<Provider> = {}): Provider {
  return {
    id: PROVIDER_ID,
    kind: 'relay',
    status: { kind: 'connected' },
    models,
    catalogModels: (s.models ?? []).map((item) => makeModel(item)),
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
    baseURLText: s.connection?.baseURL ?? 'https://relay.example.com/v1',
    relayKind: 'openai_compatible',
    relayRequested: {
      transport: s.connection?.transport ?? 'openai_chat_completions',
      authMode: 'bearer',
    },
    ...overrides,
  };
}

function modelFields(model: AIModel | undefined): Partial<FixtureModel> {
  const out: Partial<FixtureModel> = {};
  if (model?.relayTransport) out.relayTransport = model.relayTransport;
  if (model?.relayTransportSource) out.relayTransportSource = model.relayTransportSource;
  if (model?.relayCapabilityOverrides) out.relayCapabilityOverrides = model.relayCapabilityOverrides;
  return out;
}

function expectScenarioState(
  store: ReturnType<typeof createAppStore>,
  s: FixtureScenario,
  pings: Array<[string, ShortTransport]>,
) {
  const expected = s.expect!;
  const provider = store.getState().providers.find((item) => item.id === PROVIDER_ID)!;
  expect(pings).toEqual(expected.pings);
  expect(provider.models.map((model) => model.id)).toEqual(expected.enabled);
  expect(provider.relayRequested?.transport).toBe(expected.connectionTransport);
  if (expected.resolvedAPIBaseURLs) {
    expect(provider.relayRequested?.resolvedAPIBaseURLs ?? {}).toEqual(expected.resolvedAPIBaseURLs);
  }
  for (const [id, fields] of Object.entries(expected.models)) {
    expect(modelFields(provider.models.find((model) => model.id === id)), id).toEqual(fields);
  }
}

const noFamily = async () => undefined;

function enableAndWait(
  store: ReturnType<typeof createAppStore>,
  provider: Provider,
  model: AIModel,
): Promise<boolean> {
  return new Promise((resolve) => {
    enableProviderModelWithProbe(store, provider, model, { lookupFamily: noFamily, onProbeSettled: resolve });
  });
}

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
  rememberRelayCatalogEndpointTypes(PROVIDER_ID, undefined);
  clearRelayLazyProbeStates(PROVIDER_ID);
});

/* For the "could not be determined" scenario, run once per outcome in inconclusive according to the fixture $comment. */
const INCONCLUSIVE_CASE = 'enable_stops_at_an_inconclusive_first_candidate_and_pins_nothing';
const EXPLICIT_ENABLE_CASE = 'enable_on_a_user_chosen_connection_protocol_sends_no_probe_and_pins_nothing';
const enableRuns: Array<readonly [string, FixtureScenario, string | null]> = scenarios('enable_').flatMap((item) => {
  if (item.caseId !== INCONCLUSIVE_CASE) return [[item.caseId, item, null] as const];
  return fixture.probeOutcomeRules.inconclusive.map((outcome) => {
    const ping = Object.fromEntries(Object.entries(item.ping ?? {}).map(([key, value]) => (
      [key, value === 'http_429' ? outcome : value]
    )));
    return [`${item.caseId} [${outcome}]`, { ...item, ping }, outcome] as const;
  });
});

/* ── RL2-PROBE-04 lazy verification on enable ── */

describe('RL2-PROBE-04 lazy verification when enabling a single model', () => {
  it('RL2-PROBE-04 every enable scenario in the fixture is in the execution list (not green because a loop was skipped)', () => {
    const names = enableRuns.map(([name]) => name);
    expect(names).toEqual(expect.arrayContaining([
      EXPLICIT_ENABLE_CASE,
      'enable_moves_on_after_a_route_level_403',
      ...fixture.probeOutcomeRules.inconclusive.map((outcome) => `${INCONCLUSIVE_CASE} [${outcome}]`),
    ]));
    expect(fixture.probeOutcomeRules.inconclusive).toEqual(
      ['http_400', 'http_401', 'http_403', 'http_422', 'http_429', 'http_5xx', 'network'],
    );
  });

  it.each(enableRuns)('RL2-PROBE-04 %s', async (_caseId, s, inconclusiveOutcome) => {
    const store = createAppStore();
    const provider = makeRelayProvider(s, []);
    store.getState().addProvider(provider);
    // The catalog result (endpoint types) is first cached in memory per connection: same key (provider.id) as the catalog sync path.
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, Object.fromEntries(
      (s.models ?? []).filter((item) => item.supportedEndpointTypes).map((item) => [item.id, item.supportedEndpointTypes!]),
    ));
    const pings = installFakeRelay(s);
    const target = (s.models ?? []).find((item) => item.id === s.enable)!;

    const enabled = enableAndWait(store, provider, makeModel(target));
    // Enable first, probe afterwards: the model is already in the enabled list before the probe returns.
    expect(store.getState().providers[0]!.models.map((model) => model.id)).toContain(s.enable);
    await enabled;

    expectScenarioState(store, s, pings);
    expectNoCapabilityTestRequests();
    // Not determined: within this session "Not connected · View reason" still gets this failure; user-selected connection protocol: no request sent, no lazy verification state kept.
    if (inconclusiveOutcome) expect(relayLazyProbeState(PROVIDER_ID, s.enable!)?.phase).toBe('failed');
    if (s.caseId === EXPLICIT_ENABLE_CASE) expect(relayLazyProbeState(PROVIDER_ID, s.enable!)).toBeUndefined();
  });

  it('RL2-PROBE-04 html_200 (2xx but a web page) is a route-level rejection: keeps trying the next candidate and ends up reachable', async () => {
    expect(fixture.probeOutcomeRules.routeRejected).toContain('html_200');
    expect(fixture.probeOutcomeRules.inconclusive).not.toContain('html_200');
    const base = scenario('enable_moves_on_after_a_route_level_403');
    const s: FixtureScenario = {
      ...base,
      ping: Object.fromEntries(Object.entries(base.ping ?? {}).map(([key, value]) => (
        [key, value === 'http_403_route' ? 'html_200' : value]
      ))),
    };
    expect(Object.values(s.ping!)).toContain('html_200');
    const store = createAppStore();
    const provider = makeRelayProvider(s, []);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, Object.fromEntries(
      (s.models ?? []).filter((item) => item.supportedEndpointTypes).map((item) => [item.id, item.supportedEndpointTypes!]),
    ));
    const pings = installFakeRelay(s);
    await enableAndWait(store, provider, makeModel((s.models ?? []).find((item) => item.id === s.enable)!));
    expectScenarioState(store, s, pings);
  });

  it('RL2-PROBE-04 models with a model-level protocol (any source), bulk enable, and local engines are not probed', async () => {
    const s = scenario('enable_probes_the_enabled_model_and_stores_reachable');
    const pings = installFakeRelay(s);

    const pinned = createAppStore();
    const pinnedProvider = makeRelayProvider(s, []);
    pinned.getState().addProvider(pinnedProvider);
    await expect(enableAndWait(pinned, pinnedProvider, makeModel({
      id: 'o3-pro', relayTransport: 'anthropic_messages', relayTransportSource: 'observed',
    }))).resolves.toBe(false);

    const bulk = createAppStore();
    const bulkProvider = makeRelayProvider(s, []);
    bulk.getState().addProvider(bulkProvider);
    replaceProviderModels(bulk, bulkProvider, [makeModel({ id: 'o3-pro' })]);

    const local = createAppStore();
    const localProvider = makeRelayProvider(s, [], {
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', engineProfile: 'ollama' },
    });
    local.getState().addProvider(localProvider);
    enableProviderModelWithProbe(local, localProvider, makeModel({ id: 'o3-pro' }));
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(pings).toEqual([]);
    expect(local.getState().providers[0]!.models.map((model) => model.id)).toEqual(['o3-pro']);
  });
});

/* ── RL2-PROBE-04 delivered upgrades to observed ── */

describe('RL2-PROBE-04 a_delivered_send_upgrades_reachable_to_observed（C3 R8）', () => {
  const s = scenario('a_delivered_send_upgrades_reachable_to_observed');

  it.each(s.before!.map((row) => [row.id, row] as const))('RL2-PROBE-04 model %s', (_id, row) => {
    const store = createAppStore();
    const startModel = makeModel(row);
    const startProvider = makeRelayProvider(s, [startModel]);
    store.getState().addProvider(startProvider);
    const before = store.getState().providers[0];

    // failed / partial output never reaches the delivered exit (the three send paths call reportSendCompletion only in the delivered branch).
    if (row.outcome === 'delivered') promoteRelayTransportOnDelivered(store, startProvider, startModel);

    const after = store.getState().providers[0]!;
    expect(modelFields(after.models[0])).toEqual(row.after);
    // No write when the value is unchanged: the store still holds the same provider object.
    if (row.outcome !== 'delivered' || row.after.relayTransportSource === row.relayTransportSource) {
      expect(after).toBe(before);
    }
  });

  it('RL2-PROBE-04 the delivered exit reportSendCompletion shared by the three send paths triggers the upgrade', () => {
    const store = createAppStore();
    const startModel = makeModel({ id: 'a', relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    const startProvider = makeRelayProvider(s, [startModel]);
    store.getState().addProvider(startProvider);

    reportSendCompletion({
      store,
      provider: startProvider,
      model: startModel,
      conversationId: 'conv-1',
      effectiveConversation: undefined,
      skillId: undefined,
      usage: undefined,
      cost: 0,
      costSource: 'unknown',
      servedModelID: undefined,
      processedAttachments: [],
      promptContext: { retrievalCost: 0 },
      sendStartedAt: Date.now(),
      completedAt: new Date().toISOString(),
    });

    expect(modelFields(store.getState().providers[0]!.models[0])).toEqual({
      relayTransport: 'openai_responses',
      relayTransportSource: 'observed',
    });
  });

  it('RL2-PROBE-04 model protocol changed during the send (differs from the protocol at send start): no upgrade', () => {
    const store = createAppStore();
    const startModel = makeModel({ id: 'a', relayTransport: 'openai_responses', relayTransportSource: 'reachable' });
    const startProvider = makeRelayProvider(s, [startModel]);
    store.getState().addProvider({
      ...startProvider,
      models: [makeModel({ id: 'a', relayTransport: 'anthropic_messages', relayTransportSource: 'reachable' })],
    });

    expect(promoteRelayTransportOnDelivered(store, startProvider, startModel)).toBe(false);
    expect(modelFields(store.getState().providers[0]!.models[0])).toEqual({
      relayTransport: 'anthropic_messages',
      relayTransportSource: 'reachable',
    });
  });
});

/* ── RL2-PROBE-05 re-detect ── */

describe('RL2-PROBE-05 re-detect', () => {
  it('RL2-PROBE-05 the re-detect scenarios in the fixture are in the execution list', () => {
    expect(scenarios('redetect_').map((item) => item.caseId)).toContain(
      'redetect_on_a_user_chosen_connection_protocol_clears_reachable_and_sends_no_probe',
    );
  });

  it.each(scenarios('redetect_').map((item) => [item.caseId, item] as const))('RL2-PROBE-05 %s', async (_caseId, s) => {
    const store = createAppStore();
    const models = (s.models ?? []).map((item) => makeModel(item, item.id === s.defaultModel));
    const provider = makeRelayProvider(s, models);
    store.getState().addProvider(provider);

    // The two kinds of negative cache this connection already has + one from another connection (must not be cleared along with them).
    const now = Date.now();
    const descriptor = locateCapabilityRecovery({
      status: 400, preToken: true, streamStarted: false, sideEffects: false,
      automaticRetryCount: 0, source: 'custom', structuredError: { error: { param: 'temperature' } },
      customAppliedPointers: { generation: ['/temperature'] },
    }, undefined)!;
    const rejection = { connectionId: PROVIDER_ID, canonicalModelId: 'gpt-4o-mini', finalTransport: 'openai_chat', runtimeRevision: 'r1' };
    const otherRejection = { ...rejection, connectionId: 'relay-other' };
    recordCapabilityRejection(rejection, descriptor, now);
    recordCapabilityRejection(otherRejection, descriptor, now);
    const toolCall = { accountId: 'account-a', connectionId: PROVIDER_ID, authMode: 'bearer', canonicalModelId: 'gpt-4o-mini', finalTransport: 'openai_chat' };
    recordToolCallSupportFalse(toolCall, now);
    expect(capabilityRejectionIsDormant(rejection, 'generation', 'custom', now + 1)).toBe(true);
    expect(toolCallSupportIsRememberedFalse(toolCall)).toBe(true);

    const pings = installFakeRelay(s);
    await redetectRelayModels(store, provider, { lookupFamily: noFamily });

    expectScenarioState(store, s, pings);
    expectNoCapabilityTestRequests();
    const negativeEntries = [
      capabilityRejectionIsDormant(rejection, 'generation', 'custom', now + 1),
      toolCallSupportIsRememberedFalse(toolCall),
    ].filter(Boolean).length;
    expect(negativeEntries).toBe(s.expect!.negativeCacheEntriesForConnection ?? 0);
    expect(capabilityRejectionIsDormant(otherRejection, 'generation', 'custom', now + 1)).toBe(true);
  });
  it('RD1-REDETECT-01 re-probe covers enabled models that have no protocol after clearing (user-sourced ones are not probed), and probes even when none is the default', async () => {
    const s: FixtureScenario = {
      caseId: 'rd1_redetect',
      test: 'RD1-REDETECT-01',
      // Only auto-detected connections are re-probed (a user-selected connection protocol is not probed).
      connection: { baseURL: 'https://relay.example.com/v1', transport: 'auto' },
      models: [
        { id: 'model-a', relayTransport: 'anthropic_messages', relayTransportSource: 'user' },
        { id: 'model-b', relayTransport: 'openai_chat_completions', relayTransportSource: 'reachable' },
        { id: 'model-c' },
      ],
      ping: { 'model-b@chat': 'ok', 'model-c@chat': 'ok', 'model-a@messages': 'ok', 'model-a@chat': 'ok' },
    };
    const store = createAppStore();
    const provider = makeRelayProvider(s, (s.models ?? []).map((item) => makeModel(item)));
    store.getState().addProvider(provider);
    const pings = installFakeRelay(s);

    await redetectRelayModels(store, provider, { lookupFamily: noFamily });

    expect(pings.map(([modelID]) => modelID)).toEqual(['model-b', 'model-c']);
    const saved = store.getState().providers[0]!;
    expect(saved.models.every((model) => model.isDefault === false)).toBe(true);
    expect(modelFields(saved.models.find((model) => model.id === 'model-a'))).toEqual({
      relayTransport: 'anthropic_messages',
      relayTransportSource: 'user',
    });
    expect(saved.models.find((model) => model.id === 'model-b')?.relayTransportSource).toBe('reachable');
    expect(saved.models.find((model) => model.id === 'model-c')?.relayTransportSource).toBe('reachable');
  });

  it('RL2-PROBE-05 local engine connection: clears reachable and the negative cache, refreshes the catalog, no re-probe', async () => {
    const s = scenario('redetect_clears_reachable_and_negative_cache_and_keeps_stronger_sources');
    const store = createAppStore();
    const models = (s.models ?? []).map((item) => makeModel(item, item.id === s.defaultModel));
    const provider = makeRelayProvider(s, models, {
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', engineProfile: 'ollama' },
    });
    store.getState().addProvider(provider);
    const toolCall = { accountId: 'account-a', connectionId: PROVIDER_ID, authMode: 'bearer', canonicalModelId: 'gpt-4o-mini', finalTransport: 'openai_chat' };
    recordToolCallSupportFalse(toolCall, Date.now());
    const pings = installFakeRelay(s);

    await redetectRelayModels(store, provider, { lookupFamily: noFamily });

    expect(pings).toEqual([]);
    expect(toolCallSupportIsRememberedFalse(toolCall)).toBe(false);
    const saved = store.getState().providers[0]!;
    expect(modelFields(saved.models.find((model) => model.id === 'o3-pro'))).toEqual({});
    expect(modelFields(saved.models.find((model) => model.id === 'gemini-2.5-pro'))).toEqual({
      relayTransport: 'gemini_generate_content',
      relayTransportSource: 'user',
    });
    expect(vi.mocked(fetch).mock.calls.some(([input, init]) => protocolOf(upstreamOf(input, init)) === 'models')).toBe(true);
  });
});

/* ── RL2-PROBESTATE: "Not connected" is invalidated by an effective key value change / a successful send ── */

describe('RL2-PROBESTATE "Not connected" is invalidated by an effective key value change / a successful send', () => {
  const FAILED = { phase: 'failed' as const, statusCode: 404 };
  const CATALOG = [
    { id: 'm', supportedEndpointTypes: ['openai'] },
    { id: 'm2', supportedEndpointTypes: ['openai'] },
    { id: 'n', supportedEndpointTypes: ['openai'] },
    { id: 'p', supportedEndpointTypes: ['openai'] },
  ];
  const AUTO = { baseURL: 'https://relay.example.com/v1', transport: 'auto' as const };

  /** Fake relay: the catalog succeeds or fails by key value (401 for failingSecrets); generation requests answer 200 per the ok list, 404 otherwise. */
  function installKeyedRelay(failingSecrets: string[], okPings: string[]): Array<[string, ShortTransport]> {
    const pings: Array<[string, ShortTransport]> = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = upstreamOf(input, init);
      const protocol = protocolOf(url);
      if (protocol === 'models') {
        const headers = JSON.stringify([...new Headers(init?.headers).entries()]);
        if (failingSecrets.some((secret) => headers.includes(secret))) {
          return new Response(JSON.stringify({ error: { message: 'invalid api key' } }), {
            status: 401, headers: { 'Content-Type': 'application/json' },
          });
        }
        const data = CATALOG.map((item) => ({ id: item.id, object: 'model', supported_endpoint_types: item.supportedEndpointTypes }));
        return new Response(JSON.stringify({ object: 'list', data }), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        });
      }
      if (!protocol) return new Response('not found', { status: 404 });
      const modelID = modelOf(url, init);
      pings.push([modelID, protocol]);
      return respondOutcome(okPings.includes(`${modelID}@${protocol}`) ? 'ok' : 'http_404');
    });
    return pings;
  }

  function bound(id: string, keyID: string, extra: Partial<AIModel> = {}): AIModel {
    return { ...makeModel({ id }), relayKeyID: keyID, ...extra };
  }

  /** Two keys: k (primary, value sk-kkk) / j (value sk-jjj). */
  function multiKeyProvider(models: AIModel[], kState?: 'ok' | 'invalid'): Provider {
    return makeRelayProvider({ caseId: 'probestate', test: 'RL2-PROBESTATE', connection: AUTO, models: CATALOG }, models, {
      apiKey: 'sk-kkk',
      relayKeys: [
        { id: 'k', apiKey: '', ...(kState ? { status: { state: kState, checkedAt: '2026-10-01T00:00:00.000Z' } } : {}) },
        { id: 'j', apiKey: 'sk-jjj' },
      ],
    });
  }

  function deliver(store: ReturnType<typeof createAppStore>, provider: Provider, model: AIModel) {
    reportSendCompletion({
      store,
      provider,
      model,
      conversationId: 'conv-1',
      effectiveConversation: undefined,
      skillId: undefined,
      usage: undefined,
      cost: 0,
      costSource: 'unknown',
      servedModelID: undefined,
      processedAttachments: [],
      promptContext: { retrievalCost: 0 },
      sendStartedAt: Date.now(),
      completedAt: new Date().toISOString(),
    });
  }

  /** The T1 re-probe runs in the background: wait for it to finish before asserting the request count. */
  const settleReprobes = () => __relayLazyReprobesSettledForTest();

  const endpointTypes = Object.fromEntries(CATALOG.map((item) => [item.id, item.supportedEndpointTypes]));

  it('RL2-PROBESTATE-01 multi-key: changing the value of K -> M bound to K is cleared and re-probed once; N bound to J is untouched', async () => {
    const store = createAppStore();
    const provider = multiKeyProvider([bound('m', 'k'), bound('n', 'j')]);
    store.getState().addProvider(provider);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm', FAILED);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'n', FAILED);
    const pings = installKeyedRelay([], ['m@chat', 'n@chat']);

    await expect(applyRelayKeyOperation(store, provider, { type: 'replaceSecret', id: 'k', apiKey: 'sk-kkk-new' })).resolves.toBe(true);
    await settleReprobes();

    expect(pings).toEqual([['m', 'chat']]);
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toBeUndefined();
    expect(store.getState().providers[0]!.models.find((model) => model.id === 'm')?.relayTransportSource).toBe('reachable');
    expect(relayLazyProbeState(PROVIDER_ID, 'n')).toEqual(FAILED);
  });

  it('RL2-PROBESTATE-02 multi-key: the K catalog fetch succeeds and K status is written healthy -> the "Not connected" of M is kept, 0 lazy verification requests', async () => {
    const store = createAppStore();
    const provider = multiKeyProvider([bound('m', 'k'), bound('n', 'j')], 'invalid');
    store.getState().addProvider(provider);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm', FAILED);
    const pings = installKeyedRelay([], ['m@chat']);

    await expect(refreshRelayCatalogInStore(store, provider, { onlyKeyIDs: ['k'] })).resolves.toMatchObject({ state: 'loaded' });
    await settleReprobes();

    expect(store.getState().providers[0]!.relayKeys?.[0]?.status?.state).toBe('ok');
    expect(pings).toEqual([]);
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toEqual(FAILED);
  });

  it('RL2-PROBESTATE-03 single key: changing the primary key value -> all "Not connected" are cleared, models with a protocol are not re-probed; saving the same value or changing to empty does not count', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider({ caseId: 'probestate', test: 'RL2-PROBESTATE', connection: AUTO, models: CATALOG }, [
      makeModel({ id: 'm' }),
      makeModel({ id: 'p', relayTransport: 'openai_chat_completions', relayTransportSource: 'reachable' }),
    ]);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm', FAILED);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'p', FAILED);
    const pings = installKeyedRelay([], ['m@chat', 'p@chat']);

    // Saving the same value when editing the connection: not a value change.
    await expect(updateProviderKey(store, provider, 'sk-test')).resolves.toBe(true);
    await settleReprobes();
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toEqual(FAILED);
    expect(pings).toEqual([]);

    // Changed to empty (key removed): not a value change.
    await expect(updateProviderKey(store, store.getState().providers[0]!, '')).resolves.toBe(true);
    await settleReprobes();
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toEqual(FAILED);
    expect(pings).toEqual([]);

    await expect(updateProviderKey(store, store.getState().providers[0]!, 'sk-test-new')).resolves.toBe(true);
    await settleReprobes();

    expect(pings).toEqual([['m', 'chat']]);
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toBeUndefined();
    expect(relayLazyProbeState(PROVIDER_ID, 'p')).toBeUndefined();
  });

  it('RL2-PROBESTATE-04 successful send (K was already healthy) -> that model is cleared, 0 lazy verifications; another "Not connected" on the same connection is untouched', async () => {
    const store = createAppStore();
    const provider = multiKeyProvider([bound('m', 'k'), bound('m2', 'k')], 'ok');
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm', FAILED);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm2', FAILED);
    const pings = installKeyedRelay([], ['m@chat', 'm2@chat']);

    deliver(store, provider, provider.models[0]!);
    await settleReprobes();

    expect(pings).toEqual([]);
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toBeUndefined();
    expect(relayLazyProbeState(PROVIDER_ID, 'm2')).toEqual(FAILED);
  });

  it('RL2-PROBESTATE-05 successful send writes K from not-healthy to healthy -> another "Not connected" on the same key is kept, 0 lazy verifications', async () => {
    const store = createAppStore();
    const provider = multiKeyProvider([bound('m', 'k'), bound('m2', 'k')], 'invalid');
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm', FAILED);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm2', FAILED);
    const pings = installKeyedRelay([], ['m@chat', 'm2@chat']);

    deliver(store, provider, provider.models[0]!);
    await settleReprobes();

    expect(store.getState().providers[0]!.relayKeys?.[0]?.status?.state).toBe('ok');
    expect(pings).toEqual([]);
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toBeUndefined();
    expect(relayLazyProbeState(PROVIDER_ID, 'm2')).toEqual(FAILED);
  });

  it('RL2-PROBESTATE-06 while verifying: neither a primary key value change (T1) nor a successful send (T2) clears it', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider({ caseId: 'probestate', test: 'RL2-PROBESTATE', connection: AUTO, models: CATALOG }, [
      makeModel({ id: 'm' }),
    ]);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    __setRelayLazyProbeStateForTest(PROVIDER_ID, 'm', { phase: 'inFlight' });
    const pings = installKeyedRelay([], ['m@chat']);

    await expect(updateProviderKey(store, provider, 'sk-test-new')).resolves.toBe(true);
    await settleReprobes();
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toEqual({ phase: 'inFlight' });

    deliver(store, store.getState().providers[0]!, store.getState().providers[0]!.models[0]!);
    await settleReprobes();
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toEqual({ phase: 'inFlight' });
    expect(pings).toEqual([]);
  });

  it('RL2-PROBESTATE-07 changing the value of K while a probe is in flight: the old failing result is discarded and not recorded as "Not connected"', async () => {
    const store = createAppStore();
    const provider = multiKeyProvider([bound('n', 'j')]);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    const pings: string[] = [];
    let openGate!: () => void;
    const gate = new Promise<void>((resolve) => { openGate = resolve; });
    let pingStarted!: () => void;
    const started = new Promise<void>((resolve) => { pingStarted = resolve; });
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = upstreamOf(input, init);
      const protocol = protocolOf(url);
      if (protocol === 'models') {
        const data = CATALOG.map((item) => ({ id: item.id, object: 'model', supported_endpoint_types: item.supportedEndpointTypes }));
        return new Response(JSON.stringify({ object: 'list', data }), {
          status: 200, headers: { 'Content-Type': 'application/json' },
        });
      }
      if (!protocol) return new Response('not found', { status: 404 });
      pings.push(modelOf(url, init));
      pingStarted();
      await gate;
      return respondOutcome('http_404');
    });

    const settled = enableAndWait(store, provider, makeModel({ id: 'm' }));
    await started;
    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toEqual({ phase: 'inFlight' });
    expect(store.getState().providers[0]!.models.find((model) => model.id === 'm')?.relayKeyID ?? 'k').toBe('k');

    await expect(applyRelayKeyOperation(store, store.getState().providers[0]!, { type: 'replaceSecret', id: 'k', apiKey: 'sk-kkk-new' }))
      .resolves.toBe(true);
    openGate();
    await settled;
    await settleReprobes();

    expect(relayLazyProbeState(PROVIDER_ID, 'm')).toBeUndefined();
    expect(pings.every((modelID) => modelID === 'm')).toBe(true);
  });
});

/* ── RL2-KEYSTATUS key status truthfully reflects real requests ── */

describe('RL2-KEYSTATUS lazy verification / adding a key / replacing the primary key / single-key catalog refresh write key status', () => {
  const AUTO = { baseURL: 'https://relay.example.com/v1', transport: 'auto' as const };
  const CATALOG = [{ id: 'm', supportedEndpointTypes: ['openai'] }, { id: 'n', supportedEndpointTypes: ['openai'] }];
  const endpointTypes = Object.fromEntries(CATALOG.map((item) => [item.id, item.supportedEndpointTypes]));
  const base: FixtureScenario = { caseId: 'keystatus', test: 'RL2-KEYSTATUS', connection: AUTO, models: CATALOG };

  /** Fake relay: the catalog is always 200 (records which key value each catalog request used); generation requests answer per outcomes (404 by default). */
  function installRelay(outcomes: Record<string, string>): { pings: string[]; catalogSecrets: string[] } {
    const pings: string[] = [];
    const catalogSecrets: string[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = upstreamOf(input, init);
      const protocol = protocolOf(url);
      if (protocol === 'models') {
        const headers = JSON.stringify([...new Headers(init?.headers).entries()]);
        catalogSecrets.push(['sk-test', 'sk-second', 'sk-test-new'].filter((secret) => headers.includes(`${secret}"`) || headers.includes(`${secret}\\"`)).join(','));
        const data = CATALOG.map((item) => ({ id: item.id, object: 'model', supported_endpoint_types: item.supportedEndpointTypes }));
        return new Response(JSON.stringify({ object: 'list', data }), { status: 200, headers: { 'Content-Type': 'application/json' } });
      }
      if (!protocol) return new Response('not found', { status: 404 });
      const modelID = modelOf(url, init);
      pings.push(`${modelID}@${protocol}`);
      return respondOutcome(outcomes[`${modelID}@${protocol}`] ?? 'http_404');
    });
    return { pings, catalogSecrets };
  }

  const saved = (store: ReturnType<typeof createAppStore>) => store.getState().providers[0]!;

  it('RL2-KEYSTATUS-03 lazy verification passes -> written on the key bound to the verified model (multi-key: j healthy, primary key untouched)', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, [], {
      relayKeys: [{ id: 'k', apiKey: '' }, { id: 'j', apiKey: 'sk-second' }],
      catalogModels: CATALOG.map((item) => ({ ...makeModel(item), relayListedByKeyIDs: ['j'] })),
    });
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    installRelay({ 'm@chat': 'ok' });

    await expect(enableAndWait(store, provider, makeModel({ id: 'm' }))).resolves.toBe(true);

    const after = saved(store);
    expect(after.models.find((model) => model.id === 'm')?.relayKeyID).toBe('j');
    expect(after.relayKeys?.find((key) => key.id === 'j')?.status).toEqual({ state: 'ok', checkedAt: expect.any(String) });
    expect(after.relayKeys?.find((key) => key.id === 'k')?.status).toBeUndefined();
  });

  it('RL2-KEYSTATUS-03 single-key lazy verification passes -> materializes one initial entry and writes healthy', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, []);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    installRelay({ 'm@chat': 'ok' });

    await expect(enableAndWait(store, provider, makeModel({ id: 'm' }))).resolves.toBe(true);

    expect(saved(store).relayKeys).toEqual([{ id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: expect.any(String) } }]);
    expect(saved(store).models[0]).not.toHaveProperty('relayKeyID');
  });

  it('RL2-KEYSTATUS-04 lazy verification route 404 -> key status unchanged (single key does not build a list); 401 -> invalid', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, []);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    const { pings } = installRelay({});

    await expect(enableAndWait(store, provider, makeModel({ id: 'm' }))).resolves.toBe(false);
    expect(pings.length).toBeGreaterThan(0);
    expect(saved(store)).not.toHaveProperty('relayKeys');

    installRelay({ 'n@chat': 'http_401' });
    await expect(enableAndWait(store, saved(store), makeModel({ id: 'n' }))).resolves.toBe(false);
    expect(saved(store).relayKeys).toEqual([
      { id: 'initial', apiKey: '', status: { state: 'invalid', httpStatus: 401, checkedAt: expect.any(String) } },
    ]);
  });

  it('RL2-KEYSTATUS-06 adding a second key to a single key -> everything is re-fetched, the primary key also gets a status', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, [makeModel({ id: 'm', relayTransport: 'openai_chat_completions', relayTransportSource: 'user' })]);
    store.getState().addProvider(provider);
    const { catalogSecrets } = installRelay({});

    await expect(applyRelayKeyOperation(store, provider, { type: 'add', id: 'k2', name: 'Second', apiKey: 'sk-second' }))
      .resolves.toBe(true);

    expect(catalogSecrets).toEqual(['sk-test', 'sk-second']);
    expect(saved(store).relayKeys?.map((key) => [key.id, key.status?.state])).toEqual([['initial', 'ok'], ['k2', 'ok']]);
  });

  it('RL2-KEYSTATUS-07 replacing the primary key (single-entry list) -> that key status is cleared first, the new status is written after the fetch', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, [makeModel({ id: 'm' })], {
      relayKeys: [{ id: 'initial', apiKey: '', status: { state: 'invalid', httpStatus: 401, checkedAt: '2026-10-01T00:00:00.000Z' } }],
    });
    store.getState().addProvider(provider);
    installRelay({});

    await expect(updateProviderKey(store, provider, 'sk-test-new')).resolves.toBe(true);
    expect(saved(store).relayKeys).toEqual([{ id: 'initial', apiKey: '' }]);

    await expect(refreshRelayCatalogInStore(store, saved(store))).resolves.toMatchObject({ state: 'loaded' });
    expect(saved(store).relayKeys).toEqual([{ id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: expect.any(String) } }]);
  });

  it('RL2-KEYSTATUS-09 single-key catalog refresh (refreshRelayCatalogInStore / re-detect) both write the primary key status', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, [makeModel({ id: 'm', relayTransport: 'openai_chat_completions', relayTransportSource: 'user' })]);
    store.getState().addProvider(provider);
    installRelay({});

    await expect(refreshRelayCatalogInStore(store, provider)).resolves.toMatchObject({ state: 'loaded' });
    expect(saved(store).relayKeys).toEqual([{ id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: expect.any(String) } }]);

    const second = createAppStore();
    second.getState().addProvider(provider);
    await expect(redetectRelayModels(second, provider, { lookupFamily: noFamily })).resolves.toBe('loaded');
    expect(second.getState().providers[0]!.relayKeys?.map((key) => key.status?.state)).toEqual(['ok']);
  });

  it('RL2-KEYSTATUS-15 request carries no key (auth is none): after a successful catalog fetch relayKeys still does not exist', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, [makeModel({ id: 'm', relayTransport: 'openai_chat_completions', relayTransportSource: 'user' })], {
      apiKey: '',
      apiKeyPreview: '',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'none' },
    });
    store.getState().addProvider(provider);
    installRelay({});

    await expect(refreshRelayCatalogInStore(store, provider)).resolves.toMatchObject({ state: 'loaded' });

    expect(saved(store).relayKeys).toBeUndefined();
  });

  it('RL2-KEYSTATUS-12 effective key value replaced while lazy verification is in flight -> the old request result does not write key status', async () => {
    const store = createAppStore();
    const provider = makeRelayProvider(base, []);
    store.getState().addProvider(provider);
    rememberRelayCatalogEndpointTypes(PROVIDER_ID, endpointTypes);
    let openGate!: () => void;
    const gate = new Promise<void>((resolve) => { openGate = resolve; });
    let pingStarted!: () => void;
    const started = new Promise<void>((resolve) => { pingStarted = resolve; });
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const url = upstreamOf(input, init);
      if (protocolOf(url) === 'models' || !protocolOf(url)) return new Response('not found', { status: 404 });
      pingStarted();
      await gate;
      return respondOutcome('http_401');
    });

    const settled = enableAndWait(store, provider, makeModel({ id: 'm' }));
    await started;
    // Change the value directly (not via the value-change entry, so the T1 re-probe does not send another request).
    store.getState().updateProvider(PROVIDER_ID, { apiKey: 'sk-test-new' });
    openGate();
    await settled;

    expect(saved(store)).not.toHaveProperty('relayKeys');
  });
});
