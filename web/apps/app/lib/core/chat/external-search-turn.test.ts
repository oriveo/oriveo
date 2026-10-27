// @vitest-environment node
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { POST } from '../../../app/api/search/forward/route';
import { __resetRateLimitForTests } from '../../../app/api/chat/stream/rate-limit';
import { __setSearchCatalogLoaderForTests, createSearchCatalogLoader } from '../../search/search-catalog-loader';
import type { ExternalSearchSendContext } from './external-search-send';
import {
  createExternalSearchExecutor,
  createWebSearchEntry,
  externalSearchMessagePatch,
  hostMemoryToolsRegistered,
  planExternalSearchTurn,
  searchThinkingOn,
  startExternalSearchReply,
  type PlanExternalSearchInput,
} from './external-search-turn';

// Production-path evidence for external web search: DeepSeek response goldens replace upstream HTTP while the real forward route +
// forwardSearch + web_search executor + event loop + finalize persistence patch run; DNS is mocked and no real requests are sent.

const mocks = vi.hoisted(() => ({ lookup: vi.fn(), resolve4: vi.fn(), resolve6: vi.fn() }));
vi.mock('node:dns/promises', () => ({
  default: { lookup: mocks.lookup, resolve4: mocks.resolve4, resolve6: mocks.resolve6 },
  lookup: mocks.lookup,
  resolve4: mocks.resolve4,
  resolve6: mocks.resolve6,
}));

const REPO_ROOT = join(process.cwd(), '../../..');
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const load = (relative: string): any => JSON.parse(readFileSync(join(REPO_ROOT, relative), 'utf8'));
const contract = load('shared/search-contracts/search_catalog_contract.v1.json');
const golden = load('shared/search-contracts/transport-golden.v1.json');
const deepseekNormal = golden.cases.find((c: { caseId: string }) => c.caseId === 'deepseek.normal');
const deepseekHost: string = contract.catalog.services.find((s: { id: string }) => s.id === 'deepseek').regions.find((r: { id: string }) => r.id === 'cn').host;

type Requester = (input: { url: URL; headers: Record<string, string>; body?: string }) => Promise<Response>;
type TestGlobal = typeof globalThis & { __oriveoSearchForwardUpstreamRequester?: Requester };

const upstreamCalls: { url: URL; headers: Record<string, string>; body?: string }[] = [];
function stubUpstream(status: number, body: unknown) {
  (globalThis as TestGlobal).__oriveoSearchForwardUpstreamRequester = async (input) => {
    upstreamCalls.push(input);
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
  };
}

/** Browser-side fetch('/api/search/forward') -> the real route. */
const routeFetch = (async (_url: string, init?: RequestInit) => POST(new Request('http://localhost/api/search/forward', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'x-forwarded-for': '198.51.100.30' },
  body: init?.body as string,
}))) as unknown as typeof fetch;

function context(path: 'external_tool' | 'external_presearch', boundHost = deepseekHost): ExternalSearchSendContext {
  const view = {
    record: { id: 'svc-ds', kind: 'preset', serviceId: 'deepseek', name: 'DeepSeek', regionId: 'cn', boundHost, connectionRef: 'conn-ds', createdAt: 1, updatedAt: 1 },
    name: 'DeepSeek',
    keySource: 'connection',
    hasKey: false,
    keyTail: null,
    row: { status: 'ready', label: 'preset', keySource: 'connection', connectionName: 'DeepSeek' },
    resultCount: 5,
  };
  const other = { ...view, record: { ...view.record, id: 'svc-tv', serviceId: 'tavily', connectionRef: null }, name: 'Tavily' };
  return {
    state: { route: { path }, source: { method: 'external', serviceId: 'svc-ds', notice: null, nextStored: null, changed: false } },
    data: { uid: 'u1', catalog: { available: true, entries: [], withdrawn: [] }, connections: [], snapshot: { services: [view, other], defaultId: 'svc-tv' } },
  } as unknown as ExternalSearchSendContext;
}

const PLAN_INPUT: PlanExternalSearchInput = {
  toolCall: 'supported',
  host: { library: false, mcp: false, memoryTools: false, continuationKind: 'tool_loop' },
  thinking: { on: false, protocol: 'openai_chat', continuationStateAvailable: true },
  userText: 'Oriveo web search',
  B: 100_000,
  today: '2026-10-27',
};
const CONNECTIONS = [{ id: 'conn-ds', name: 'DeepSeek', providerKind: 'deepseek', baseUrl: null, apiKey: 'sk-test-0000' }];

describe('external search turn (production path)', () => {
  beforeEach(() => {
    __resetRateLimitForTests();
    upstreamCalls.length = 0;
    mocks.resolve4.mockResolvedValue(['203.0.113.10']);
    mocks.resolve6.mockRejectedValue(new Error('ENODATA'));
    mocks.lookup.mockResolvedValue([{ address: '203.0.113.10', family: 4 }]);
    __setSearchCatalogLoaderForTests(createSearchCatalogLoader({
      trustedKeys: { [contract.testKeys.keyId]: contract.testKeys.publicKeyB64 },
      builtin: contract.catalog,
      fetchView: async () => new Response(null, { status: 503 }),
    }));
  });

  afterEach(() => {
    delete (globalThis as TestGlobal).__oriveoSearchForwardUpstreamRequester;
    __setSearchCatalogLoaderForTests(undefined);
    vi.restoreAllMocks();
  });

  it('web_search tool: golden result goes into the <oriveo-web> envelope, numbering continues after the library, persisted sources match it, facts observed', async () => {
    stubUpstream(200, deepseekNormal.body);
    const turn = planExternalSearchTurn(context('external_tool'), PLAN_INPUT);
    expect(turn?.plan.requestHasWebSearchTool).toBe(true);
    const track = vi.fn();
    const reply = startExternalSearchReply({
      turn: turn!,
      B: 100_000,
      rhoHi: 0.5,
      retrievedAt: '2026-10-27T08:00:00.000Z',
      execute: createExternalSearchExecutor(turn!.binding, { uid: 'u1', connections: CONNECTIONS, fetchImpl: routeFetch }),
      priorBatches: [{ source: 'library', items: [{ libraryKey: 'doc-a' }, { libraryKey: 'doc-b' }] }],
      track,
    });
    const entry = createWebSearchEntry(reply);
    expect(entry.definition).toMatchObject({ function: { name: 'web_search' } });
    const outcome = await entry.execute(
      { id: 'call_1', type: 'function', function: { name: 'web_search', arguments: JSON.stringify({ query: 'Oriveo web search' }) } },
      { callID: 'call_1', stepNumber: 1, legIndex: 0, signal: new AbortController().signal },
    );
    // What upstream received is the golden request shape (the key exists only within this request)
    expect(upstreamCalls).toHaveLength(1);
    expect(upstreamCalls[0].headers.Authorization).toBe('Bearer sk-test-0000');
    expect(outcome.content.startsWith('<oriveo-web provider="DeepSeek" query="Oriveo web search"')).toBe(true);
    const ids = [...outcome.content.matchAll(/<result id="(\d+)"/g)].map((m) => Number(m[1]));
    expect(ids[0]).toBe(3);
    expect(ids.length).toBeGreaterThan(0);

    const finish = reply.finish();
    const patch = externalSearchMessagePatch(finish, turn!.binding.service, {
      citations: [{ url: 'library://doc-a', source: 'library', index: 1 }],
    });
    const searchCitations = (patch.citations ?? []).filter((c) => c.source === 'external_search');
    expect(searchCitations.map((c) => c.index)).toEqual(ids);
    expect(searchCitations[0]).toMatchObject({
      url: deepseekNormal.expect.results[0].url,
      query: 'Oriveo web search',
      serviceId: 'svc-ds',
      serviceName: 'DeepSeek',
      retrievedAt: '2026-10-27T08:00:00.000Z',
      site: deepseekNormal.expect.results[0].site,
    });
    expect(patch.citations?.[0]).toMatchObject({ source: 'library' });
    expect(patch.capabilityResults).toEqual([expect.objectContaining({ owner: 'web', source: 'external_search', state: 'observed', searchCount: 1 })]);
    expect(patch.searchErrorCard).toBeUndefined();
    expect(track).toHaveBeenCalledWith('search_executed', expect.objectContaining({ service: 'deepseek', protocol: 'catalog', path: 'tool', error_class: 'none' }));
  });

  it('pre-search: query = original text, pre-send check failure gives sent:false and no billing, the finalize error card carries serviceId and the replacement service', async () => {
    stubUpstream(200, deepseekNormal.body);
    const turn = planExternalSearchTurn(context('external_presearch', 'stale.example'), PLAN_INPUT);
    expect(turn?.plan.presearch).toEqual({ query: 'Oriveo web search', count: 5 });
    const reply = startExternalSearchReply({
      turn: turn!,
      B: 100_000,
      rhoHi: 0.5,
      execute: createExternalSearchExecutor(turn!.binding, { uid: 'u1', connections: CONNECTIONS, fetchImpl: routeFetch }),
      track: vi.fn(),
    });
    const content = await reply.search(turn!.plan.presearch!.query, turn!.plan.presearch!.count);
    expect(upstreamCalls).toHaveLength(0);
    expect(content).not.toContain('web_search');
    const finish = reply.finish();
    expect(finish.facts.state).toBe('failed');
    const patch = externalSearchMessagePatch(finish, turn!.binding.service);
    expect(patch.searchErrorCard).toMatchObject({ errorClass: 'host_changed', serviceId: 'svc-ds', switchTo: { id: 'svc-tv', name: 'Tavily' } });
  });

  it('preset service key unreadable (reused connection deleted): no request sent, auth_invalid / sent:false, error card primary button "Update key"', async () => {
    stubUpstream(200, deepseekNormal.body);
    const turn = planExternalSearchTurn(context('external_presearch'), PLAN_INPUT);
    const fetchSpy = vi.fn(routeFetch);
    const reply = startExternalSearchReply({
      turn: turn!,
      B: 100_000,
      rhoHi: 0.5,
      execute: createExternalSearchExecutor(turn!.binding, { uid: 'u1', connections: [], fetchImpl: fetchSpy as unknown as typeof fetch }),
      track: vi.fn(),
    });
    await reply.search(turn!.plan.presearch!.query, turn!.plan.presearch!.count);
    expect(fetchSpy).not.toHaveBeenCalled();
    expect(upstreamCalls).toHaveLength(0);
    const patch = externalSearchMessagePatch(reply.finish(), turn!.binding.service);
    expect(patch.searchErrorCard).toMatchObject({ errorClass: 'auth_invalid', primaryAction: 'update_key', serviceId: 'svc-ds' });
  });

  it('regenerate reuse: rebuilt by query group, no request sent, no search_executed recorded', () => {
    const turn = planExternalSearchTurn(context('external_tool'), {
      ...PLAN_INPUT,
      regenerate: {
        action: 'regenerate',
        previousCitations: [
          { url: 'https://a.example/', title: 'A', snippet: 'a', source: 'external_search', query: 'q1', index: 1 },
          { url: 'https://b.example/', title: 'B', snippet: 'b', source: 'external_search', query: 'q1', index: 2 },
        ],
      },
    });
    expect(turn?.plan.reuse).toBe(true);
    expect(turn?.plan.requestHasWebSearchTool).toBe(false);
    const execute = vi.fn();
    const track = vi.fn();
    const reply = startExternalSearchReply({ turn: turn!, B: 100_000, rhoHi: 0.5, execute, track });
    const content = reply.reuse([
      { url: 'https://a.example/', title: 'A', snippet: 'a', source: 'external_search', query: 'q1', index: 1 },
      { url: 'https://b.example/', title: 'B', snippet: 'b', source: 'external_search', query: 'q1', index: 2 },
    ]);
    expect(content).toContain('<oriveo-web provider="DeepSeek" query="q1"');
    expect(execute).not.toHaveBeenCalled();
    expect(track).not.toHaveBeenCalled();
    expect(reply.finish().sourcesLine?.reused).toBe(true);
  });
  it('thinking check: counts as on only when the level is set and not fast, and the reasoning field was not stripped', () => {
    expect(searchThinkingOn('automatic')).toBe(true);
    expect(searchThinkingOn('fast')).toBe(false);
    expect(searchThinkingOn(undefined)).toBe(false);
    expect(searchThinkingOn('automatic', true)).toBe(false);
  });

  it('memory tool check: the registry has either the propose or the search entry', () => {
    expect(hostMemoryToolsRegistered({ propose: false, search: true })).toBe(true);
    expect(hostMemoryToolsRegistered({ propose: true, search: false })).toBe(true);
    expect(hostMemoryToolsRegistered({ propose: false, search: false })).toBe(false);
    const turn = planExternalSearchTurn(context('external_tool'), { ...PLAN_INPUT, host: { ...PLAN_INPUT.host, memoryTools: true } });
    expect(turn?.plan.toolHost?.tools).toContain('memory');
  });

  it('resend after edit carries no previous sources: previousResultsPersisted:false, no reuse, searches as usual', () => {
    const turn = planExternalSearchTurn(context('external_presearch'), { ...PLAN_INPUT, regenerate: { action: 'edit_resend' } });
    expect(turn?.plan.reuse).toBe(false);
    expect(turn?.plan.presearch).toEqual({ query: 'Oriveo web search', count: 5 });
  });

  it('internal resend reuse within this turn: produced sources rebuild the envelope via reuse, numbering identical, no request sent, this reply facts and sources unchanged', async () => {
    stubUpstream(200, deepseekNormal.body);
    const turn = planExternalSearchTurn(context('external_tool'), PLAN_INPUT);
    const track = vi.fn();
    const reply = startExternalSearchReply({
      turn: turn!,
      B: 100_000,
      rhoHi: 0.5,
      retrievedAt: '2026-10-27T08:00:00.000Z',
      execute: createExternalSearchExecutor(turn!.binding, { uid: 'u1', connections: CONNECTIONS, fetchImpl: routeFetch }),
      track,
    });
    const first = await reply.search('Oriveo web search', null);
    const before = reply.finish();
    const calls = upstreamCalls.length;
    track.mockClear();
    const replay = reply.replayEnvelope();
    expect(upstreamCalls).toHaveLength(calls);
    expect(track).not.toHaveBeenCalled();
    expect(replay).toBe(first);
    expect([...replay.matchAll(/<result id="(\d+)"/g)].map((m) => Number(m[1]))).toEqual(before.citations.map((c) => c.number));
    expect(reply.finish()).toEqual(before);
    expect(reply.finish().sourcesLine?.reused).toBe(false);
  });
});
