import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayCapabilityOverrides, RelayModelTransport } from '@oriveo/shared';
import { relayCapabilityTestMessages } from '@oriveo/core/providers/relay-capability-test';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { createAppStore } from '../store/app-store';

import { sendStream } from '../providers/service';
import {
  canTestRelayModelCapabilities,
  hasTestedRelayCapabilityOverrides,
  relayCapabilityTestStreamOptions,
  relayCapabilityTestPlan,
  restoreRelayAutomaticCapabilities,
  runRelayCapabilityTest,
  type RelayCapabilityTestProgress,
} from '../relay-capability-test-ops';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import { replaceRelayWebFragments } from '../chat/relay-web-fragments';
import {
  readRelayWebProbeAutoHistory,
  readRelayWebProbeRecord,
  writeRelayWebProbeAutoHistory,
} from '../chat/relay-web-probe-records';

/* ── Fixture (source of truth): shared/test-fixtures/relay/capability-test.v1.json ── */

type Short = 'chat' | 'responses' | 'messages' | 'gemini';
type Kind = 'text' | 'image' | 'tool';
interface FixtureResponse {
  status?: number;
  contentType?: string;
  body?: unknown;
  bodyByTransport?: Record<Short, unknown>;
  network?: boolean;
  hang?: boolean;
  drip?: boolean;
}
interface Scenario {
  caseId: string;
  transport: Short;
  model: string;
  existingOverrides?: RelayCapabilityOverrides;
  /** Override default connection fields (disableResponseStorage and other relayRequested fields). */
  connection?: Partial<NonNullable<Provider['relayRequested']>>;
  responses: Record<Kind, string>;
  expect: {
    requests: Kind[];
    totalHttpRequests?: number;
    outcome: 'completed' | 'text_failed';
    items: Record<string, string>;
    reasons?: Record<string, string>;
    text?: { verdict: string; reason: string };
    overrides: RelayCapabilityOverrides;
    bodyExtra?: Record<string, unknown>;
  };
}
interface RequestShape {
  path: string;
  query?: Record<string, string>;
  bodySubset: Record<string, unknown>;
  bodySubsetByKind: Partial<Record<Kind, Record<string, unknown>>>;
}
interface Fixture {
  builtins: { imagePNGBase64: string; tool: { name: string } };
  transports: Record<Short, RelayModelTransport>;
  requestShapes: Record<Short, RequestShape>;
  mustContain: Record<Kind, string[]>;
  mustNotContain: Record<Kind, string[]>;
  responses: Record<string, FixtureResponse>;
  scenarios: Scenario[];
  restoreAutomatic: { cases: Array<{ caseId: string; before: RelayCapabilityOverrides; after: RelayCapabilityOverrides }> };
}

const fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'capability-test.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('capability-test.v1.json not found');
})();

/** hang / drip use an injected short deadline; the production value (30 seconds) is asserted separately by RD4-DEADLINE-01. */
const SHORT_DEADLINE_MS = 300;

function withModel<T>(value: T, modelID: string): T {
  return JSON.parse(JSON.stringify(value).split('{{model}}').join(modelID)) as T;
}

function isSubset(expected: unknown, actual: unknown): boolean {
  if (Array.isArray(expected)) {
    return Array.isArray(actual) && actual.length === expected.length
      && expected.every((item, index) => isSubset(item, actual[index]));
  }
  if (expected && typeof expected === 'object') {
    if (!actual || typeof actual !== 'object' || Array.isArray(actual)) return false;
    return Object.entries(expected).every(([key, value]) =>
      key in (actual as Record<string, unknown>) && isSubset(value, (actual as Record<string, unknown>)[key]));
  }
  return expected === actual;
}

/* ── Fake relay: the production default send really calls fetch; the request body tells which kind of test request it is ── */

interface Captured { kind: Kind; url: string; raw: string; body: Record<string, unknown>; headers: Record<string, string> }

function upstreamOf(input: RequestInfo | URL, init?: RequestInit): string {
  return new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input instanceof Request ? input.url : input);
}

function kindOf(body: string): Kind {
  if (body.includes(fixture.builtins.imagePNGBase64)) return 'image';
  if (body.includes(fixture.builtins.tool.name)) return 'tool';
  return 'text';
}

function headersOf(init?: RequestInit): Record<string, string> {
  const out: Record<string, string> = {};
  new Headers(init?.headers).forEach((value, key) => { out[key] = value; });
  return out;
}

function respond(response: FixtureResponse, transport: Short, signal: AbortSignal | null | undefined): Promise<Response> {
  if (response.network) return Promise.reject(new TypeError('Failed to fetch'));
  if (response.hang) {
    return new Promise<Response>((_resolve, reject) => {
      signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    });
  }
  if (response.drip) {
    let timer: ReturnType<typeof setInterval> | undefined;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        const encoder = new TextEncoder();
        timer = setInterval(() => controller.enqueue(encoder.encode(': ping\n\n')), 100);
      },
      cancel() { clearInterval(timer); },
    });
    signal?.addEventListener('abort', () => clearInterval(timer), { once: true });
    return Promise.resolve(new Response(stream, { status: 200, headers: { 'Content-Type': 'text/event-stream' } }));
  }
  const body = response.bodyByTransport ? response.bodyByTransport[transport] : response.body;
  return Promise.resolve(new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status: response.status,
    headers: { 'Content-Type': response.contentType! },
  }));
}

function installFakeRelay(s: Scenario, onRequest?: (kind: Kind) => void): Captured[] {
  const captured: Captured[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const raw = String(init?.body ?? '');
    // The first-send protocol being decided is enough to list the web item (the template is used when no fragment is stored). This group only measures text / vision / tools,
    // the web probe answers 500 (undecidable: no record, no override change) and is not counted in requests; the web item is covered separately in RD4-WEB.
    if (raw.includes(webFixture.request.prompt)) {
      return new Response('{"error":{"message":"down"}}', { status: 500, headers: { 'Content-Type': 'application/json' } });
    }
    const kind = kindOf(raw);
    captured.push({ kind, url: upstreamOf(input, init), raw, body: JSON.parse(raw), headers: headersOf(init) });
    onRequest?.(kind);
    return respond(fixture.responses[s.responses[kind]]!, s.transport, init?.signal);
  });
  return captured;
}

/* ── Construction ── */

const PROVIDER_ID = 'relay-1';

function makeModel(id: string, overrides?: RelayCapabilityOverrides): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '',
    ...(overrides ? { relayCapabilityOverrides: overrides } : {}),
  };
}

function makeProvider(transport: RelayModelTransport, model: AIModel, extra: Partial<Provider> = {}): Provider {
  return {
    id: PROVIDER_ID,
    kind: 'relay',
    status: { kind: 'connected' },
    models: [model],
    catalogModels: [{ ...model, isDefault: false }, makeModel('other-model')],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
    baseURLText: 'https://relay.example.com',
    relayKind: 'openai_compatible',
    relayRequested: { transport, authMode: 'auto' },
    ...extra,
  };
}

function savedProvider(store: ReturnType<typeof createAppStore>): Provider {
  return store.getState().providers.find((item) => item.id === PROVIDER_ID)!;
}

function scenario(caseId: string): Scenario {
  return fixture.scenarios.find((item) => item.caseId === caseId)!;
}

function storeFor(s: Scenario) {
  const store = createAppStore();
  const transport = fixture.transports[s.transport];
  store.getState().addProvider(makeProvider(transport, makeModel(s.model, s.existingOverrides), {
    relayRequested: { transport, authMode: 'auto', ...s.connection },
  }));
  return store;
}

async function runScenario(s: Scenario) {
  const store = storeFor(s);
  const captured = installFakeRelay(s);
  const fetchSpy = vi.mocked(globalThis.fetch);
  const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

  expect(result.outcome).toBe(s.expect.outcome);
  expect(result.items).toEqual(s.expect.items);
  for (const [item, reason] of Object.entries(s.expect.reasons ?? {})) {
    expect(result.results[item as 'image' | 'toolCall']?.reason).toBe(reason);
  }
  if (s.expect.text) {
    expect({ verdict: result.results.text?.verdict, reason: result.results.text?.reason }).toEqual(s.expect.text);
  }
  expect(captured.map((item) => item.kind)).toEqual(s.expect.requests);
  if (s.expect.totalHttpRequests !== undefined) expect(fetchSpy).toHaveBeenCalledTimes(s.expect.totalHttpRequests);

  const shape = withModel(fixture.requestShapes[s.transport], s.model);
  const expand = (value: string) => value.split('{{png}}').join(fixture.builtins.imagePNGBase64);
  for (const request of captured) {
    const url = new URL(request.url);
    expect(url.pathname).toBe(shape.path);
    for (const [key, value] of Object.entries(shape.query ?? {})) expect(url.searchParams.get(key)).toBe(value);
    expect(isSubset({ ...shape.bodySubset, ...s.expect.bodyExtra }, request.body)).toBe(true);
    const byKind = shape.bodySubsetByKind[request.kind];
    if (byKind) expect(isSubset(byKind, request.body)).toBe(true);
    for (const value of fixture.mustContain[request.kind].map(expand)) {
      expect(request.raw.includes(value) || request.raw.includes(value.split('/').join('\\/'))).toBe(true);
    }
    for (const value of fixture.mustNotContain[request.kind].map(expand)) expect(request.raw.includes(value)).toBe(false);
  }
  // Model after the production write-back: the enabled list and the catalog entry with the same id are both changed; other models are untouched.
  const provider = savedProvider(store);
  expect(provider.models[0]!.relayCapabilityOverrides ?? {}).toEqual(s.expect.overrides);
  expect(provider.catalogModels.find((item) => item.id === s.model)!.relayCapabilityOverrides ?? {})
    .toEqual(s.expect.overrides);
  expect(provider.catalogModels.find((item) => item.id === 'other-model')!.relayCapabilityOverrides).toBeUndefined();
  return { result, captured, store };
}

beforeEach(() => {
  localStorage.clear();
});

afterEach(() => {
  vi.restoreAllMocks();
});

/* ── T3 executor ── */

describe('RL2-PROBE-06 T3 capability test executor (streaming, same path as chat, once per item)', () => {
  it.each(fixture.scenarios.map((item) => [item.caseId, item] as const))('RL2-PROBE-06 %s', async (_caseId, s) => {
    await runScenario(s);
  });

  it('RL2-PROBE-06 auth uses the chat production primitive (auto -> protocol default auth)', async () => {
    const s = fixture.scenarios.find((item) => item.transport === 'messages')!;
    const store = createAppStore();
    store.getState().addProvider(makeProvider(fixture.transports.messages, makeModel(s.model, s.existingOverrides)));
    const captured = installFakeRelay(s);

    await runRelayCapabilityTest(store, PROVIDER_ID, s.model);

    const config = JSON.parse(captured[0]!.headers['x-relay-proxy-config'] ?? '{}') as { authMode?: string; apiKey?: string };
    expect(config.authMode).toBe('x_api_key');
    expect(config.apiKey).toBe('sk-test');
  });

  it('RL2-PROBE-06 per-item progress: reports in-progress before sending, reports the result after reading', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    installFakeRelay(s);
    const progress: RelayCapabilityTestProgress[] = [];

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { onProgress: (event) => progress.push(event) });

    // The web item (listed once the first-send protocol is decided; the template is used when no fragment is stored) goes last.
    expect(result.plan).toEqual(['text', 'image', 'toolCall', 'web']);
    expect(result.webSource).toBe('template');
    expect(progress.map((event) => event.running)).toEqual(['text', null, 'image', null, 'toolCall', null, 'web', null]);
    expect(Object.keys(progress.at(-1)!.results)).toEqual(['text', 'image', 'toolCall', 'web']);
    expect(result.results.text).toMatchObject({ verdict: 'accepted', reason: 'ok', status: 200 });
    expect(typeof result.results.text?.elapsedMs).toBe('number');
    expect(result.written).toBe(true);
  });

  it('RL2-PROBE-06 request construction fails (address fails the safety policy): the item is undetermined / network, nothing sent, nothing written', async () => {
    const store = createAppStore();
    store.getState().addProvider(makeProvider('openai_chat_completions', makeModel('m'), {
      baseURLText: 'http://relay.example.com',
      relayRequested: { transport: 'openai_chat_completions', authMode: 'auto', securityMode: 'remote_https' },
    }));
    const fetchSpy = vi.spyOn(globalThis, 'fetch');

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, 'm');

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(result.outcome).toBe('text_failed');
    expect(result.results.text).toMatchObject({ verdict: 'undetermined', reason: 'network' });
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toBeUndefined();
  });

  it('RL2-PROBE-06 entry scope matches the per-model probe: a local engine connection cannot be tested', () => {
    const model = makeModel('m');
    const chat = makeProvider('openai_chat_completions', model);
    expect(canTestRelayModelCapabilities(chat, model)).toBe(true);
    const local = makeProvider('openai_chat_completions', model, {
      relayRequested: { transport: 'openai_chat_completions', authMode: 'bearer', engineProfile: 'ollama' },
    });
    expect(canTestRelayModelCapabilities(local, model)).toBe(false);
  });

  it('RL2-PROBE-06 the effective protocol is not one of the four: no entry; when both items are user overrides the web item can still be listed: entry remains', () => {
    const allUser = makeModel('m', { image: { value: true, source: 'user' }, toolCall: { value: false, source: 'user' } });
    const oneUser = makeModel('m', { image: { value: true, source: 'user' } });
    const llama = { ...makeModel('m'), relayTransport: 'llamacpp_native' as const, relayTransportSource: 'user' as const };
    expect(canTestRelayModelCapabilities(makeProvider('openai_chat_completions', allUser), allUser)).toBe(true);
    expect(canTestRelayModelCapabilities(makeProvider('openai_chat_completions', oneUser), oneUser)).toBe(true);
    expect(canTestRelayModelCapabilities(makeProvider('openai_chat_completions', llama), llama)).toBe(false);
    expect(canTestRelayModelCapabilities(makeProvider('llamacpp_native', makeModel('m')), makeModel('m'))).toBe(false);
  });
});

/* ── Deadline ── */

describe('RD4-DEADLINE total deadline per item', () => {
  it('RD4-DEADLINE-01 text_hang_times_out_and_stops: hangs without responding -> timeout, only text sent, nothing written', async () => {
    const { result } = await runScenario(scenario('text_hang_times_out_and_stops'));
    expect(result.results.text?.elapsedMs).toBeGreaterThanOrEqual(SHORT_DEADLINE_MS - 20);
  });

  it('RD4-DEADLINE-02 image_drip_is_cut_by_total_deadline: continuously dripping comment lines are also cut by the total deadline', async () => {
    const { result } = await runScenario(scenario('image_drip_is_cut_by_total_deadline'));
    expect(result.results.image?.elapsedMs).toBeLessThan(SHORT_DEADLINE_MS * 4);
  });
});

/* ── Same path ── */

describe('RD4-PATH same path as chat', () => {
  it('RD4-PATH-01 the text request equals the request chat send produces for the same message and options; model bound to the second key -> auth uses the second key', async () => {
    const s = scenario('all_accepted_writes_true');
    const model = { ...makeModel(s.model), relayKeyID: 'k2' };
    const provider = makeProvider(fixture.transports[s.transport], model, {
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k2', apiKey: 'sk-second' }],
    });
    const store = createAppStore();
    store.getState().addProvider(provider);
    const captured = installFakeRelay(s);

    await runRelayCapabilityTest(store, PROVIDER_ID, s.model);
    const testRequest = captured[0]!;

    // Chat production send: service.sendStream -> relay adapter -> core orchestration, with the same options and synthesized message.
    const saved = savedProvider(store);
    const savedModel = saved.models[0]!;
    const handle = sendStream(
      'relay',
      resolveProviderAPIKey(saved, savedModel.id),
      savedModel.id,
      relayCapabilityTestMessages('text'),
      saved.baseURLText,
      relayCapabilityTestStreamOptions(saved, savedModel, 'text'),
    );
    const reader = handle.stream.getReader();
    while (!(await reader.read()).done) { /* read until the stream ends */ }
    const chatRequest = captured[captured.length - 1]!;
    expect(chatRequest).not.toBe(testRequest);

    expect(testRequest.url).toBe(chatRequest.url);
    expect(testRequest.headers).toEqual(chatRequest.headers);
    expect(testRequest.raw).toBe(chatRequest.raw);
    const config = JSON.parse(testRequest.headers['x-relay-proxy-config']!) as { apiKey?: string };
    expect(config.apiKey).toBe('sk-second');
  });

  it('RD4-PATH-02 text_404_sends_one_request_without_protocol_fallback: exactly 1 HTTP request overall', async () => {
    await runScenario(scenario('text_404_sends_one_request_without_protocol_fallback'));
  });
});

/* ── Interruption ── */

describe('RD4-STOP every interruption is accounted for', () => {
  it('RD4-STOP-01 cancel: aborts the in-flight request, sends nothing further, keeps completed items, writes nothing', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    const controller = new AbortController();
    const kinds: Kind[] = [];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (_input, init) => {
      const kind = kindOf(String(init?.body ?? ''));
      kinds.push(kind);
      if (kind === 'text') return respond(fixture.responses.ok!, 'chat', init?.signal);
      const pending = respond(fixture.responses.hang!, 'chat', init?.signal);
      controller.abort();
      return pending;
    });

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { signal: controller.signal });

    expect(result.outcome).toBe('stopped');
    expect(result.stopReason).toBe('cancelled');
    expect(kinds).toEqual(['text', 'image']);
    expect(Object.keys(result.results)).toEqual(['text']);
    expect(result.written).toBe(false);
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toBeUndefined();
  });

  it('RD4-STOP-02 connection changed: stops before the next item is sent, keeps completed items, writes nothing', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    const captured = installFakeRelay(s, (kind) => {
      if (kind === 'image') store.getState().updateProvider(PROVIDER_ID, { apiKey: 'sk-other' });
    });

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model);

    expect(result.outcome).toBe('stopped');
    expect(result.stopReason).toBe('connection');
    expect(captured.map((item) => item.kind)).toEqual(['text', 'image']);
    expect(result.results.image?.verdict).toBe('accepted');
    expect(result.written).toBe(false);
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toBeUndefined();
  });

  it('RD4-STOP-03 protocol changed: stops before write-back, keeps the three verdicts, writes nothing', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    installFakeRelay(s, (kind) => {
      if (kind !== 'tool') return;
      const current = savedProvider(store);
      store.getState().updateProvider(PROVIDER_ID, {
        models: current.models.map((model) => ({ ...model, relayTransport: 'openai_responses', relayTransportSource: 'user' })),
      });
    });

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model);

    expect(result.outcome).toBe('stopped');
    expect(result.stopReason).toBe('protocol');
    expect(Object.keys(result.results)).toEqual(['text', 'image', 'toolCall']);
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toBeUndefined();
  });

  it('RD4-STOP-04 model deleted: stops before the next item is sent, writes nothing', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    const captured = installFakeRelay(s, (kind) => {
      if (kind === 'image') store.getState().updateProvider(PROVIDER_ID, { models: [] });
    });

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model);

    expect(result.outcome).toBe('stopped');
    expect(result.stopReason).toBe('unavailable');
    expect(captured.map((item) => item.kind)).toEqual(['text', 'image']);
    const provider = savedProvider(store);
    expect(provider.catalogModels.find((item) => item.id === s.model)!.relayCapabilityOverrides).toBeUndefined();
  });

  it('RD4-STOP-02 connection and protocol change together: reason = connection; model deleted at the same time: reason = unavailable', async () => {
    const s = scenario('all_accepted_writes_true');
    const both = storeFor(s);
    installFakeRelay(s, (kind) => {
      if (kind === 'image') {
        both.getState().updateProvider(PROVIDER_ID, {
          apiKey: 'sk-other',
          relayRequested: { transport: 'openai_responses', authMode: 'auto' },
        });
      }
    });
    expect(await runRelayCapabilityTest(both, PROVIDER_ID, s.model)).toMatchObject({ outcome: 'stopped', stopReason: 'connection' });
    vi.restoreAllMocks();

    const all = storeFor(s);
    installFakeRelay(s, (kind) => {
      if (kind === 'image') all.getState().updateProvider(PROVIDER_ID, { apiKey: 'sk-other', models: [] });
    });
    expect(await runRelayCapabilityTest(all, PROVIDER_ID, s.model)).toMatchObject({ outcome: 'stopped', stopReason: 'unavailable' });
  });

  it('RL2-PROBE-06 each item builds its request from the latest connection (same read as the identity check), not the snapshot taken at start', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    const captured = installFakeRelay(s, (kind) => {
      if (kind !== 'text') return;
      const current = savedProvider(store);
      store.getState().updateProvider(PROVIDER_ID, {
        relayRequested: { ...current.relayRequested!, customUserAgent: 'ua/2' },
      });
    });

    await runRelayCapabilityTest(store, PROVIDER_ID, s.model);

    const ua = (request: Captured) => (JSON.parse(request.headers['x-relay-proxy-config']!) as { customUserAgent?: string }).customUserAgent;
    expect(captured.map(ua)).toEqual([undefined, 'ua/2', 'ua/2']);
  });

  it('RD4-STOP-05 throws before write-back: the executor throws to the caller, nothing is written', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    installFakeRelay(s);
    vi.spyOn(store.getState(), 'updateProvider').mockImplementation(() => { throw new Error('store down'); });

    await expect(runRelayCapabilityTest(store, PROVIDER_ID, s.model)).rejects.toThrow('store down');
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toBeUndefined();
  });

  it('RD4-STOP-04 model is already untestable when opened (protocol not one of the four): stops directly at unavailable, zero requests', async () => {
    const llama = { ...makeModel('m'), relayTransport: 'llamacpp_native' as const, relayTransportSource: 'user' as const };
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    const store = createAppStore();
    store.getState().addProvider(makeProvider('openai_chat_completions', llama));

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, 'm');

    expect(result).toMatchObject({ outcome: 'stopped', stopReason: 'unavailable', results: {}, written: false });
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

/* ── T4 restore to auto ── */

describe('RL2-PROBE-06 T4 restore to auto', () => {
  it.each(fixture.restoreAutomatic.cases.map((item) => [item.caseId, item] as const))('RL2-PROBE-06 %s', (_caseId, item) => {
    const store = createAppStore();
    store.getState().addProvider(makeProvider('openai_chat_completions', makeModel('m', item.before)));
    expect(hasTestedRelayCapabilityOverrides(savedProvider(store).models[0]!)).toBe(true);

    expect(restoreRelayAutomaticCapabilities(store, PROVIDER_ID, 'm')).toBe(true);

    const provider = savedProvider(store);
    for (const model of [provider.models[0]!, provider.catalogModels.find((entry) => entry.id === 'm')!]) {
      if (Object.keys(item.after).length === 0) {
        expect(model).not.toHaveProperty('relayCapabilityOverrides');
      } else {
        expect(model.relayCapabilityOverrides).toEqual(item.after);
      }
    }
    expect(hasTestedRelayCapabilityOverrides(provider.models[0]!)).toBe(false);
  });
});

describe('RL2-KEYSTATUS capability test writes key status on every item request', () => {
  it('RL2-KEYSTATUS-05 capability test 200 -> effective key is healthy (single key materializes one initial entry)', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    installFakeRelay(s);

    await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(savedProvider(store).relayKeys).toEqual([
      { id: 'initial', apiKey: '', status: { state: 'ok', checkedAt: expect.any(String) } },
    ]);
  });

  it('RL2-KEYSTATUS-05 text item 401 -> that key is invalid (multi-key: written on the key the model is bound to)', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = createAppStore();
    const transport = fixture.transports[s.transport];
    store.getState().addProvider(makeProvider(transport, { ...makeModel(s.model), relayKeyID: 'k2' }, {
      relayRequested: { transport, authMode: 'auto' },
      relayKeys: [{ id: 'initial', apiKey: '' }, { id: 'k2', apiKey: 'sk-second' }],
    }));
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('{"error":{"message":"Invalid API key"}}', {
      status: 401, headers: { 'Content-Type': 'application/json' },
    }));

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(result.outcome).toBe('text_failed');
    const keys = savedProvider(store).relayKeys!;
    expect(keys[1]!.status).toEqual({ state: 'invalid', httpStatus: 401, checkedAt: expect.any(String) });
    expect(keys[0]!.status).toBeUndefined();
  });

  it('RL2-KEYSTATUS-18 2xx but the body is a web page / content cannot be parsed -> not written as healthy', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('<!doctype html><html><body>console</body></html>', {
      status: 200, headers: { 'Content-Type': 'text/html; charset=utf-8' },
    }));

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(result.results.text?.verdict).not.toBe('accepted');
    expect(savedProvider(store)).not.toHaveProperty('relayKeys');
  });

  it('RL2-KEYSTATUS-12 connection identity changed during the request -> the result of this item is not written to key status', async () => {
    const s = scenario('all_accepted_writes_true');
    const store = storeFor(s);
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => {
      store.getState().updateProvider(PROVIDER_ID, { apiKey: 'sk-other' });
      return new Response('{"error":{"message":"Invalid API key"}}', { status: 401, headers: { 'Content-Type': 'application/json' } });
    });

    await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(savedProvider(store)).not.toHaveProperty('relayKeys');
  });
});

/* ── Test panel web item (web-probe.v1.json triggers: manual probe) ── */

interface WebProbeFixture {
  request: { prompt: string };
  requestShapes: Array<{ transport: string; fragment: Record<string, unknown> }>;
  evidenceCases: Array<{ caseId: string; status: number | null; sse?: string[]; body?: unknown }>;
}

const webFixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-probe.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as WebProbeFixture;
    dir = path.dirname(dir);
  }
  throw new Error('web-probe.v1.json not found');
})();

const WEB_CHAT_FRAGMENT = webFixture.requestShapes.find((item) => item.transport === 'openai_chat_completions')!.fragment;

describe('RD4-WEB test panel 4th item: web', () => {
  type SentKind = Kind | 'web';

  /** Fake relay: a request carrying the probe hint is the web item and answers per the web-probe fixture; everything else follows the capability test fixture. */
  function installWebFakeRelay(s: Scenario, webCaseId: string): SentKind[] {
    const sent: SentKind[] = [];
    const web = webFixture.evidenceCases.find((item) => item.caseId === webCaseId)!;
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const raw = String(init?.body ?? '');
      if (raw.includes(webFixture.request.prompt)) {
        sent.push('web');
        if (web.sse) {
          return new Response(`${web.sse.join('\n')}\n`, { status: web.status ?? 200, headers: { 'Content-Type': 'text/event-stream' } });
        }
        return new Response(JSON.stringify(web.body), { status: web.status ?? 500, headers: { 'Content-Type': 'application/json' } });
      }
      const kind = kindOf(raw);
      sent.push(kind);
      return respond(fixture.responses[s.responses[kind]]!, s.transport, init?.signal);
    });
    return sent;
  }

  /** Auto history: the connection window already holds 10 entries, one of which has the same (connection, model, protocol, fragment hash) as this run. */
  function fillAutoHistory(modelId: string) {
    const fragmentHash = relayWebFragmentHash(WEB_CHAT_FRAGMENT);
    const sentAt = new Date().toISOString();
    const entries = Array.from({ length: 10 }, (_, index) => ({
      connectionId: PROVIDER_ID,
      modelId: index === 0 ? modelId : `other-${index}`,
      transport: 'openai_chat_completions',
      fragmentHash,
      sentAt,
    }));
    writeRelayWebProbeAutoHistory(entries);
    return readRelayWebProbeAutoHistory();
  }

  it('RD4-WEB-01 the web item is listed once the first-send protocol is decided (last); listed whether or not a fragment is stored (the template is used when none is)', () => {
    const model = makeModel('m');
    const provider = makeProvider('openai_chat_completions', model);
    expect(relayCapabilityTestPlan(model, provider)).toEqual(['text', 'image', 'toolCall', 'web']);
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: WEB_CHAT_FRAGMENT });
    expect(relayCapabilityTestPlan(model, provider)).toEqual(['text', 'image', 'toolCall', 'web']);
    const allUser = makeModel('m', { image: { value: true, source: 'user' }, toolCall: { value: false, source: 'user' } });
    expect(relayCapabilityTestPlan(allUser, makeProvider('openai_chat_completions', allUser))).toEqual(['text', 'web']);
    // Only another protocol has a fragment: still listed (this protocol's template is used).
    replaceRelayWebFragments(PROVIDER_ID, { openai_responses: { tools: [{ type: 'web_search' }] } });
    expect(relayCapabilityTestPlan(model, provider)).toEqual(['text', 'image', 'toolCall', 'web']);
  });

  it('RD4-WEB-01b vision and tools are both set by the user: the entry remains as long as web can be listed (first-send protocol decided)', () => {
    const allUser = makeModel('m', { image: { value: true, source: 'user' }, toolCall: { value: false, source: 'user' } });
    const provider = makeProvider('openai_chat_completions', allUser);
    expect(canTestRelayModelCapabilities(provider, allUser)).toBe(true);
    expect(relayCapabilityTestPlan(allUser, provider)).toEqual(['text', 'web']);
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: WEB_CHAT_FRAGMENT });
    expect(canTestRelayModelCapabilities(provider, allUser)).toBe(true);
  });

  it('RD4-WEB-02 step 4 runs the manual web probe: not in auto history, not blocked by cap / dedupe, searched writes the web override and counts as written', async () => {
    const s = scenario('all_accepted_writes_true');
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: WEB_CHAT_FRAGMENT });
    const store = storeFor(s);
    const history = fillAutoHistory(s.model);
    const sent = installWebFakeRelay(s, 'chat_url_citation_searched');
    const progress: RelayCapabilityTestProgress[] = [];

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, {
      deadlineMs: SHORT_DEADLINE_MS,
      onProgress: (event) => progress.push(event),
    });

    expect(result.outcome).toBe('completed');
    expect(result.plan).toEqual(['text', 'image', 'toolCall', 'web']);
    expect(sent).toEqual(['text', 'image', 'tool', 'web']);
    expect(progress.map((event) => event.running)).toEqual(['text', null, 'image', null, 'toolCall', null, 'web', null]);
    expect(result.results.web).toMatchObject({ verdict: 'searched', reason: 'ok', status: 200 });
    expect(typeof result.results.web?.elapsedMs).toBe('number');
    expect(result.written).toBe(true);
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toEqual({
      image: { value: true, source: 'tested' },
      toolCall: { value: true, source: 'tested' },
      web: { value: true, source: 'tested' },
    });
    expect(readRelayWebProbeRecord({ connectionId: PROVIDER_ID, modelId: s.model, transport: 'openai_chat_completions' })?.result)
      .toBe('searched');
    expect(readRelayWebProbeAutoHistory()).toEqual(history);
  });

  it('RD4-WEB-03 only web is writable: rejected writes web {false, tested}, written = true', async () => {
    const s = scenario('all_items_user_set_sends_text_only');
    const store = createAppStore();
    const model = makeModel(s.model, s.existingOverrides);
    store.getState().addProvider(makeProvider('openai_chat_completions', model));
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: WEB_CHAT_FRAGMENT });
    const sent = installWebFakeRelay({ ...s, transport: 'chat' }, 'chat_400_rejected');

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(result.plan).toEqual(['text', 'web']);
    expect(sent).toEqual(['text', 'web']);
    expect(result.results.web?.verdict).toBe('rejected');
    expect(result.written).toBe(true);
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toEqual({
      ...s.existingOverrides,
      web: { value: false, source: 'tested' },
    });
  });

  it('RD4-WEB-04 silent: no override written, written does not become true because of web', async () => {
    const s = scenario('all_items_user_set_sends_text_only');
    const store = createAppStore();
    store.getState().addProvider(makeProvider('openai_chat_completions', makeModel(s.model, s.existingOverrides)));
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: WEB_CHAT_FRAGMENT });
    installWebFakeRelay({ ...s, transport: 'chat' }, 'chat_text_only_silent');

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(result.results.web?.verdict).toBe('silent');
    expect(result.written).toBe(false);
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toEqual(s.existingOverrides);
  });

  it('RD4-WEB-05 text fails: web is not sent, no result, nothing written', async () => {
    const s = scenario('text_rejected_stops_and_writes_nothing');
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: WEB_CHAT_FRAGMENT });
    const store = storeFor(s);
    const sent = installWebFakeRelay(s, 'chat_url_citation_searched');

    const result = await runRelayCapabilityTest(store, PROVIDER_ID, s.model, { deadlineMs: SHORT_DEADLINE_MS });

    expect(result.outcome).toBe('text_failed');
    expect(result.plan).toEqual(['text', 'image', 'toolCall', 'web']);
    expect(sent).toEqual(['text']);
    expect(result.results.web).toBeUndefined();
    expect(savedProvider(store).models[0]!.relayCapabilityOverrides).toBeUndefined();
    expect(readRelayWebProbeRecord({ connectionId: PROVIDER_ID, modelId: s.model, transport: 'openai_chat_completions' }))
      .toBeUndefined();
  });
});
