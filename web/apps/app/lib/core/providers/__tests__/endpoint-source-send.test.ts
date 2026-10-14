import 'fake-indexeddb/auto';
/**
 * @vitest-environment jsdom
 */
// Takes effect on real requests: when an official provider records region:<id> / default, the production send entries (main chat
// runStreamPipeline, cross-check crosscheckAnswer) hand sendStream a base URL computed from the current metadata;
// startup backfill classifies unclassified records by metadata and writes them back locally (without changing updatedAt, without uploading).
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { buildProviderRequest } from '@oriveo/core/providers/request-builders/dispatch';
import type { AIModel, Provider } from '@oriveo/shared';
import { pruneBlobs } from '../../../infra/storage/blob-cache';
import { __seedMetadataCacheForTest as seedMetadataCache } from '../../metadata/metadata-client';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  readStream: vi.fn(),
  createPartialFlushScheduler: vi.fn(),
  putProvider: vi.fn(async () => {}),
  didUpdateProvider: vi.fn(),
}));

vi.mock('../service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));
vi.mock('../../../utils/chat-stream-utils', () => ({
  readStream: (...args: unknown[]) => mocks.readStream(...args),
}));
vi.mock('../../chat/partial-flush', () => ({
  createPartialFlushScheduler: (...args: unknown[]) => mocks.createPartialFlushScheduler(...args),
}));
vi.mock('../../chat/cost-fields', () => ({
  applyCitationsToMessage: vi.fn(),
}));
vi.mock('../../../infra/storage/idb', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/idb')>()),
  putProvider: (...args: unknown[]) => mocks.putProvider(...(args as [])),
}));
vi.mock('../../sync', () => ({
  getSyncAdapter: () => ({ didUpdateProvider: mocks.didUpdateProvider }),
}));

const QWEN = {
  kind: 'qwen',
  displayName: 'Qwen',
  defaultBaseURL: 'https://dashscope-intl.aliyuncs.com',
  trustedHosts: ['aliyuncs.com'],
  regionOptions: [
    { id: 'sg', label: 'Singapore', baseURL: 'https://dashscope-intl.aliyuncs.com' },
    { id: 'bj', label: 'Beijing', baseURL: 'https://dashscope.aliyuncs.com' },
  ],
};
const MOVED_BJ = 'https://cn-beijing.dashscope.aliyuncs.com';

async function loadMetadata(bjBaseURL = 'https://dashscope.aliyuncs.com') {
  vi.resetModules();
  await pruneBlobs(() => true);
  await seedMetadataCache({
    timestamp: Date.now(),
    data: {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-11T00:00:00Z',
      profiles: {},
      providers: { qwen: { transport: { baseUrl: QWEN.defaultBaseURL, endpoints: {} }, models: {} } },
      providerConfigs: [{
        ...QWEN,
        regionOptions: QWEN.regionOptions.map((option) =>
          option.id === 'bj' ? { ...option, baseURL: bjBaseURL } : option),
      }],
    } as never,
  });
  vi.spyOn(globalThis, 'fetch').mockResolvedValue({ status: 304, ok: false, json: vi.fn() } as unknown as Response);
  const metadata = await import('../../metadata/metadata-client');
  await metadata.initMetadata();
}

function qwenProvider(patch: Partial<Provider> = {}): Provider {
  return {
    id: 'qwen-1',
    kind: 'qwen',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-qwen',
    apiKeyPreview: 'sk-…',
    baseURLText: 'https://dashscope.aliyuncs.com',
    endpointSource: 'region:bj',
    updatedAt: '2026-10-01T00:00:00.000Z',
    ...patch,
  };
}

const model: AIModel = {
  id: 'qwen-plus',
  name: 'Qwen Plus',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
};

function chatStore() {
  const conversations = [{ id: 'conv-1', messages: [{ id: 'assistant-1', state: 'generating' }] }];
  return {
    getState: () => ({
      appendStreamingReasoningText: vi.fn(),
      conversations,
      updateConversation: vi.fn(),
    }),
  } as never;
}

function sentBaseURL(): unknown {
  expect(mocks.sendStream).toHaveBeenCalledTimes(1);
  return mocks.sendStream.mock.calls[0]?.[4];
}

describe('endpointSource takes effect at the production send entries', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.sendStream.mockReturnValue({
      abort: vi.fn(),
      stream: new ReadableStream({
        start(controller) {
          controller.enqueue({ type: 'delta', content: 'ok' });
          controller.enqueue({ type: 'done' });
          controller.close();
        },
      }),
    });
    mocks.readStream.mockResolvedValue({
      fullText: 'ok',
      reasoningText: '',
      usage: undefined,
      imageAttachments: [],
      servedModelID: model.id,
      citations: undefined,
    });
    mocks.createPartialFlushScheduler.mockReturnValue({ onChunk: vi.fn(), dispose: vi.fn() });
  });
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('ENDPOINT-SOURCE-SEND main chat: region:bj hits the new address after metadata changes the address', async () => {
    await loadMetadata(MOVED_BJ);
    const { runStreamPipeline } = await import('../../chat/stream-runner');
    await runStreamPipeline({
      store: chatStore(),
      appendChunk: vi.fn(),
      conversationId: 'conv-1',
      messageId: 'assistant-1',
      provider: qwenProvider(),
      model,
      chatHistory: [{ role: 'user', content: 'hi' }],
      initialText: '',
      relayStreamOptions: undefined,
      setAbortFn: vi.fn(),
    });
    expect(sentBaseURL()).toBe(MOVED_BJ);
  });

  it('ENDPOINT-SOURCE-SEND cross-check: region:bj follows metadata, custom keeps the literal address', async () => {
    await loadMetadata(MOVED_BJ);
    const { crosscheckAnswer } = await import('../../note-ai-ops');
    await crosscheckAnswer({
      provider: qwenProvider(),
      model,
      originalPrompt: 'q',
      originalAnswer: 'a',
      appLanguage: 'en',
    });
    expect(sentBaseURL()).toBe(MOVED_BJ);

    mocks.sendStream.mockClear();
    await crosscheckAnswer({
      provider: qwenProvider({ baseURLText: 'https://proxy.example.com/v1', endpointSource: 'custom' }),
      model,
      originalPrompt: 'q',
      originalAnswer: 'a',
      appLanguage: 'en',
    });
    expect(sentBaseURL()).toBe('https://proxy.example.com/v1');
  });

  it('ENDPOINT-SOURCE-BACKFILL startup backfill: unclassified records are classified by metadata and written back locally, without changing updatedAt and without uploading', async () => {
    await loadMetadata();
    const { createAppStore } = await import('../../store/app-store');
    const { backfillOfficialEndpointSources } = await import('../endpoint-source');
    const store = createAppStore();
    const unclassified = qwenProvider({ endpointSource: undefined });
    const relay: Provider = {
      id: 'relay-1',
      kind: 'relay',
      status: { kind: 'connected' },
      models: [],
      catalogModels: [],
      apiKey: 'k',
      apiKeyPreview: 'k',
      baseURLText: 'https://dashscope.aliyuncs.com',
    };
    store.setState({ providers: [unclassified, relay] });

    await backfillOfficialEndpointSources(store);

    const [qwen, relayAfter] = store.getState().providers;
    expect(qwen?.endpointSource).toBe('region:bj');
    expect(qwen?.updatedAt).toBe(unclassified.updatedAt);
    expect(relayAfter).toBe(relay);
    expect(mocks.putProvider).toHaveBeenCalledTimes(1);
    expect(mocks.putProvider).toHaveBeenCalledWith(expect.objectContaining({ id: 'qwen-1', endpointSource: 'region:bj' }));
    expect(mocks.didUpdateProvider).not.toHaveBeenCalled();
  });
});

// Fixture sendPath cases go through the real sendStream (browser -> /api/chat/stream proxy); at the fetch layer
// the request body sent by the browser is intercepted, then handed to the production buildProviderRequest used by the route to compute the upstream URL, and the upstream host is asserted.
type SendFixture = {
  configs: Record<string, Record<string, unknown> & { kind: string; defaultBaseURL: string }>;
  metadataPresets: Record<string, Record<string, unknown>>;
  reconcileCases: Array<{
    caseId: string;
    config: string;
    metadataPatch: Record<string, unknown> | string;
    stored: { baseURLText: string | null; endpointSource: string | null };
    expectRequestBaseURL: string;
    sendPath?: boolean;
  }>;
};
const sendFixture = JSON.parse(readFileSync(
  resolve(process.cwd(), '../../../shared/test-fixtures/provider-catalog/endpoint-source.v1.json'),
  'utf8',
)) as SendFixture;

async function loadCaseMetadata(testCase: SendFixture['reconcileCases'][number]) {
  vi.resetModules();
  await pruneBlobs(() => true);
  const base = { ...sendFixture.configs[testCase.config]! };
  if (typeof testCase.metadataPatch === 'string' && testCase.metadataPatch !== 'absent') {
    Object.assign(base, sendFixture.metadataPresets[testCase.metadataPatch]);
  } else if (typeof testCase.metadataPatch === 'object' && Object.keys(testCase.metadataPatch).length > 0) {
    throw new Error(`sendPath cases do not yet support dotted metadataPatch: ${testCase.caseId}`);
  }
  await seedMetadataCache({
    timestamp: Date.now(),
    data: {
      version: 1,
      contractVersion: 1,
      updatedAt: '2026-10-11T00:00:00Z',
      profiles: {},
      providers: { [base.kind]: { transport: { baseUrl: base.defaultBaseURL, endpoints: {} }, models: {} } },
      providerConfigs: [{ displayName: base.kind, ...base }],
    } as never,
  });
  const browserBodies: Array<Record<string, unknown>> = [];
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === '/api/chat/stream') {
      browserBodies.push(JSON.parse(String(init?.body)));
      return new Response('data: {"type":"done"}\n\n', {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      });
    }
    return { status: 304, ok: false, json: vi.fn() } as unknown as Response;
  });
  const metadata = await import('../../metadata/metadata-client');
  await metadata.initMetadata();
  await metadata.__settleMetadataBackgroundWorkForTest();
  const actualService = await vi.importActual<typeof import('../service')>('../service');
  mocks.sendStream.mockImplementation((...args: unknown[]) =>
    (actualService.sendStream as (...a: unknown[]) => unknown)(...args));
  return { kind: base.kind, browserBodies };
}

describe('ENDPOINT-SOURCE-SEND fixture sendPath: existing records hit the expected host through the production main chat entry', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  for (const testCase of sendFixture.reconcileCases.filter((item) => item.sendPath)) {
    it(`ENDPOINT-SOURCE-SEND-${testCase.caseId}`, async () => {
      mocks.readStream.mockResolvedValue({
        fullText: 'ok', reasoningText: '', usage: undefined, imageAttachments: [], servedModelID: 'm', citations: undefined,
      });
      mocks.createPartialFlushScheduler.mockReturnValue({ onChunk: vi.fn(), dispose: vi.fn() });
      const { kind, browserBodies } = await loadCaseMetadata(testCase);
      const { runStreamPipeline } = await import('../../chat/stream-runner');
      await runStreamPipeline({
        store: chatStore(),
        appendChunk: vi.fn(),
        conversationId: 'conv-1',
        messageId: 'assistant-1',
        provider: {
          id: `${kind}-1`,
          kind: kind as Provider['kind'],
          status: { kind: 'connected' },
          models: [],
          catalogModels: [],
          apiKey: 'sk-test',
          apiKeyPreview: 'sk-…',
          ...(testCase.stored.baseURLText ? { baseURLText: testCase.stored.baseURLText } : {}),
          ...(testCase.stored.endpointSource
            ? { endpointSource: testCase.stored.endpointSource as Provider['endpointSource'] }
            : {}),
        },
        model: { ...model, id: 'test-model' },
        chatHistory: [{ role: 'user', content: 'hi' }],
        initialText: '',
        relayStreamOptions: undefined,
        setAbortFn: vi.fn(),
      });
      await vi.waitFor(() => expect(browserBodies).toHaveLength(1));
      const sent = browserBodies[0]!;
      // route.ts uses the same builder to turn the browser-supplied baseURL into the upstream request URL
      const upstream = await buildProviderRequest({
        providerKind: sent.providerKind as never,
        apiKey: String(sent.apiKey),
        modelID: String(sent.modelID),
        messages: sent.messages as never,
        stream: true,
        baseURL: sent.baseURL as string | undefined,
      } as never, async () => null);
      expect(new URL(upstream.url).host).toBe(new URL(testCase.expectRequestBaseURL).host);
    });
  }
});
