/**
  * Wiring of the automatic trigger for relay web probing.
  * Source of truth: `shared/test-fixtures/relay/web-probe.v1.json` (triggers, evidenceCases, requestShapes).
  * The fake fetch replaces only the network; save / enable / probe / record / override all run through production code.
 */
import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider, RelayCapabilityOverrides, RelayModelTransport } from '@oriveo/shared';
import { RELAY_WEB_FRAGMENT_TEMPLATES, type RelayWebFragment } from '@oriveo/shared/relay/web-fragments';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import { createAppStore } from '../store/app-store';

const mockGetSyncAdapter = vi.fn<() => unknown>(() => null);
vi.mock('../sync', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../sync')>()),
  getSyncAdapter: () => mockGetSyncAdapter(),
}));
vi.mock('../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../infra/storage/partition')>()),
  getActiveUIDSync: () => 'account-a',
}));

import { saveRelayWebSearchSettings } from '../provider-ops';
import { clearRelayLazyProbeStates, enableProviderModelWithProbe } from '../relay-model-probe-ops';
import { runRelayWebProbe } from '../relay-web-probe-ops';
import { __relayWebAutoProbesSettledForTest } from '../relay-web-probe-auto';
import { readStoredRelayWebFragments, replaceRelayWebFragments } from '../chat/relay-web-fragments';
import {
  appendRelayWebProbeAutoHistory,
  readRelayWebProbeAutoHistory,
  readRelayWebProbeRecord,
  writeRelayWebProbeRecord,
} from '../chat/relay-web-probe-records';

/* ── Fixture ── */

interface EvidenceCase {
  caseId: string;
  status: number | null;
  sse?: string[];
  body?: unknown;
}
interface WebProbeFixture {
  request: { prompt: string };
  triggers: { perSave: number; perConnectionPerWindow: number };
  requestShapes: Array<{ transport: string; fragment: RelayWebFragment }>;
  evidenceCases: EvidenceCase[];
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
const evidence = (caseId: string) => fixture.evidenceCases.find((item) => item.caseId === caseId)!;
const CHAT_FRAGMENT = fixture.requestShapes.find((item) => item.transport === 'openai_chat_completions')!.fragment;
const CHANGED_CHAT_FRAGMENT: RelayWebFragment = { web_search_options: { search_context_size: 'low' } };

/* ── Fake relay: requests with the fixed hint are web probes, the rest are lazy-verification pings ── */

interface ProbeCall { modelId: string; protocol: string }

function upstreamOf(input: RequestInfo | URL, init?: RequestInit): string {
  return new Headers(init?.headers).get('X-Relay-Upstream-URL') ?? String(input instanceof Request ? input.url : input);
}

function respond(c: EvidenceCase): Response {
  if (c.sse) {
    return new Response(`${c.sse.join('\n')}\n`, { status: c.status ?? 200, headers: { 'Content-Type': 'text/event-stream' } });
  }
  return new Response(JSON.stringify(c.body), { status: c.status ?? 500, headers: { 'Content-Type': 'application/json' } });
}

function installFakeRelay(options: {
  probe: EvidenceCase;
  pingOK?: (url: string) => boolean;
  onProbe?: (modelId: string) => void;
}): ProbeCall[] {
  const probes: ProbeCall[] = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = upstreamOf(input, init);
    const raw = String(init?.body ?? '');
    if (raw.includes(fixture.request.prompt)) {
      const modelId = String((JSON.parse(raw) as { model?: unknown }).model ?? '');
      options.onProbe?.(modelId);
      probes.push({ modelId, protocol: url });
      return respond(options.probe);
    }
    if (options.pingOK?.(url)) {
      return new Response('{"id":"ok"}', { status: 200, headers: { 'Content-Type': 'application/json' } });
    }
    return new Response(JSON.stringify({ error: { message: 'not found' } }), {
      status: 404, headers: { 'Content-Type': 'application/json' },
    });
  });
  return probes;
}

/* ── Construction ── */

const PROVIDER_ID = 'relay-1';
const NOW_ISO = '2026-10-13T12:00:00.000Z';
const now = () => Date.parse(NOW_ISO);

function makeModel(id: string, overrides?: RelayCapabilityOverrides): AIModel {
  return {
    id,
    name: id,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '',
    ...(overrides ? { relayCapabilityOverrides: overrides } : {}),
  };
}

function makeProvider(transport: RelayModelTransport | 'auto', models: AIModel[], catalog: AIModel[] = models): Provider {
  return {
    id: PROVIDER_ID,
    kind: 'relay',
    status: { kind: 'connected' },
    models,
    catalogModels: catalog.map((model) => ({ ...model })),
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
    baseURLText: 'https://relay.example.com/v1',
    relayKind: 'openai_compatible',
    relayRequested: { transport, authMode: 'bearer' },
  };
}

function storeWith(provider: Provider) {
  const store = createAppStore();
  store.getState().addProvider(provider);
  return store;
}

function savedProvider(store: ReturnType<typeof createAppStore>): Provider {
  return store.getState().providers.find((item) => item.id === PROVIDER_ID)!;
}

function overridesOf(store: ReturnType<typeof createAppStore>, modelId: string): RelayCapabilityOverrides | undefined {
  return savedProvider(store).models.find((item) => item.id === modelId)!.relayCapabilityOverrides;
}

const chatKey = (modelId: string) => ({ connectionId: PROVIDER_ID, modelId, transport: 'openai_chat_completions' });

/** Fill the auto quota in this connection's rolling window (selection no longer sends; only the save itself can clear the override). */
function fillDailyCap() {
  for (let index = 0; index < fixture.triggers.perConnectionPerWindow; index += 1) {
    appendRelayWebProbeAutoHistory({
      connectionId: PROVIDER_ID,
      modelId: `x${index}`,
      transport: 'anthropic_messages',
      fragmentHash: 'h',
      sentAt: '2026-10-13T10:00:00.000Z',
    });
  }
}

beforeEach(() => {
  localStorage.clear();
  mockGetSyncAdapter.mockReset();
  mockGetSyncAdapter.mockReturnValue(null);
});

afterEach(async () => {
  await __relayWebAutoProbesSettledForTest();
  vi.restoreAllMocks();
  clearRelayLazyProbeStates(PROVIDER_ID);
});

/* ── RL2-WEBPROBE-WIRE-save ── */

describe('relay web probe runs automatically after saving fragments', () => {
  it('RL2-WEBPROBE-11 WIRE-save', async () => {
    const ids = ['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7'];
    const store = storeWith(makeProvider('openai_chat_completions', ids.map((id) => makeModel(id))));
    const hash = relayWebFragmentHash(CHAT_FRAGMENT);
    const seenAtSend: Array<{ inHistory: boolean; previousRecorded: boolean }> = [];
    const probes = installFakeRelay({
      probe: evidence('chat_url_citation_searched'),
      onProbe: (modelId) => {
        const index = ids.indexOf(modelId);
        seenAtSend.push({
          // History is written before sending.
          inHistory: readRelayWebProbeAutoHistory().some((entry) => entry.modelId === modelId && entry.fragmentHash === hash),
          // Serial: the next probe is sent only after the previous probe has written its record.
          previousRecorded: index === 0 || readRelayWebProbeRecord(chatKey(ids[index - 1]!)) !== undefined,
        });
      },
    });

    const saved = await saveRelayWebSearchSettings(store, savedProvider(store), { openai_chat_completions: CHAT_FRAGMENT }, { now });
    expect(saved).toBe(true);
    await __relayWebAutoProbesSettledForTest();

    const probed = ids.slice(0, fixture.triggers.perSave);
    expect(probes.map((item) => item.modelId)).toEqual(probed);
    expect(seenAtSend.every((item) => item.inHistory && item.previousRecorded)).toBe(true);
    for (const id of probed) {
      expect(readRelayWebProbeRecord(chatKey(id))).toEqual({ result: 'searched', source: 'tested', at: NOW_ISO, fragmentHash: hash });
      expect(overridesOf(store, id)).toEqual({ web: { value: true, source: 'tested' } });
    }
    // Untested models: zero requests, no record.
    for (const id of ids.slice(fixture.triggers.perSave)) {
      expect(readRelayWebProbeRecord(chatKey(id))).toBeUndefined();
      expect(overridesOf(store, id)).toBeUndefined();
    }
    expect(readRelayWebProbeAutoHistory().map((entry) => [entry.modelId, entry.sentAt])).toEqual(probed.map((id) => [id, NOW_ISO]));

    // Saving the same fragment again: ones already probed are deduplicated and take no slot; the remaining two fill in.
    await saveRelayWebSearchSettings(store, savedProvider(store), { openai_chat_completions: CHAT_FRAGMENT }, { now });
    await __relayWebAutoProbesSettledForTest();
    expect(probes.map((item) => item.modelId)).toEqual(ids);
  });

  it('RL2-WEBPROBE-WIRE-save models whose first-send transport has no fragment get no request', async () => {
    const store = storeWith(makeProvider('openai_chat_completions', [makeModel('m1')]));
    const probes = installFakeRelay({ probe: evidence('chat_url_citation_searched') });

    await saveRelayWebSearchSettings(store, savedProvider(store), {
      anthropic_messages: { tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }] },
    }, { now });
    await __relayWebAutoProbesSettledForTest();

    expect(probes).toEqual([]);
    expect(readRelayWebProbeAutoHistory()).toEqual([]);
  });
});

/* ── RL2-WEBPROBE-WIRE-enable ── */

describe('relay web probe runs once after the lazy verify passed', () => {
  const MODEL = 'gpt-4o-mini';

  function enableAndSettle(store: ReturnType<typeof createAppStore>): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      enableProviderModelWithProbe(store, savedProvider(store), makeModel(MODEL), {
        lookupFamily: async () => undefined,
        webProbe: { now },
        onProbeSettled: resolve,
      });
    }).then(async (recorded) => {
      await __relayWebAutoProbesSettledForTest();
      return recorded;
    });
  }

  it('RL2-WEBPROBE-11 WIRE-enable lazy verify passed: one probe', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('auto', [], [makeModel(MODEL)]));
    const probes = installFakeRelay({
      probe: evidence('chat_400_rejected'),
      pingOK: (url) => url.endsWith('/chat/completions'),
    });

    expect(await enableAndSettle(store)).toBe(true);

    expect(probes.map((item) => item.modelId)).toEqual([MODEL]);
    expect(readRelayWebProbeRecord(chatKey(MODEL))?.result).toBe('rejected');
    expect(overridesOf(store, MODEL)).toEqual({ web: { value: false, source: 'tested' } });
    expect(readRelayWebProbeAutoHistory().map((entry) => entry.modelId)).toEqual([MODEL]);
  });

  it('RL2-WEBPROBE-WIRE-enable lazy verify failed: no probe', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('auto', [], [makeModel(MODEL)]));
    const probes = installFakeRelay({ probe: evidence('chat_url_citation_searched'), pingOK: () => false });

    expect(await enableAndSettle(store)).toBe(false);

    expect(probes).toEqual([]);
    expect(readRelayWebProbeAutoHistory()).toEqual([]);
  });

  it('RL2-WEBPROBE-WIRE-enable lazy verify did not run: no probe', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('openai_chat_completions', [], [makeModel(MODEL)]));
    const probes = installFakeRelay({ probe: evidence('chat_url_citation_searched'), pingOK: () => true });

    expect(await enableAndSettle(store)).toBe(false);

    expect(savedProvider(store).models.map((item) => item.id)).toEqual([MODEL]);
    expect(probes).toEqual([]);
    expect(readRelayWebProbeAutoHistory()).toEqual([]);
  });
});

/* ── RL2-WEBPROBE-OVERRIDE-clear ── */

describe('tested web override mirrors the current record', () => {
  it('RL2-WEBPROBE-10 OVERRIDE-clear a fragment change drops tested web, user-set kept', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('openai_chat_completions', [
      makeModel('m1', { web: { value: true, source: 'tested' }, image: { value: true, source: 'user' } }),
      makeModel('m2', { web: { value: false, source: 'user' } }),
    ]));
    fillDailyCap();
    const probes = installFakeRelay({ probe: evidence('chat_url_citation_searched') });

    // Saving the same fragment again: the hash is unchanged, tested stays as is.
    await saveRelayWebSearchSettings(store, savedProvider(store), { openai_chat_completions: CHAT_FRAGMENT }, { now });
    await __relayWebAutoProbesSettledForTest();
    expect(overridesOf(store, 'm1')?.web).toEqual({ value: true, source: 'tested' });

    await saveRelayWebSearchSettings(store, savedProvider(store), { openai_chat_completions: CHANGED_CHAT_FRAGMENT }, { now });
    await __relayWebAutoProbesSettledForTest();

    expect(probes).toEqual([]);
    expect(overridesOf(store, 'm1')).toEqual({ image: { value: true, source: 'user' } });
    expect(overridesOf(store, 'm2')).toEqual({ web: { value: false, source: 'user' } });
  });

  it('RL2-WEBPROBE-OVERRIDE-clear silent after a lift drops tested web, user-set kept', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const hash = relayWebFragmentHash(CHAT_FRAGMENT);
    const store = storeWith(makeProvider('openai_chat_completions', [
      makeModel('m1', { web: { value: false, source: 'tested' } }),
      makeModel('m2', { web: { value: false, source: 'user' } }),
    ]));
    for (const id of ['m1', 'm2']) {
      writeRelayWebProbeRecord(chatKey(id), { result: 'rejected', source: 'tested', at: '2026-10-12T00:00:00.000Z', fragmentHash: hash });
    }
    installFakeRelay({ probe: evidence('chat_text_only_silent') });

    const lifted = await runRelayWebProbe(store, PROVIDER_ID, 'm1', { now });
    await runRelayWebProbe(store, PROVIDER_ID, 'm2', { now });

    expect(lifted.result).toBe('silent');
    expect(lifted.record).toEqual({ result: 'silent', source: 'tested', at: NOW_ISO, fragmentHash: hash });
    expect(readRelayWebProbeRecord(chatKey('m1'))?.result).toBe('silent');
    expect(overridesOf(store, 'm1')).toBeUndefined();
    expect(overridesOf(store, 'm2')).toEqual({ web: { value: false, source: 'user' } });
  });

  it('RL2-WEBPROBE-OVERRIDE-clear silent after searched keeps tested true (merged record stays searched)', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('openai_chat_completions', [makeModel('m1')]));
    installFakeRelay({ probe: evidence('chat_url_citation_searched') });
    expect((await runRelayWebProbe(store, PROVIDER_ID, 'm1', { now })).result).toBe('searched');
    vi.restoreAllMocks();
    installFakeRelay({ probe: evidence('chat_text_only_silent') });

    const run = await runRelayWebProbe(store, PROVIDER_ID, 'm1', { now });

    expect(run.result).toBe('silent');
    expect(run.record?.result).toBe('searched');
    expect(overridesOf(store, 'm1')).toEqual({ web: { value: true, source: 'tested' } });
  });

  it('RL2-WEBPROBE-OVERRIDE-clear undetermined writes no record and keeps the override', async () => {
    replaceRelayWebFragments(PROVIDER_ID, { openai_chat_completions: CHAT_FRAGMENT });
    const store = storeWith(makeProvider('openai_chat_completions', [
      makeModel('m1'),
      makeModel('m2', { web: { value: true, source: 'user' } }),
    ]));
    installFakeRelay({ probe: evidence('chat_400_rejected') });
    expect((await runRelayWebProbe(store, PROVIDER_ID, 'm1', { now })).result).toBe('rejected');
    expect(overridesOf(store, 'm1')).toEqual({ web: { value: false, source: 'tested' } });
    vi.restoreAllMocks();
    installFakeRelay({ probe: evidence('chat_503_undetermined') });

    const run = await runRelayWebProbe(store, PROVIDER_ID, 'm1', { now });
    await runRelayWebProbe(store, PROVIDER_ID, 'm2', { now });

    expect(run.result).toBe('undetermined');
    expect(run.record).toBeUndefined();
    expect(readRelayWebProbeRecord(chatKey('m1'))?.result).toBe('rejected');
    expect(overridesOf(store, 'm1')).toEqual({ web: { value: false, source: 'tested' } });
    expect(overridesOf(store, 'm2')).toEqual({ web: { value: true, source: 'user' } });
  });
});

/* -- The template is the effective fragment -- */

describe('saving a fragment equal to the template', () => {
  const TEMPLATE = RELAY_WEB_FRAGMENT_TEMPLATES.openai_chat_completions;

  it('RL2-WEBPROBE-02 the template-probe override survives saving the same fragment; probes still run for saved fragments', async () => {
    const store = storeWith(makeProvider('openai_chat_completions', ['m1', 'm2'].map((id) => makeModel(id))));
    const probes = installFakeRelay({ probe: evidence('chat_url_citation_searched') });

    // Manual probe from the panel (template): writes the record and tested web.
    const run = await runRelayWebProbe(store, PROVIDER_ID, 'm2', { now });
    expect(run).toMatchObject({ outcome: 'completed', result: 'searched', webSource: 'template', overrideWritten: true });
    expect(overridesOf(store, 'm2')).toEqual({ web: { value: true, source: 'tested' } });

    // The web settings page saves the same fragment as the template: the effective fragment did not change, so tested web is not removed; saving is still one automatic event (the same-hash record already exists and is not deduplicated, per the selection rule).
    expect(await saveRelayWebSearchSettings(store, store.getState().providers[0]!, { openai_chat_completions: TEMPLATE }, { now })).toBe(true);
    expect(overridesOf(store, 'm2')).toEqual({ web: { value: true, source: 'tested' } });
    await __relayWebAutoProbesSettledForTest();
    expect(probes.map((item) => item.modelId)).toEqual(['m2', 'm1', 'm2']);
    expect(overridesOf(store, 'm1')).toEqual({ web: { value: true, source: 'tested' } });
  });
});
