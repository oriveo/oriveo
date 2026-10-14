// Contract test for the single entry that resolves the connection key per model.
// Fixture: test-fixtures/relay/credential-resolve.v1.json (the same copy on all three clients).
// SEND cases hit in from the production send entry runStreamPipeline (real sendStream -> real Relay adapter),
// capture the request the browser sends to /api/relay/forward, then hand it unchanged to the production reverse-proxy route and assert the Authorization it actually sends upstream.

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import { resolveProviderAPIKey } from '@oriveo/core/providers/provider-credential';
import { createAppStore } from '../../store/app-store';
import { runStreamPipeline } from '../../chat/stream-runner';
import { __resetStreamBatcherForTests } from '../../chat/stream-batcher';
import { POST as relayForwardPOST } from '../../../../app/api/relay/forward/route';
import { __resetRateLimitForTests } from '../../../../app/api/chat/stream/rate-limit';

type FixtureProvider = { id: string; kind: string; apiKey: string; baseURL?: string; models: string[] };
type FixtureMultiKeyProvider = Omit<FixtureProvider, 'models'> & {
  relayKeys: NonNullable<Provider['relayKeys']>;
  models: Array<{ id: string; relayKeyID?: string }>;
};
type Fixture = {
  cases: Array<{ id: string; provider: FixtureProvider; modelId: string | null; expect: string }>;
  sendCase: { id: string; provider: FixtureProvider; modelId: string; expectAuthorization: string };
  multiKeyCases: Array<{ id: string; provider: FixtureMultiKeyProvider; modelId: string | null; expect: string }>;
  multiKeySendCase: { id: string; provider: FixtureMultiKeyProvider; expect: Record<string, string> };
};

const fixture: Fixture = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'credential-resolve.v1.json');
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, 'utf8')) as Fixture;
    dir = path.dirname(dir);
  }
  throw new Error('credential-resolve.v1.json not found');
})();

const mocks = vi.hoisted(() => ({
  createPartialFlushScheduler: vi.fn(),
  resolve4: vi.fn(),
  resolve6: vi.fn(),
  lookup: vi.fn(),
}));

vi.mock('../../chat/partial-flush', () => ({
  createPartialFlushScheduler: (...args: unknown[]) => mocks.createPartialFlushScheduler(...args),
}));

vi.mock('../../unsupported-param-telemetry', () => ({
  reportUnsupportedParamDropped: vi.fn(),
}));

vi.mock('node:dns/promises', () => ({
  default: { lookup: mocks.lookup, resolve4: mocks.resolve4, resolve6: mocks.resolve6 },
  lookup: mocks.lookup,
  resolve4: mocks.resolve4,
  resolve6: mocks.resolve6,
}));

let currentStore: ReturnType<typeof createAppStore>;
vi.mock('../../../../providers/StoreProvider', () => ({
  getVanillaStore: () => currentStore,
}));

type TestGlobal = typeof globalThis & {
  __oriveoRelayForwardUpstreamRequester?: (input: unknown) => Promise<Response>;
};

describe('CREDENTIAL-RESOLVE（Web）', () => {
  for (const c of fixture.cases) {
    it(`CREDENTIAL-RESOLVE-${c.id}`, () => {
      expect(resolveProviderAPIKey({ apiKey: c.provider.apiKey }, c.modelId)).toBe(c.expect);
    });
  }

  // Multiple keys: feed a Provider of this client's production shape (structural subtyping: kind / relayKeys / enabled models).
  for (const c of fixture.multiKeyCases) {
    it(`CREDENTIAL-RESOLVE-${c.id}`, () => {
      const provider = {
        id: c.provider.id,
        kind: c.provider.kind,
        status: { kind: 'connected' },
        apiKey: c.provider.apiKey,
        apiKeyPreview: '',
        relayKeys: c.provider.relayKeys,
        models: c.provider.models.map((m) => ({ ...m, name: m.id, capabilities: ['text'], isAvailable: true })),
        catalogModels: [],
      } as unknown as Provider;
      expect(resolveProviderAPIKey(provider, c.modelId)).toBe(c.expect);
    });
  }
});

describe('CREDENTIAL-RESOLVE production send path (Web)', () => {
  const CONV_ID = 'conv-credential';
  const MSG_ID = 'assistant-credential';

  beforeEach(() => {
    __resetStreamBatcherForTests();
    __resetRateLimitForTests();
    mocks.createPartialFlushScheduler.mockReturnValue({ onChunk: vi.fn(), dispose: vi.fn() });
    mocks.resolve4.mockResolvedValue(['203.0.113.10']);
    mocks.resolve6.mockRejectedValue(new Error('ENODATA'));
    mocks.lookup.mockResolvedValue([{ address: '203.0.113.10', family: 4 }]);
    currentStore = createAppStore();
    currentStore.setState({
      conversations: [{ id: CONV_ID, messages: [{ id: MSG_ID, state: 'generating' }] }] as never,
    });
    currentStore.getState().beginStreamingForConversation(CONV_ID, MSG_ID);
  });

  afterEach(() => {
    vi.restoreAllMocks();
    delete (globalThis as TestGlobal).__oriveoRelayForwardUpstreamRequester;
  });

  /** Send one through the production send entry, then hand the proxy request to the production route, and return the Authorization it actually sends upstream. */
  async function upstreamAuthorization(provider: Provider, model: AIModel, baseURL: string | undefined): Promise<string> {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(async () => new Response('data: [DONE]\n\n', {
      status: 200,
      headers: { 'Content-Type': 'text/event-stream' },
    }));

    await runStreamPipeline({
      store: currentStore as never,
      appendChunk: vi.fn(),
      conversationId: CONV_ID,
      messageId: MSG_ID,
      provider,
      model,
      chatHistory: [{ role: 'user', content: 'hi' }],
      initialText: '',
      relayStreamOptions: undefined,
      setAbortFn: vi.fn(),
    });

    const forwardCall = fetchMock.mock.calls.find(([url]) => url === '/api/relay/forward') as
      [string, RequestInit] | undefined;
    expect(forwardCall).toBeDefined();
    const [, init] = forwardCall!;

    // Hand the proxy request the browser sent unchanged to the production route, and take the header it actually sends upstream.
    const upstream = vi.fn().mockResolvedValue(new Response('{}', {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    }));
    (globalThis as TestGlobal).__oriveoRelayForwardUpstreamRequester = upstream;
    const res = await relayForwardPOST(new Request('http://localhost/api/relay/forward', {
      method: 'POST',
      headers: init.headers as Record<string, string>,
      body: init.body as string,
    }));

    expect(res.status).toBe(200);
    const [{ url, headers }] = upstream.mock.calls[0] as [{ url: URL; headers: Record<string, string> }];
    expect(url.toString()).toBe(`${baseURL}/chat/completions`);
    fetchMock.mockRestore();
    return headers.Authorization!;
  }

  it(`CREDENTIAL-RESOLVE-${fixture.sendCase.id}`, async () => {
    const send = fixture.sendCase;
    const model = {
      id: send.modelId,
      name: send.modelId,
      capabilities: ['text'],
      isAvailable: true,
    } as unknown as AIModel;
    const provider = {
      id: send.provider.id,
      kind: send.provider.kind,
      status: { kind: 'connected' },
      apiKey: send.provider.apiKey,
      baseURLText: send.provider.baseURL,
      models: [model],
      catalogModels: [],
    } as unknown as Provider;
    expect(await upstreamAuthorization(provider, model, send.provider.baseURL)).toBe(send.expectAuthorization);
  });

  it(`CREDENTIAL-RESOLVE-${fixture.multiKeySendCase.id}`, async () => {
    const send = fixture.multiKeySendCase;
    const models = send.provider.models.map((m) => ({
      ...m,
      name: m.id,
      capabilities: ['text'],
      isAvailable: true,
    })) as unknown as AIModel[];
    const provider = {
      id: send.provider.id,
      kind: send.provider.kind,
      status: { kind: 'connected' },
      apiKey: send.provider.apiKey,
      baseURLText: send.provider.baseURL,
      relayKeys: send.provider.relayKeys,
      models,
      catalogModels: [],
    } as unknown as Provider;
    for (const [modelID, authorization] of Object.entries(send.expect)) {
      // Send one per model: reset to one generating assistant message.
      __resetStreamBatcherForTests();
      __resetRateLimitForTests();
      currentStore = createAppStore();
      currentStore.setState({
        conversations: [{ id: CONV_ID, messages: [{ id: MSG_ID, state: 'generating' }] }] as never,
      });
      currentStore.getState().beginStreamingForConversation(CONV_ID, MSG_ID);
      const model = models.find((m) => m.id === modelID)!;
      expect(await upstreamAuthorization(provider, model, send.provider.baseURL)).toBe(authorization);
    }
  });
});
