// @vitest-environment jsdom
//
// An assistant turn that ends with nothing visible fails as empty_response instead of saving a blank delivered bubble
//. Real sendMessage / continueAnswering -> runStreamPipeline; `/api/chat/stream` is scripted.

import 'fake-indexeddb/auto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider, Skill } from '@oriveo/shared';

const mocks = vi.hoisted(() => ({
  runStreamPipeline: vi.fn(),
  recordSkillUseOp: vi.fn(),
  activeUid: { value: 'uid-skill-loop' },
  agentSearch: { value: null as unknown },
  executeLibraryTool: vi.fn(),
  /** Set = the skill knowledge retrieval answers this; null = the production retrieval. */
  skillRetrieval: { value: null as unknown },
  /** Set = the plain send's external search context; null = the production loader. */
  searchContext: { value: null as unknown },
  propose: vi.fn(),
}));

vi.mock('../stream-runner', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../stream-runner')>()),
  runStreamPipeline: (...args: unknown[]) => mocks.runStreamPipeline(...args),
}));
vi.mock('../../../utils/chat-stream-utils', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../utils/chat-stream-utils')>()),
  buildChatHistory: vi.fn(async (messages: ChatMessage[]) =>
    messages.filter((message) => message.text).map((message) => ({ role: message.role, content: message.text }))),
}));
vi.mock('../stream-options', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../stream-options')>()),
  buildStreamOptionsFromIntent: vi.fn(() => ({})),
  buildProviderStreamOptions: vi.fn(() => ({})),
  resolveGenerationProfileForModel: vi.fn(() => undefined),
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  resolveGenerationProfileRef: vi.fn(() => undefined),
  getRelayRuntimeConfig: vi.fn(() => undefined),
  getModelTransport: vi.fn(() => 'openai_chat'),
  getMetadataRevision: () => undefined,
  hasCatalogModel: vi.fn(() => true),
  resolveCatalogModel: vi.fn(() => ({ contextLength: 128_000 })),
  isMetadataSnapshotConfirmed: vi.fn(() => true),
  getProviderCatalogStatus: vi.fn(() => 'loaded'),
  getLibraryRuntimeConfig: vi.fn(() => ({
    version: 2,
    toolDescriptions: { library_search: 'Search the library.', library_list: 'List the library.', library_read: 'Read a document.' },
    maxSteps: 6, toolTimeoutMs: 1000, maxEmptyHits: 2, maxSelfCorrections: 2, tokenBudget: 0,
    estimatedTokensPerStep: 2_000, highCostConfirmationUSD: 0.25, weakModelDenylist: [], sensitiveGateEnabled: true,
  })),
}));
vi.mock('../../library/api', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../library/api')>()),
  executeLibraryTool: (...args: unknown[]) => mocks.executeLibraryTool(...args),
}));
vi.mock('../prompt-injection', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../prompt-injection')>();
  return {
    ...actual,
    retrieveSkillKnowledge: (...args: Parameters<typeof actual.retrieveSkillKnowledge>) => (
      mocks.skillRetrieval.value === null ? actual.retrieveSkillKnowledge(...args) : Promise.resolve(mocks.skillRetrieval.value)
    ),
  };
});
vi.mock('../external-search-send', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../external-search-send')>();
  return {
    ...actual,
    loadExternalSearchSendContext: (...args: Parameters<typeof actual.loadExternalSearchSendContext>) => (
      mocks.searchContext.value === null ? actual.loadExternalSearchSendContext(...args) : Promise.resolve(mocks.searchContext.value as never)
    ),
  };
});
vi.mock('../cost-fields', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../cost-fields')>()),
  deriveCostFields: vi.fn(() => ({ cost: 0, costSource: 'localEstimate' })),
}));
vi.mock('../send-completion', () => ({
  reportSendCompletion: vi.fn(),
  reportUsageAndBudget: vi.fn(),
}));
vi.mock('../../sync', () => ({
  getSyncAdapter: vi.fn(() => null),
  deleteAttachments: vi.fn(),
  flushPendingConversationDeletions: vi.fn(async () => undefined),
}));
vi.mock('../../telemetry', async () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: (kind: string) => kind,
  telemetryModelID: (await vi.importActual<typeof import('../../telemetry')>('../../telemetry')).telemetryModelID,
  sanitizeTelemetryURL: (await vi.importActual<typeof import('../../telemetry')>('../../telemetry')).sanitizeTelemetryURL,
}));
vi.mock('../../memory/memory-candidate-repository', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../memory/memory-candidate-repository')>()),
  createMemoryCandidateRepository: () => ({
    propose: (...args: unknown[]) => mocks.propose(...args),
    generate: async () => null,
  }),
}));
vi.mock('../../../infra/storage/partition', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/partition')>()),
  getActiveUIDSync: () => mocks.activeUid.value,
}));
vi.mock('../../skills/ops-lazy', () => ({
  loadSkillOps: () => Promise.resolve({ recordSkillUseOp: mocks.recordSkillUseOp }),
}));
// The external search service is outside this suite: a scripted agent search hands the loop a web_search entry.
vi.mock('../external-search-turn', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../external-search-turn')>();
  return {
    ...actual,
    prepareAgentExternalSearch: (...args: Parameters<typeof actual.prepareAgentExternalSearch>) => (
      mocks.agentSearch.value === null ? actual.prepareAgentExternalSearch(...args) : Promise.resolve(mocks.agentSearch.value)
    ),
  };
});


// Reasoning chunks go through the rAF batcher, which writes into the module-level store.
const currentStore = vi.hoisted(() => ({ value: null as unknown }));
vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => currentStore.value }));

import { createAppStore } from '../../store/app-store';
import { useMcpStore } from '../../mcp/mcp-store';
import { sendMessage } from '../operations-send';
import { continueAnswering } from '../operations-continue';
import { __resetProposeMemoryDegradedForTest } from '../propose-memory-runtime';
import { __resetMemorySuggestionForTest, getPendingMemorySuggestion } from '../conversation-instructions/memory-suggestion';
import { proposeMemoryCandidate } from '@oriveo/core/context/memory-propose';
import { resolveErrorCopyKey } from '../../../utils/chat-stream-utils';

function model(): AIModel {
  return {
    id: 'gpt-4o', name: 'GPT-4o', capabilities: ['text'], toolCall: true, reasoningModeAvailable: false,
    isAvailable: true, isDefault: true, priceTier: '$', promptPrice: 0, completionPrice: 0,
    capabilityEvidenceCandidates: [{
      key: 'tool_call', support: 'supported', source: 'server_typed', grade: 'machine_verified',
      scope: 'provider_model_transport', providerKind: 'openAI', modelId: 'gpt-4o', transport: 'openai_chat',
    }],
  } as AIModel;
}

function provider(): Provider {
  return {
    id: 'provider-1', kind: 'openAI', status: { kind: 'connected' }, models: [model()], catalogModels: [model()],
    apiKey: 'sk-test', apiKeyPreview: 'sk-...test',
  };
}

function conversation(messages: ChatMessage[] = []): Conversation {
  return {
    id: 'conv-1', title: 'Chat', hasCustomTitle: false, providerID: 'provider-1', providerKind: 'openAI', modelID: 'gpt-4o',
    previewText: '', estimatedCost: 0, isDraft: false, messages, draftText: '',
    createdAt: '2026-10-03T00:00:00.000Z', updatedAt: '2026-10-03T00:00:00.000Z',
  };
}

const GAMMA: Skill = {
  id: 'skill-c', name: 'Gamma', systemPrompt: 'Use gamma rules.', whenToUse: 'When the user asks about gamma',
  autoInvoke: true, description: '', icon: '', color: '#4A90D9', modelCapabilityHint: 'any', starterMessages: [],
  knowledgeFiles: [], knowledgeBase: null, useMemory: true, isPinned: false, pinOrder: 0, source: 'user',
  sortOrder: 0, usageCount: 0, createdAt: '2026-10-01T00:00:00Z', updatedAt: '2026-10-01T00:00:00Z',
};

const FINISH = `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })}\n\ndata: [DONE]\n\n`;

function textSse(text: string): string {
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', content: text } }] })}\n\n` + FINISH;
}

function reasoningOnlySse(reasoning: string): string {
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', reasoning_content: reasoning } }] })}\n\n` + FINISH;
}

function proposeMemorySse(argumentsJson: string): string {
  const call = { index: 0, id: 'call_1', type: 'function', function: { name: 'propose_memory', arguments: argumentsJson } };
  return `data: ${JSON.stringify({ choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [call] } }] })}\n\n`
    + `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })}\n\n`
    + 'data: [DONE]\n\n';
}

function scriptChatStream(legs: string[]): { calls: () => number } {
  const queue = [...legs];
  let count = 0;
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL) => {
    const url = typeof input === 'string' ? input : input.toString();
    if (!url.endsWith('/api/chat/stream')) throw new Error(`unexpected fetch: ${url}`);
    count += 1;
    const next = queue.shift();
    if (next === undefined) throw new Error('no scripted leg left');
    return new Response(next, { status: 200, headers: { 'Content-Type': 'text/event-stream' } });
  }));
  return { calls: () => count };
}

function start(options: { skills?: Skill[]; text?: string } = {}) {
  const conv = conversation();
  const store = createAppStore({ conversations: [conv] });
  currentStore.value = store;
  store.setState({ userSkills: options.skills ?? [] });
  const handle = sendMessage(
    { store, appendChunk: vi.fn(), te: (key) => key },
    { text: options.text ?? 'Tell me about gamma.', prevMessages: [], conversation: conv, provider: provider(), model: model(), reasoningMode: 'automatic' },
  );
  const assistant = (): ChatMessage | undefined => store.getState().conversations
    .find((item) => item.id === handle.convId)?.messages.find((message) => message.id === handle.msgId);
  return { handle, assistant };
}

function expectEmptyResponseFailure(message: ChatMessage | undefined): void {
  expect(message).toMatchObject({ state: 'failed', errorKind: 'emptyResponse' });
  // The error card localizes it through the existing whitelist, which skips provider-sourced failures.
  expect(message!.errorSource).not.toBe('provider');
  const copyKey = resolveErrorCopyKey(message!.errorKind, message!.errorReasonCode);
  expect(copyKey).not.toBeNull();
  expect(message!.errorTitle).toBe(`${copyKey}.title`);
}

let uidCounter = 0;

beforeEach(async () => {
  uidCounter += 1;
  mocks.activeUid.value = `uid-empty-reply-${uidCounter}`;
  const actual = await vi.importActual<typeof import('../stream-runner')>('../stream-runner');
  mocks.runStreamPipeline.mockReset();
  mocks.runStreamPipeline.mockImplementation(actual.runStreamPipeline);
  mocks.recordSkillUseOp.mockReset();
  mocks.agentSearch.value = null;
  mocks.skillRetrieval.value = null;
  mocks.searchContext.value = null;
  mocks.propose.mockReset();
  mocks.propose.mockResolvedValue(null);
  __resetProposeMemoryDegradedForTest();
  __resetMemorySuggestionForTest();
  localStorage.clear();
  useMcpStore.getState().reset();
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('empty assistant reply fails as empty_response', () => {
  it('marker_only_reply_fails_empty_response', async () => {
    const chat = scriptChatStream([textSse('⟦skill:skill-c|fits gamma⟧'), textSse('')]);
    const { handle, assistant } = start({ skills: [GAMMA] });
    await handle.done;

    expect(chat.calls()).toBe(2);
    expectEmptyResponseFailure(assistant());
    expect(assistant()!.text ?? '').toBe('');
  });

  it('plain_empty_stream_fails_empty_response', async () => {
    scriptChatStream([FINISH]);
    const { handle, assistant } = start();
    await handle.done;

    expectEmptyResponseFailure(assistant());
  });

  it('reasoning_only_reply_fails_empty_response', async () => {
    scriptChatStream([reasoningOnlySse('Thinking about gamma.')]);
    const { handle, assistant } = start();
    await handle.done;

    expectEmptyResponseFailure(assistant());
    expect((assistant()!.text ?? '').trim()).toBe('');
  });

  it('continue_empty_reply_fails', async () => {
    scriptChatStream([textSse('   ')]);
    const user: ChatMessage = {
      id: 'user-1', role: 'user', text: 'Tell me about gamma.', state: 'delivered', createdAt: '2026-10-03T00:00:01.000Z',
    } as ChatMessage;
    const partial: ChatMessage = {
      id: 'assistant-1', role: 'assistant', text: 'Gamma is', state: 'interrupted', stopReason: 'interrupted',
      providerID: 'provider-1', modelID: 'gpt-4o', createdAt: '2026-10-03T00:00:02.000Z',
    } as ChatMessage;
    const conv = conversation([user, partial]);
    const store = createAppStore({ conversations: [conv] });
    currentStore.value = store;
    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { messageId: partial.id, conversation: conv, messages: conv.messages, provider: provider(), model: model(), reasoningMode: 'automatic' },
    );
    await handle.done;

    const message = store.getState().conversations[0]!.messages.find((item) => item.id === partial.id);
    expectEmptyResponseFailure(message);
    // The text the earlier round delivered is kept.
    expect(message!.text?.trim()).toBe('Gamma is');
  });

  it('continue_overflow_after_reasoning_records_context_window_exceeded', async () => {
    // Reasoning streamed, then the upstream stopped with a context-window overflow: the overflow wins over empty_response.
    mocks.runStreamPipeline.mockImplementationOnce(async () => ({
      outcome: 'completed', fullText: '', reasoningText: 'thinking about it', usage: undefined, imageAttachments: [],
      servedModelID: 'gpt-4o', citations: undefined, capabilityResults: [], managed: undefined,
      finish: { family: 'anthropic', ended: 'clean', finishRaw: 'model_context_window_exceeded' },
    }));
    scriptChatStream([]);
    const user: ChatMessage = {
      id: 'user-1', role: 'user', text: 'Tell me about gamma.', state: 'delivered', createdAt: '2026-10-03T00:00:01.000Z',
    } as ChatMessage;
    const partial: ChatMessage = {
      id: 'assistant-1', role: 'assistant', text: 'Gamma is', state: 'interrupted', stopReason: 'interrupted',
      providerID: 'provider-1', modelID: 'gpt-4o', createdAt: '2026-10-03T00:00:02.000Z',
    } as ChatMessage;
    const conv = conversation([user, partial]);
    const store = createAppStore({ conversations: [conv] });
    currentStore.value = store;
    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { messageId: partial.id, conversation: conv, messages: conv.messages, provider: provider(), model: model(), reasoningMode: 'automatic' },
    );
    await handle.done;

    const message = store.getState().conversations[0]!.messages.find((item) => item.id === partial.id);
    expect(message).toMatchObject({ state: 'failed', stopReason: 'context_window_exceeded' });
    expect(message!.errorKind).not.toBe('emptyResponse');
    expect(message!.text?.trim()).toBe('Gamma is');
  });

  it('propose_with_empty_tail_stays_delivered', async () => {
    const userText = 'Remember that I prefer concise answers.';
    const proposeArgs = JSON.stringify({
      proposition: 'The user prefers concise answers.', kind: 'preference', scope: 'global',
      sourceQuote: 'I prefer concise answers',
    });
    // The candidate comes from the production pure function, so it is a real proposal.
    mocks.propose.mockImplementation(async (argumentsJson: string, priorInTurn: number, context: {
      userText: string; messageId: string; conversationId: string; folderId: string | null;
    }) => proposeMemoryCandidate(argumentsJson, { ...context, nowMs: 1_000, activeContents: [], records: [] }, priorInTurn).candidate);
    const chat = scriptChatStream([proposeMemorySse(proposeArgs), textSse('')]);
    const { handle, assistant } = start({ text: userText });
    await handle.done;

    expect(chat.calls()).toBe(2);
    expect(mocks.propose).toHaveBeenCalledTimes(1);
    expect(assistant()?.state).toBe('delivered');
    expect(assistant()?.errorKind).toBeUndefined();
    // The suggestion bar the proposal raised is still up.
    expect(getPendingMemorySuggestion()).toMatchObject({
      status: 'candidate', messageId: expect.any(String), candidate: expect.objectContaining({ content: 'The user prefers concise answers.' }),
    });
  });

  it('stop_before_content_stays_cancel_path', async () => {
    mocks.runStreamPipeline.mockImplementationOnce(async (params: { setAbortFn: (fn: () => void) => void }) => {
      params.setAbortFn(vi.fn());
      return {
        outcome: 'completed', fullText: '', reasoningText: '', usage: undefined, imageAttachments: [],
        servedModelID: 'gpt-4o', citations: undefined, capabilityResults: [], managed: undefined,
      };
    });
    scriptChatStream([]);
    const { handle, assistant } = start();
    handle.abort();
    await handle.done;

    expect(assistant()?.state).not.toBe('failed');
    expect(assistant()?.errorKind).toBeUndefined();
    expect(assistant()?.stopReason).toBe('interrupted');
  });
});
