import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
  * Passive recording (RL2-WEBPROBE-CHAT-02, fixture shared/test-fixtures/relay/web-probe.v1.json evidenceCases):
  * relay chat goes through the production send chain sendMessage -> production Relay orchestration layer (citation resolution) -> delivery completion path;
  * if this turn carried a connection-level web fragment and citations were resolved -> the local record is written as searched / observed; with no citations or on error nothing is written.
 */
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  store: null as unknown,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../../utils/chat-stream-utils', async () => ({
  ...await vi.importActual<typeof import('../../../utils/chat-stream-utils')>('../../../utils/chat-stream-utils'),
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
}));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { relayWebFragmentHash } from '@oriveo/core/providers/relay-web-probe';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { replaceRelayWebFragments } from '../relay-web-fragments';
import { readRelayWebProbeRecord, writeRelayWebProbeRecord } from '../relay-web-probe-records';
import { rememberRelayCatalogEndpointTypes } from '../../providers/relay-probe-candidates';

interface EvidenceCase {
  caseId: string;
  transport: string;
  status: number | null;
  sse?: string[];
  body?: unknown;
}

const evidenceCases: EvidenceCase[] = (() => {
  let dir = __dirname;
  for (;;) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'relay', 'web-probe.v1.json');
    if (existsSync(candidate)) return (JSON.parse(readFileSync(candidate, 'utf8')) as { evidenceCases: EvidenceCase[] }).evidenceCases;
    const parent = path.dirname(dir);
    if (parent === dir) throw new Error('web-probe.v1.json not found');
    dir = parent;
  }
})();
const evidence = (caseId: string) => evidenceCases.find((item) => item.caseId === caseId)!;

const METADATA_FIXTURE = {
  version: 1,
  contractVersion: 1,
  updatedAt: '2026-08-08T00:00:00Z',
  profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
  providers: {},
  providerConfigs: [],
};

const TRANSPORT = 'openai_chat_completions';
const FRAGMENT = { web_search_options: {} };
const provider = {
  id: 'relay-1', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: TRANSPORT, resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: TRANSPORT, relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const model = {
  id: 'my-relay-model', name: 'my-relay-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;
const key = { connectionId: provider.id, modelId: model.id, transport: TRANSPORT };

const sentBodies: Record<string, unknown>[] = [];
let respond: () => Response;

function replay(c: EvidenceCase): () => Response {
  return () => (c.sse
    ? new Response(`${c.sse.join('\n')}\n`, { status: c.status ?? 200, headers: { 'Content-Type': 'text/event-stream' } })
    : new Response(JSON.stringify(c.body), { status: c.status ?? 500, headers: { 'Content-Type': 'application/json' } }));
}

function newStore(p: Provider = provider, m: AIModel = model) {
  const conv = {
    id: 'conv-1', title: 'T', hasCustomTitle: false, providerID: p.id, modelID: m.id, previewText: '', estimatedCost: 0,
    isDraft: false, messages: [], draftText: '', updatedAt: '2026-10-08T00:00:00.000Z',
  };
  const store = createAppStore({ providers: [p], conversations: [conv as never] });
  mocks.store = store;
  return store;
}

async function send(p: Provider = provider, m: AIModel = model) {
  const store = newStore(p, m);
  const conv = store.getState().conversations[0];
  await sendMessage(
    { store, appendChunk: (chunk: string) => batchAppendStreaming('conv-1', chunk), te: (k: string) => k },
    { text: 'What is the top news today?', prevMessages: [], conversation: conv, provider: p, model: m, reasoningMode: 'automatic' },
  ).done;
  return store.getState().conversations[0].messages.find((m) => m.role === 'assistant')!;
}

beforeEach(async () => {
  localStorage.clear();
  sentBodies.length = 0;
  __resetMetadataClientForTest();
  await __seedMetadataCacheForTest({ data: METADATA_FIXTURE, timestamp: Date.now() } as never);
  await initMetadata();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'What is the top news today?' }]);
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>);
          return respond();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
});

describe('RL2-WEBPROBE-CHAT-02 delivered and citations resolved -> searched / observed', () => {
  it('RL2-WEBPROBE-CHAT-02 chat_url_citation_searched writes searched / observed (hash = fragment of this turn)', async () => {
    replaceRelayWebFragments(provider.id, { [TRANSPORT]: FRAGMENT });
    respond = replay(evidence('chat_url_citation_searched'));
    const assistant = await send();
    expect(assistant.state).toBe('delivered');
    expect(sentBodies).toHaveLength(1);
    expect(sentBodies[0]).toMatchObject(FRAGMENT);
    const record = readRelayWebProbeRecord(key);
    expect(record).toMatchObject({ result: 'searched', source: 'observed', fragmentHash: relayWebFragmentHash(FRAGMENT) });
    expect(typeof record?.at).toBe('string');
  });

  it('RL2-WEBPROBE-CHAT-02 observed searched overrides an existing silent', async () => {
    replaceRelayWebFragments(provider.id, { [TRANSPORT]: FRAGMENT });
    writeRelayWebProbeRecord(key, { result: 'silent', source: 'tested', at: '2026-10-01T00:00:00.000Z', fragmentHash: relayWebFragmentHash(FRAGMENT) });
    respond = replay(evidence('chat_url_citation_searched'));
    await send();
    expect(readRelayWebProbeRecord(key)).toMatchObject({ result: 'searched', source: 'observed' });
  });
});

describe('RL2-WEBPROBE-CHAT-02 cases where nothing is written', () => {
  it('RL2-WEBPROBE-CHAT-02 chat_text_only_silent: delivered but no citations, nothing written', async () => {
    replaceRelayWebFragments(provider.id, { [TRANSPORT]: FRAGMENT });
    respond = replay(evidence('chat_text_only_silent'));
    const assistant = await send();
    expect(assistant.state).toBe('delivered');
    expect(readRelayWebProbeRecord(key)).toBeUndefined();
  });

  it('RL2-WEBPROBE-CHAT-02 error (400 / 503) writes nothing', async () => {
    replaceRelayWebFragments(provider.id, { [TRANSPORT]: FRAGMENT });
    for (const caseId of ['chat_400_rejected', 'chat_503_undetermined']) {
      respond = replay(evidence(caseId));
      const assistant = await send();
      expect(assistant.state, caseId).toBe('failed');
      expect(readRelayWebProbeRecord(key), caseId).toBeUndefined();
    }
  });

  it('RL2-WEBPROBE-CHAT-02 this turn carried no fragment: even with citations nothing is written', async () => {
    respond = replay(evidence('chat_url_citation_searched'));
    const assistant = await send();
    expect(assistant.state).toBe('delivered');
    expect(sentBodies[0]).not.toHaveProperty('web_search_options');
    expect(readRelayWebProbeRecord(key)).toBeUndefined();
  });
});

describe('RL2-WEBPROBE-CHAT-02 uses the same protocol as the probe (the first-send protocol of the model)', () => {
  const autoProvider = {
    ...provider, id: 'relay-auto', relayRequested: { transport: 'auto', resolvedAPIBaseURL: 'https://relay.example/v1' },
    relayResolvedTransport: undefined,
  } as unknown as Provider;
  const claude = { ...model, id: 'claude-sonnet-4', name: 'claude-sonnet-4' } as AIModel;
  const messagesFragment = { tools: [{ type: 'web_search_20250305', name: 'web_search' }] };
  afterEach(() => rememberRelayCatalogEndpointTypes(autoProvider.id, undefined));

  it('RL2-WEBPROBE-CHAT-02 auto connection first-send anthropic_messages: delivered citations are recorded under anthropic_messages', async () => {
    rememberRelayCatalogEndpointTypes(autoProvider.id, { [claude.id]: ['anthropic', 'openai'] });
    replaceRelayWebFragments(autoProvider.id, { anthropic_messages: messagesFragment, openai_chat_completions: FRAGMENT });
    respond = replay(evidence('messages_web_search_tool_result_searched'));
    const assistant = await send(autoProvider, claude);
    expect(assistant.state).toBe('delivered');
    expect(sentBodies[0]).toMatchObject(messagesFragment);
    expect(readRelayWebProbeRecord({ connectionId: autoProvider.id, modelId: claude.id, transport: 'anthropic_messages' }))
      .toMatchObject({ result: 'searched', source: 'observed', fragmentHash: relayWebFragmentHash(messagesFragment) });
    expect(readRelayWebProbeRecord({ connectionId: autoProvider.id, modelId: claude.id, transport: TRANSPORT })).toBeUndefined();
  });

  it('RL2-WEBPROBE-CHAT-02 first-send protocol rejected, after falling back to another protocol citations appear: this turn switched protocol, nothing written', async () => {
    rememberRelayCatalogEndpointTypes(autoProvider.id, { [claude.id]: ['anthropic', 'openai'] });
    replaceRelayWebFragments(autoProvider.id, { anthropic_messages: messagesFragment, openai_chat_completions: FRAGMENT });
    const queue = [replay(evidence('messages_415_rejected')), replay(evidence('chat_url_citation_searched'))];
    respond = () => (queue.shift() ?? queue[0]!)();
    const assistant = await send(autoProvider, claude);
    expect(assistant.state).toBe('delivered');
    // The fallback really happens: Messages is rejected first, then Chat delivers and brings back citations.
    expect(sentBodies).toHaveLength(2);
    expect(sentBodies[0]).toMatchObject(messagesFragment);
    expect(sentBodies[1]).toMatchObject(FRAGMENT);
    expect(assistant.citations?.length ?? 0).toBeGreaterThan(0);
    expect(readRelayWebProbeRecord({ connectionId: autoProvider.id, modelId: claude.id, transport: 'anthropic_messages' })).toBeUndefined();
    expect(readRelayWebProbeRecord({ connectionId: autoProvider.id, modelId: claude.id, transport: TRANSPORT })).toBeUndefined();
  });
});
