import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayCapabilityOverrides, RelayModelTransport } from '@oriveo/shared';
import { RELAY_WEB_FRAGMENT_TEMPLATES, type RelayWebTransport } from '@oriveo/shared/relay/web-fragments';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import { createAppStore } from '../store/app-store';

const mockGetSyncAdapter = vi.fn<() => unknown>(() => null);
vi.mock('../sync', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../sync')>()),
  getSyncAdapter: () => mockGetSyncAdapter(),
}));

import { relayWebProbeSource, runRelayWebProbe } from '../relay-web-probe-ops';
import { relayCapabilityTestPlan } from '../relay-capability-test-ops';
import { readStoredRelayWebFragments, replaceRelayWebFragments } from '../chat/relay-web-fragments';
import {
  clearRelayWebProbeRecordsConnection,
  currentRelayWebProbeRecord,
  readRelayWebProbeRecord,
} from '../chat/relay-web-probe-records';

/* ── Fixture (source of truth): shared/test-fixtures/relay/web-probe.v1.json + capability-test.v1.json builtins ── */

interface RequestShape {
  caseId: string;
  transport: RelayWebTransport;
  fragment: Record<string, unknown>;
  mustContain: Record<string, unknown>;
  mustContainPrompt: boolean;
  mustNotContain: string[];
}
interface EvidenceCase {
  caseId: string;
  transport: RelayWebTransport;
  status: number | null;
  sse?: string[];
  body?: unknown;
}
interface WebProbeFixture {
  forms: { probe: string[]; never: string[] };
  request: { prompt: string; outputLimit: number; timeoutSeconds: number };
  requestShapes: RequestShape[];
  evidenceCases: EvidenceCase[];
}
interface CapabilityFixture {
  builtins: { imagePNGBase64: string; tool: { name: string } };
}

function loadFixture<T>(name: string): T {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', name);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as T;
    dir = path.dirname(dir);
  }
  throw new Error(`${name} not found`);
}

const fixture = loadFixture<WebProbeFixture>('web-probe.v1.json');
const capability = loadFixture<CapabilityFixture>('capability-test.v1.json');

/** "builtins.x.y" in mustNotContain refers to the builtins of capability-test.v1.json. */
function builtin(pathText: string): string {
  let value: unknown = { builtins: capability.builtins };
  for (const key of pathText.split('.')) value = (value as Record<string, unknown>)[key];
  return String(value);
}

/** mustContain: objects are compared as a subset by key; arrays mean "every expected element is present in the actual array" (tools bundled by the builder may coexist, e.g. image_generation for Responses). */
function isSubset(expected: unknown, actual: unknown): boolean {
  if (Array.isArray(expected)) {
    return Array.isArray(actual) && expected.every((item) => actual.some((entry) => isSubset(item, entry)));
  }
  if (expected && typeof expected === 'object') {
    if (!actual || typeof actual !== 'object' || Array.isArray(actual)) return false;
    return Object.entries(expected).every(([key, value]) =>
      key in (actual as Record<string, unknown>) && isSubset(value, (actual as Record<string, unknown>)[key]));
  }
  return expected === actual;
}

function evidenceCase(caseId: string): EvidenceCase {
  return fixture.evidenceCases.find((item) => item.caseId === caseId)!;
}

/* ── Fake relay: the production default send really calls fetch ── */

interface Captured { raw: string; body: Record<string, unknown> }

function installFakeRelay(c: EvidenceCase): Captured[] {
  const captured: Captured[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (_input, init) => {
    const raw = String(init?.body ?? '');
    captured.push({ raw, body: JSON.parse(raw) as Record<string, unknown> });
    if (c.sse) {
      return new Response(`${c.sse.join('\n')}\n`, { status: c.status ?? 200, headers: { 'Content-Type': 'text/event-stream' } });
    }
    return new Response(JSON.stringify(c.body), { status: c.status ?? 500, headers: { 'Content-Type': 'application/json' } });
  });
  return captured;
}

/* ── Construction ── */

const PROVIDER_ID = 'relay-1';
const MODEL_ID = 'probe-model';
const NOW_ISO = '2026-10-13T12:00:00.000Z';
const now = () => Date.parse(NOW_ISO);

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

function storeWith(provider: Provider) {
  const store = createAppStore();
  store.getState().addProvider(provider);
  return store;
}

function savedModel(store: ReturnType<typeof createAppStore>): AIModel {
  return store.getState().providers.find((item) => item.id === PROVIDER_ID)!.models.find((item) => item.id === MODEL_ID)!;
}

const CHAT_FRAGMENT = fixture.requestShapes.find((item) => item.transport === 'openai_chat_completions')!.fragment;

beforeEach(() => {
  localStorage.clear();
  mockGetSyncAdapter.mockReset();
  mockGetSyncAdapter.mockReturnValue(null);
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('relay web probe request (one streaming request, chat builder + saved fragment)', () => {
  for (const shape of fixture.requestShapes) {
    it(`RL2-WEBPROBE-03 SHAPE-${shape.caseId}`, async () => {
      replaceRelayWebFragments(PROVIDER_ID, { [shape.transport]: shape.fragment });
      const store = storeWith(makeProvider(shape.transport, makeModel(MODEL_ID)));
      const searched = fixture.evidenceCases.find((item) => item.transport === shape.transport && item.caseId.endsWith('_searched'))!;
      const captured = installFakeRelay(searched);

      const run = await runRelayWebProbe(store, PROVIDER_ID, MODEL_ID, { now });

      expect(run.outcome).toBe('completed');
      expect(captured).toHaveLength(1);
      const request = captured[0]!;
      expect(isSubset(shape.mustContain, request.body)).toBe(true);
      if (shape.mustContainPrompt) expect(request.raw.includes(fixture.request.prompt)).toBe(true);
      for (const key of shape.mustNotContain) expect(request.raw.includes(builtin(key))).toBe(false);
      // The output limit goes through the builder's original field (same channel as the capability test).
      expect(request.raw).toMatch(new RegExp(`"(max_tokens|max_output_tokens|maxOutputTokens)":${fixture.request.outputLimit}\\b`));
      expect(request.body.stream ?? true).toBe(true);
    });
  }
});

/* -- When the first-send protocol has no stored fragment, the panel web item probes with that protocol's built-in template; the template is the effective fragment, so the record and web override are written and no fragment is stored -- */

describe('relay web probe with the default settings (template)', () => {
  const key = { connectionId: PROVIDER_ID, modelId: MODEL_ID, transport: 'openai_chat_completions' };
  const TEMPLATE = RELAY_WEB_FRAGMENT_TEMPLATES.openai_chat_completions;

  it('RL2-WEBPROBE-01 no saved fragment: web listed, request carries the template, web override written', async () => {
    // Fragments of other protocols do not count.
    replaceRelayWebFragments(PROVIDER_ID, { anthropic_messages: { tools: [{ type: 'web_search_20250305', name: 'web_search' }] } });
    const store = storeWith(makeProvider('openai_chat_completions', makeModel(MODEL_ID, { image: { value: true, source: 'user' } })));
    const provider = store.getState().providers[0]!;
    expect(relayCapabilityTestPlan(savedModel(store), provider)).toEqual(['text', 'toolCall', 'web']);
    expect(relayWebProbeSource(provider, savedModel(store))).toBe('template');
    const captured = installFakeRelay(evidenceCase('chat_url_citation_searched'));

    const run = await runRelayWebProbe(store, PROVIDER_ID, MODEL_ID, { now });

    expect(run).toMatchObject({ outcome: 'completed', result: 'searched', webSource: 'template', overrideWritten: true });
    expect(captured).toHaveLength(1);
    expect(isSubset(TEMPLATE, captured[0]!.body)).toBe(true);
    expect(captured[0]!.body.web_search_options).toEqual({});
    expect(captured[0]!.raw.includes(fixture.request.prompt)).toBe(true);
    // Record hash = the template's canonical hash; the template is the effective fragment, so this is the current record; the web override is written from it (tested) and no fragment is stored.
    const record = { result: 'searched', source: 'tested', at: NOW_ISO, fragmentHash: relayWebFragmentHash(TEMPLATE) };
    expect(readRelayWebProbeRecord(key)).toEqual(record);
    expect(currentRelayWebProbeRecord(key, TEMPLATE)).toEqual(record);
    expect(savedModel(store).relayCapabilityOverrides).toEqual({
      image: { value: true, source: 'user' }, web: { value: true, source: 'tested' },
    });
    expect(readStoredRelayWebFragments(PROVIDER_ID).openai_chat_completions).toBeUndefined();
  });

  it('RL2-WEBPROBE-01 a saved fragment is used instead of the template', async () => {
    const saved = { web_search_options: { search_context_size: 'low' } };
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: saved });
    const store = storeWith(makeProvider('openai_chat_completions', makeModel(MODEL_ID)));
    expect(relayWebProbeSource(store.getState().providers[0]!, savedModel(store))).toBe('saved');
    const captured = installFakeRelay(evidenceCase('chat_url_citation_searched'));

    const run = await runRelayWebProbe(store, PROVIDER_ID, MODEL_ID, { now });

    expect(run).toMatchObject({ outcome: 'completed', result: 'searched', webSource: 'saved', overrideWritten: true });
    expect(captured[0]!.body.web_search_options).toEqual({ search_context_size: 'low' });
    expect(readRelayWebProbeRecord(key)?.fragmentHash).toBe(relayWebFragmentHash(saved));
    expect(savedModel(store).relayCapabilityOverrides).toEqual({ web: { value: true, source: 'tested' } });
  });
});

describe('relay web probe forms', () => {
  it('RL2-WEBPROBE-13 FORMS no probe outside RELAY', async () => {
    expect(fixture.forms.probe).toEqual(['RELAY']);
    const nonRelay: Record<string, Partial<Provider>> = {
      BYOK: { kind: 'openai', relayKind: undefined },
      SUB: { kind: 'openai', authMode: 'subscription', relayKind: undefined },
    };
    // The community edition has no hosted forms; the shared fixture still lists them.
    const neverForms = fixture.forms.never.filter((form: string) => form in nonRelay);
    expect(Object.keys(nonRelay).sort()).toEqual([...neverForms].sort());
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const fetchSpy = vi.spyOn(globalThis, 'fetch');
    for (const form of neverForms) {
      const store = storeWith(makeProvider('openai_chat_completions', makeModel(MODEL_ID), nonRelay[form]));
      const run = await runRelayWebProbe(store, PROVIDER_ID, MODEL_ID, { now });
      expect(run.outcome).toBe('unavailable');
    }
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe('relay web probe override and record', () => {
  const key = { connectionId: PROVIDER_ID, modelId: MODEL_ID, transport: 'openai_chat_completions' };

  async function probe(caseId: string, overrides?: RelayCapabilityOverrides) {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('openai_chat_completions', makeModel(MODEL_ID, overrides)));
    installFakeRelay(evidenceCase(caseId));
    const run = await runRelayWebProbe(store, PROVIDER_ID, MODEL_ID, { now });
    return { run, store };
  }

  it('RL2-WEBPROBE-10 OVERRIDE searched writes web {true, tested} and a tested record', async () => {
    const { run, store } = await probe('chat_url_citation_searched', { image: { value: true, source: 'user' } });
    expect(run.result).toBe('searched');
    expect(run.evidenceUrls).toEqual(['https://news.example.com/top']);
    expect(savedModel(store).relayCapabilityOverrides).toEqual({
      image: { value: true, source: 'user' },
      web: { value: true, source: 'tested' },
    });
    const hash = relayWebFragmentHash(CHAT_FRAGMENT);
    expect(readRelayWebProbeRecord(key)).toEqual({ result: 'searched', source: 'tested', at: NOW_ISO, fragmentHash: hash });
    expect(currentRelayWebProbeRecord(key, CHAT_FRAGMENT)?.result).toBe('searched');
    expect(currentRelayWebProbeRecord(key, { web_search_options: { search_context_size: 'low' } })).toBeUndefined();
  });

  it('RL2-WEBPROBE-OVERRIDE rejected writes web {false, tested} and a rejected record', async () => {
    const { run, store } = await probe('chat_400_rejected');
    expect(run.result).toBe('rejected');
    expect(savedModel(store).relayCapabilityOverrides).toEqual({ web: { value: false, source: 'tested' } });
    expect(readRelayWebProbeRecord(key)?.result).toBe('rejected');
  });

  it('RL2-WEBPROBE-OVERRIDE silent writes no override, records silent', async () => {
    const { run, store } = await probe('chat_text_only_silent');
    expect(run.result).toBe('silent');
    expect(savedModel(store).relayCapabilityOverrides).toBeUndefined();
    expect(readRelayWebProbeRecord(key)?.result).toBe('silent');
  });

  it('RL2-WEBPROBE-OVERRIDE undetermined writes neither override nor record', async () => {
    const { run, store } = await probe('chat_503_undetermined');
    expect(run.result).toBe('undetermined');
    expect(savedModel(store).relayCapabilityOverrides).toBeUndefined();
    expect(readRelayWebProbeRecord(key)).toBeUndefined();
  });

  it('RL2-WEBPROBE-OVERRIDE a user-set web override is kept', async () => {
    const { run, store } = await probe('chat_400_rejected', { web: { value: true, source: 'user' } });
    expect(run.result).toBe('rejected');
    expect(savedModel(store).relayCapabilityOverrides).toEqual({ web: { value: true, source: 'user' } });
    expect(readRelayWebProbeRecord(key)?.result).toBe('rejected');
  });

  it('RL2-WEBPROBE-OVERRIDE records are deleted with the connection', async () => {
    await probe('chat_url_citation_searched');
    expect(readRelayWebProbeRecord(key)).toBeDefined();
    clearRelayWebProbeRecordsConnection(PROVIDER_ID);
    expect(readRelayWebProbeRecord(key)).toBeUndefined();
  });
});
