// @vitest-environment jsdom
//
// sendMessage happy-path integration test (paid BYOK provider, stream completes naturally -> delivered).
//
// Exercises the real sendMessage -> prepareSendStart -> runStreamPipeline -> reportSendCompletion
// chain; only the network layer (sendStream/readStream) and external side effects
// (usage/sync/partition/knowledge/metadata) are mocked.
// Important: the readStream mock must return a complete StreamPipelineResult shape, including
// reasoningText:'', otherwise `reasoningText.trim()` in operations-send throws, is caught and
// turns into failed, which means the happy path is never exercised.

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Note, Provider } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { selectStreamingConversationIds } from '../../store/selectors';
import { continueAnswering, retryMessage, sendMessage } from '../operations';
import { toProviderError } from '../../providers/errors';
import { generationParameterProfileFingerprint, saveGenerationParameterOverrides, valueOverride } from '../generation-parameter-settings';
import type { StreamOptions } from '../../providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  processImageAttachments: vi.fn(),
  getSyncAdapter: vi.fn(),
  executeLibraryTool: vi.fn(),
  executeLibraryResearch: vi.fn(),
  requestLibraryConfirmation: vi.fn(),
  captureException: vi.fn(),
  trackEvent: vi.fn(),
  continuationStarted: vi.fn(),
  continuationCompleted: vi.fn(),
  continuationInterrupted: vi.fn(),
  continuationForExplicitContinue: vi.fn(),
  continuationCaptured: vi.fn(),
}));

vi.mock('../../providers/service', () => ({
  sendStream: (...args: unknown[]) => mocks.sendStream(...args),
}));

vi.mock('../../../utils/chat-stream-utils', () => ({
  buildChatHistory: (...args: unknown[]) => mocks.buildChatHistory(...args),
  readStream: (...args: unknown[]) => mocks.readStream(...args),
  mapErrorKindKey: () => 'network',
  sanitizeOutboundMessages: (msgs: unknown[]) => msgs,
}));

vi.mock('../../../utils/stream-image-utils', () => ({
  processImageAttachments: (...args: unknown[]) => mocks.processImageAttachments(...args),
  backfillStorageRefs: vi.fn(),
}));

vi.mock('../../sync-port', () => ({
  getSyncAdapter: (...args: unknown[]) => mocks.getSyncAdapter(...args),
  deleteAttachments: vi.fn(),
}));

vi.mock('../../library/api', () => ({
  executeLibraryTool: (...args: unknown[]) => mocks.executeLibraryTool(...args),
  executeLibraryResearch: (...args: unknown[]) => mocks.executeLibraryResearch(...args),
  isLibraryRateLimitError: () => false,
  isLibraryNotFoundError: () => false,
  LibraryAPIError: class LibraryAPIError extends Error {},
}));

vi.mock('../../library/confirmation', () => ({
  requestLibraryConfirmation: (...args: unknown[]) => mocks.requestLibraryConfirmation(...args),
  clearOwnLibraryConfirmation: vi.fn(),
}));

vi.mock('@sentry/nextjs', () => ({
  captureException: (...args: unknown[]) => mocks.captureException(...args),
}));

vi.mock('../../telemetry', async () => ({
  trackEvent: (...args: unknown[]) => mocks.trackEvent(...args),
  telemetryProviderKind: (kind: string) => kind,
  // Use the real relay downgrade implementation; reimplementing the rule in a test double only tests the double
  telemetryModelID: (await vi.importActual<typeof import('../../telemetry')>('../../telemetry')).telemetryModelID,
}));

vi.mock('../continuation-lifecycle', () => ({
  continuationSendStarted: (...args: unknown[]) => mocks.continuationStarted(...args),
  continuationSendCompleted: (...args: unknown[]) => mocks.continuationCompleted(...args),
  continuationSendInterrupted: (...args: unknown[]) => mocks.continuationInterrupted(...args),
  continuationForExplicitContinue: (...args: unknown[]) => mocks.continuationForExplicitContinue(...args),
  continuationCaptured: (...args: unknown[]) => mocks.continuationCaptured(...args),
  deleteLocalMessageContinuation: vi.fn(),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUID: vi.fn(),
}));

vi.mock('../../skills/knowledge-api', () => ({
  retrieveKnowledgeSnippets: vi.fn(),
}));

vi.mock('../../metadata/metadata-client', () => ({
  // These fixtures carry no metadata ETag, so identity has no revision and the negative cache fails closed.
  getMetadataRevision: () => undefined,
  getCapabilityRuntime: () => undefined,
  // The completion-time tool_call mismatch event also goes through the central evidence facade; no modelFacts here.
  getModelFacts: () => undefined,
  getModelFactsRevision: () => undefined,
  // The send chain goes activeGenerationParameterIds -> resolveGenerationProfileForModel and calls
  // that single export unconditionally, so a test double missing it throws for the whole send path (these
  // fixtures have no metadata profile anyway).
  resolveGenerationProfileRef: vi.fn(() => undefined),
  resolveCatalogModel: vi.fn(() => null),
  // The send chain also asks whether this web search preference can reach the wire right now, and
  // that check reads the catalog transport through `presentCapabilityControl`. A test double missing it
  // throws for the whole send path as well.
  getModelTransport: vi.fn(() => undefined),
  getDeclaredReasoningLevels: vi.fn(() => []),
  getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
  // cost.ts prices through lookupPricing (only reached for paid providers; free short-circuits to $0). Give it a real price so cost > 0.
  lookupPricing: vi.fn(() => ({ promptPerToken: 0.000001, completionPerToken: 0.000002 })),
  getLibraryRuntimeConfig: vi.fn(() => ({
    version: 3,
    toolDescriptions: {},
    maxSteps: 6,
    toolTimeoutMs: 15_000,
    maxEmptyHits: 2,
    maxSelfCorrections: 3,
    tokenBudget: 0,
    estimatedTokensPerStep: 2_000,
    highCostConfirmationUSD: 0.25,
    weakModelDenylist: [],
    sensitiveGateEnabled: true,
  })),
}));

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'p-openai',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: '••test',
    ...overrides,
  };
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-4o',
    name: 'GPT-4o',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: '$',
    ...overrides,
  };
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1',
    title: 'Existing',
    hasCustomTitle: false,
    providerID: 'p-openai',
    providerKind: 'openAI',
    modelID: 'gpt-4o',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: '2026-04-12T00:00:00.000Z',
    updatedAt: '2026-04-12T00:00:00.000Z',
    ...overrides,
  };
}

function makeNote(overrides: Partial<Note> = {}): Note {
  return {
    id: 'note-a',
    title: 'Vector recall',
    titleSource: 'manual',
    body: 'Use tags first, then keywords.',
    tags: ['vector'],
    captureKind: 'blank',
    createdAt: '2026-06-19T00:00:00.000Z',
    updatedAt: '2026-06-19T00:00:00.000Z',
    ...overrides,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'hello' }]);
  mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
  // Complete readStream result, so the delivered branch is taken
  mocks.readStream.mockResolvedValue({
    fullText: 'Hello there',
    reasoningText: '',
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
    imageAttachments: [],
    servedModelID: 'gpt-4o',
    citations: undefined,
  });
  mocks.processImageAttachments.mockResolvedValue({
    finalText: 'Hello there',
    processedAttachments: [],
  });
  mocks.getSyncAdapter.mockReturnValue(undefined);
  mocks.executeLibraryTool.mockResolvedValue({
    result: {
      docId: 'roadmap',
      source: 'notion',
      title: 'Q3 Roadmap',
      url: 'https://www.notion.so/roadmap',
      sections: [{ heading: 'Launch', text: 'Ship in September.', anchor: 'launch' }],
    },
  });
  mocks.requestLibraryConfirmation.mockResolvedValue('continue');
  mocks.executeLibraryResearch.mockResolvedValue({
    result: {
      query: 'Summarize the launch date',
      documents: [{
        docId: 'roadmap',
        source: 'notion',
        title: 'Q3 Roadmap',
        url: 'https://www.notion.so/roadmap',
        sections: [{ heading: 'Launch', text: 'Ship in September.', anchor: 'launch' }],
        sensitive: { hit: false },
        riskLevel: 'normal',
      }],
      steps: [{ tool: 'library_search', label: 'Summarize the launch date', status: 'completed' }],
    },
  });
});

describe('sendMessage happy path', () => {
  it('existing conversation: stream completes and writes user + delivered assistant, clears the stream and reports usage', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    const quoteContext = {
      schemaVersion: 1 as const, sourceMessageId: 'source-byok', sourceRole: 'assistant' as const,
      contentKind: 'prose' as const, leadingText: 'before ', selectedText: 'selected',
      trailingText: ' after', contextTruncated: false,
    };

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { text: 'hello', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic', quoteContext },
    );

    expect(handle.convId).toBe('conv-1');
    await handle.done;

    const conv = store.getState().conversations.find((c) => c.id === 'conv-1')!;
    const user = conv.messages.find((m) => m.role === 'user');
    const assistant = conv.messages.find((m) => m.role === 'assistant');
    expect(user?.text).toBe('hello');
    expect(user?.quoteContext).toEqual(quoteContext);
    expect(mocks.buildChatHistory).toHaveBeenCalledWith(
      expect.arrayContaining([expect.objectContaining({ role: 'user', text: 'hello', quoteContext })]),
      model,
      'openAI',
    );
    expect(mocks.captureException).not.toHaveBeenCalled();
    expect(assistant?.id).toBe(handle.msgId);
    expect(assistant?.state).toBe('delivered');
    expect(assistant?.text).toBe('Hello there');
    expect(assistant?.servedModelID).toBe('gpt-4o');
    // Real send lifecycle creates then clears a local-only continuation record; this is not
    // a telemetry/sync assertion and never resumes the loop on reload.
    expect(mocks.continuationStarted).toHaveBeenCalledWith('conv-1', handle.msgId);
    expect(mocks.continuationCompleted).toHaveBeenCalledWith('conv-1', handle.msgId);
    // Ordinary sends never read opaque replay state; only continueAnswering owns that consumer.
    expect(mocks.continuationForExplicitContinue).not.toHaveBeenCalled();
    // Usage pricing hit, so a real cost is computed (10 prompt + 5 completion tokens)
    expect(assistant?.estimatedCost).toBeGreaterThan(0);

    // Stream cleared by the finally clearStreamingForConversation
    expect(selectStreamingConversationIds(store.getState())).not.toContain('conv-1');

    expect(mocks.sendStream).toHaveBeenCalledWith(
      'openAI', 'sk-test', 'gpt-4o', expect.any(Array), undefined,
      undefined,
    );
    const finalOptions = mocks.sendStream.mock.calls[0][5] as StreamOptions;
    expect(finalOptions?.customFragments).toBeUndefined();
    expect(finalOptions?.generationParameters).toBeUndefined();
    expect(finalOptions?.reasoning).toBeUndefined();
  });

  it('explicit model-control resend appends while preserving prior generated reasoning, attachments and citations', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const user: ChatMessage = {
      id: 'user-partial', role: 'user', text: 'hello', providerID: provider.id,
      providerKind: provider.kind, providerName: 'OpenAI', modelID: model.id,
      modelName: model.name, estimatedCost: 0, state: 'delivered',
    };
    const oldAttachment = { id: 'image-old', kind: 'image' as const, fileName: 'old.png', mimeType: 'image/png', localImageID: 'old-local' };
    const newAttachment = { id: 'image-new', kind: 'image' as const, fileName: 'new.png', mimeType: 'image/png', localImageID: 'new-local' };
    const assistant: ChatMessage = {
      id: 'assistant-partial', role: 'assistant', text: 'Partial answer', providerID: provider.id,
      providerKind: provider.kind, providerName: 'OpenAI', modelID: model.id,
      modelName: model.name, estimatedCost: 0.5, state: 'failed',
      reasoningText: 'Existing reasoning', reasoningDurationMs: 250,
      attachments: [oldAttachment], citations: [{ url: 'https://example.com/old', title: 'Old' }],
    };
    const conversation = makeConversation({ messages: [user, assistant] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.readStream.mockResolvedValueOnce({
      fullText: 'Partial answer completed', reasoningText: 'New reasoning', reasoningDurationMs: 100,
      usage: { prompt_tokens: 2, completion_tokens: 3, total_tokens: 5 }, imageAttachments: [],
      servedModelID: model.id, citations: [{ url: 'https://example.com/new', title: 'New' }],
    });
    mocks.processImageAttachments.mockResolvedValueOnce({
      finalText: 'Partial answer completed', processedAttachments: [newAttachment],
    });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: user.text, prevMessages: [user], conversation, provider, model,
        reasoningMode: 'automatic', userMessageOverride: user,
        assistantMessageOverride: { ...assistant, state: 'generating' }, persistUserMessage: false,
        userMessageAlreadyInHistory: true, appendToAssistant: true,
      },
    );
    await handle.done;

    const delivered = store.getState().conversations[0]!.messages.find((message) => message.id === assistant.id)!;
    expect(delivered).toMatchObject({
      state: 'delivered', text: 'Partial answer completed',
      reasoningText: 'Existing reasoning\n\nNew reasoning', reasoningDurationMs: 250,
      attachments: [oldAttachment, newAttachment],
      citations: [
        { url: 'https://example.com/old', title: 'Old' },
        { url: 'https://example.com/new', title: 'New' },
      ],
    });
    expect(delivered.estimatedCost).toBeGreaterThan(0.5);
  });

  it('a capability-carrying send keeps full lifecycle telemetry while an unreachable web preference stays unreported', async () => {
    const provider = makeProvider();
    const supportedModel = makeModel({
      capabilities: ['text', 'web'], webSearchProfile: 'oai_web', transport: 'openai_chat',
    });
    const supportedConversation = makeConversation();
    const supportedStore = createAppStore({ providers: [provider], conversations: [supportedConversation] });
    const capabilityContext = {
      version: 1 as const,
      revision: 'p5-test',
      entries: [{
        owner: 'web' as const,
        source: 'provider_recipe' as const,
        wireApplied: true,
        definition: {
          capability: 'web' as const,
          protocol: 'openai_chat',
          responseParserKind: 'openai_proxy_sse',
          signals: [{ producerEvent: 'citations', pointer: '/choices/*/delta/annotations', nonEmpty: true }],
        },
      }],
    };
    mocks.sendStream.mockReturnValueOnce({
      stream: {} as ReadableStream,
      abort: vi.fn(),
      getCapabilityResultContext: () => capabilityContext,
      capabilityResultContextReady: Promise.resolve(capabilityContext),
    });

    await sendMessage(
      { store: supportedStore, appendChunk: vi.fn(), te: (key) => key },
      { text: 'search', prevMessages: [], conversation: supportedConversation, provider, model: supportedModel, reasoningMode: 'automatic', webSearchEnabled: true },
    ).done;
    // A wire fact only narrows which fields are allowed in; it does not downgrade the whole lifecycle to a bare event.
    expect(mocks.trackEvent).toHaveBeenCalledWith('chat_message_sent', expect.objectContaining({
      provider_kind: 'openAI', model_id: 'gpt-4o',
    }));
    expect(mocks.trackEvent).toHaveBeenCalledWith('chat_message_completed', expect.objectContaining({
      provider_kind: 'openAI', model_id: 'gpt-4o',
    }));
    // These fixtures have no metadata (getCapabilityRuntime/getModelTransport are both undefined),
    // so the web search preference cannot reach the wire and the outbound options carry no
    // supportsWebSearch. The positive case lives in chat-lifecycle-telemetry.test.ts.
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('web_search_used', expect.anything());

    mocks.trackEvent.mockClear();
    const unsupportedModel = makeModel({ transport: 'openai_chat' });
    const unsupportedConversation = makeConversation({ id: 'conv-no-web' });
    const unsupportedStore = createAppStore({ providers: [provider], conversations: [unsupportedConversation] });
    await sendMessage(
      { store: unsupportedStore, appendChunk: vi.fn(), te: (key) => key },
      { text: 'search', prevMessages: [], conversation: unsupportedConversation, provider, model: unsupportedModel, reasoningMode: 'automatic', webSearchEnabled: true },
    ).done;

    expect(mocks.trackEvent).toHaveBeenCalledWith('chat_message_sent', expect.objectContaining({
      web_search_enabled: true,
    }));
    expect(mocks.trackEvent).not.toHaveBeenCalledWith('web_search_used', expect.anything());
  });

  it('a stream failure keeps provider/model/error_code on lifecycle telemetry and skips Sentry context', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    const capabilityContext = {
      version: 1 as const,
      revision: 'p5-test',
      entries: [{
        owner: 'reasoning' as const,
        source: 'provider_recipe' as const,
        wireApplied: true,
        definition: {
          capability: 'reasoning' as const,
          protocol: 'openai_chat',
          responseParserKind: 'openai_proxy_sse',
          signals: [{ producerEvent: 'reasoning', pointer: '/choices/*/delta/reasoning_content', nonEmpty: true }],
        },
      }],
    };
    mocks.sendStream.mockReturnValueOnce({
      stream: {} as ReadableStream,
      abort: vi.fn(),
      getCapabilityResultContext: () => capabilityContext,
      capabilityResultContextReady: Promise.resolve(capabilityContext),
    });
    mocks.readStream.mockRejectedValueOnce(new Error('upstream body must remain local'));

    await sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { text: 'reason', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic' },
    ).done;

    expect(mocks.trackEvent).toHaveBeenCalledWith('chat_message_sent', expect.objectContaining({
      provider_kind: 'openAI', model_id: 'gpt-4o',
    }));
    expect(mocks.trackEvent).toHaveBeenCalledWith('chat_message_failed', expect.objectContaining({
      provider_kind: 'openAI', model_id: 'gpt-4o', error_code: expect.any(String),
    }));
    // Upstream text stays local: the raw error message must never appear in telemetry
    const failedProps = mocks.trackEvent.mock.calls.find(([event]) => event === 'chat_message_failed')?.[1];
    expect(JSON.stringify(failedProps)).not.toMatch(/upstream body must remain local/);
    expect(mocks.captureException).not.toHaveBeenCalled();
  });


  // Server-side retrieval reuses the same injection pipeline as explicitly named documents, so the
  // model needs no tool capability at all
  it('server-side retrieval injects an envelope plus identity-only citations and sets the retry flag', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.buildChatHistory.mockResolvedValue([
      { role: 'user', content: 'Summarize the launch date' },
    ]);

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        webSearchEnabled: true,
        libraryServerResearch: {
          query: 'Summarize the launch date',
          sources: ['notion'],
        },
      },
    );
    await handle.done;

    expect(mocks.executeLibraryResearch).toHaveBeenCalledWith(
      'Summarize the launch date',
      ['notion'],
      expect.objectContaining({
        providerKind: 'openAI',
        researchId: expect.any(String),
        toolCallId: expect.stringContaining('research:'),
        maxDocuments: 5,
      }),
    );

    const history = mocks.sendStream.mock.calls[0][3] as Array<{ role: string; content: string }>;
    expect(history[0]).toMatchObject({
      role: 'system',
      content: expect.stringContaining('untrusted evidence'),
    });
    const lastUser = [...history].reverse().find((message) => message.role === 'user');
    expect(lastUser?.content).toContain('<library_context>');
    expect(lastUser?.content).toContain('Ship in September.');

    const assistant = store.getState().conversations
      .find((c) => c.id === 'conv-1')!.messages.find((m) => m.role === 'assistant');
    // libraryResearchEnabled is the retry flag: lose it and a retry silently falls back to a plain send
    expect(assistant?.libraryResearchEnabled).toBe(true);
    expect(assistant?.researchSteps).toEqual([
      expect.objectContaining({ tool: 'library_search', status: 'completed', step: 1 }),
    ]);
    expect(assistant?.citations).toEqual([
      expect.objectContaining({
        index: 1,
        docId: 'roadmap',
        source: 'notion',
        url: 'https://www.notion.so/roadmap',
      }),
    ]);
    // Body text and snippets belong to this outbound request only and never enter message storage
    expect(JSON.stringify(assistant?.citations)).not.toContain('Ship in September.');
  });

  it('cancelled server-side retrieval writes the cancellation text and no citations', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.requestLibraryConfirmation.mockResolvedValue('cancel');
    mocks.executeLibraryResearch.mockResolvedValue({
      result: {
        documents: [{
          docId: 'secret',
          source: 'notion',
          title: 'Secrets',
          url: 'https://www.notion.so/secret',
          sections: [{ text: 'api_key=raw-secret' }],
          sensitive: { hit: true },
          redacted: { title: 'Secrets', sections: [] },
        }],
        steps: [],
      },
    });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        libraryServerResearch: { query: 'Summarize the launch date' },
        libraryContextCancelledText: 'Library research was cancelled.',
      },
    );
    await handle.done;

    expect(mocks.sendStream).not.toHaveBeenCalled();
    const assistant = store.getState().conversations
      .find((c) => c.id === 'conv-1')!.messages.find((m) => m.role === 'assistant');
    expect(assistant).toMatchObject({
      text: 'Library research was cancelled.',
      state: 'delivered',
    });
    expect(assistant?.citations).toBeUndefined();
  });

  it('new conversation: with no conversation, one is created, onNewConversation fires and the delivered result is bound', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const store = createAppStore({ providers: [provider], conversations: [] });
    const onNewConversation = vi.fn();

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'first message',
        prevMessages: [],
        conversation: undefined,
        provider,
        model,
        reasoningMode: 'automatic',
        onNewConversation,
      },
    );

    // New conversation is created and the callback fires
    expect(onNewConversation).toHaveBeenCalledTimes(1);
    const newId = onNewConversation.mock.calls[0][0] as string;
    expect(handle.convId).toBe(newId);
    expect(store.getState().activeConversationId).toBe(newId);

    await handle.done;

    const conv = store.getState().conversations.find((c) => c.id === newId)!;
    expect(conv).toBeTruthy();
    expect(conv.messages.find((m) => m.role === 'user')?.text).toBe('first message');
    const assistant = conv.messages.find((m) => m.role === 'assistant');
    expect(assistant?.state).toBe('delivered');
    expect(assistant?.text).toBe('Hello there');
    expect(selectStreamingConversationIds(store.getState())).not.toContain(newId);
  });

  it('new conversation: pending pinned notes are saved with the first round for prompt injection to read', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const store = createAppStore({
      providers: [provider],
      conversations: [],
      notes: [makeNote()],
    });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'first message with note context',
        prevMessages: [],
        conversation: undefined,
        provider,
        model,
        reasoningMode: 'automatic',
        pinnedNoteIds: ['note-a'],
      },
    );

    await handle.done;

    const conv = store.getState().conversations.find((c) => c.id === handle.convId)!;
    expect(conv.pinnedNoteIds).toEqual(['note-a']);
    const sentMessages = mocks.sendStream.mock.calls[0][3] as Array<{ role: string; content: string }>;
    expect(sentMessages[0]).toMatchObject({
      role: 'system',
      content: expect.stringContaining('[Pinned Notes - untrusted user-saved reference data]'),
    });
    expect(sentMessages[0].content).toContain('"title":"Vector recall"');
    expect(sentMessages[0].content).toContain('Use tags first, then keywords.');
  });

  it('Add context reads the whole document and injects only its body into the request', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.readStream.mockResolvedValueOnce({
      fullText: 'Hello there',
      reasoningText: '',
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      imageAttachments: [],
      servedModelID: 'gpt-4o',
      citations: [{
        url: 'https://provider.example/annotation',
        title: 'Provider annotation',
        snippet: 'must not persist beside direct context',
      }],
    });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        webSearchEnabled: true,
        libraryContextDocuments: [{
          docId: 'roadmap',
          source: 'notion',
          title: 'Q3 Roadmap',
        }],
      },
    );
    await handle.done;

    expect(mocks.executeLibraryTool).toHaveBeenCalledWith(
      'library_read',
      { docId: 'roadmap', source: 'notion' },
      expect.any(AbortSignal),
      expect.objectContaining({
        researchId: expect.any(String),
        toolCallId: 'direct:notion:roadmap:1',
      }),
    );
    const history = mocks.sendStream.mock.calls[0][3] as Array<{ role: string; content: string }>;
    expect(history[0]).toMatchObject({
      role: 'system',
      content: expect.stringContaining('untrusted evidence'),
    });
    expect(history.at(-1)?.content).toContain('<library_context>');
    expect(history.at(-1)?.content).toContain('Ship in September.');

    const assistant = store.getState().conversations[0]?.messages.find((message) => message.role === 'assistant');
    expect(assistant?.citations).toEqual([
      expect.objectContaining({
        docId: 'roadmap',
        source: 'notion',
        url: 'https://www.notion.so/roadmap',
      }),
    ]);
    expect(JSON.stringify(assistant?.citations)).not.toContain('Provider annotation');
    expect(JSON.stringify(assistant?.citations)).not.toContain('must not persist');
    expect(assistant?.attachments).toBeUndefined();
  });

  it('after the user cancels document sharing, a delivered notice is written, citations are cleared and the model is not called', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.executeLibraryTool.mockResolvedValueOnce({
      result: {
        docId: 'roadmap',
        source: 'notion',
        title: 'Q3 Roadmap',
        url: 'https://www.notion.so/roadmap',
        sections: [{ text: 'PRIVATE' }],
        sensitive: { hit: true, kinds: ['credential'] },
        redacted: {
          title: 'Q3 Roadmap',
          sections: [{ text: '[REDACTED_SECRET]' }],
        },
      },
    });
    mocks.requestLibraryConfirmation.mockResolvedValueOnce('cancel');

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the roadmap',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        libraryContextDocuments: [{
          docId: 'roadmap',
          source: 'notion',
          title: 'Q3 Roadmap',
        }],
        libraryContextCancelledText: 'Cancelled locally',
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.role === 'assistant',
    );
    expect(assistant).toMatchObject({
      state: 'delivered',
      text: 'Cancelled locally',
    });
    expect(assistant?.citations).toBeUndefined();
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  it('SendHandle.done resolves on completion without taking the failed branch (no errorTitle)', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => `err:${key}` },
      { text: 'hi', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic' },
    );
    await expect(handle.done).resolves.toBeUndefined();

    const assistant = store
      .getState()
      .conversations.find((c) => c.id === 'conv-1')!
      .messages.find((m) => m.role === 'assistant');
    expect(assistant?.errorTitle).toBeUndefined();
    expect(assistant?.state).not.toBe('failed');
  });
});

// Highest-priority scope in generation parameter resolution: the single-use transient value.
// There is no UI producer for it yet, but the resolve() call path has to be wired end to end so
// transient parameters do not stay a dead parameter.
describe('single-use transientGenerationParameters wiring', () => {
  beforeEach(() => localStorage.clear());

  it('sendMessage: transient overrides take priority over saved conversation overrides and go out together', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    saveGenerationParameterOverrides(
      {
        providerId: provider.id,
        modelId: model.id,
        conversationId: conversation.id,
        profileFingerprint: generationParameterProfileFingerprint(provider, model),
      },
      { temperature: valueOverride(0.2) },
    );

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'hello', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic',
        transientGenerationParameters: { temperature: valueOverride(0.9) },
      },
    );
    await handle.done;

    const relayStreamOptions = mocks.sendStream.mock.calls[0][5] as StreamOptions | undefined;
    // The test has no complete Relay identity/final endpoint, so even an
    // explicit transient value fails closed at the request boundary.
    expect(relayStreamOptions?.generationParameters).toBeUndefined();
  });

  it('continueAnswering: same transient wiring, taking priority over saved conversation overrides', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg = {
      id: 'u-transient', role: 'user', text: 'question', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const interruptedMsg = {
      id: 'a-transient', role: 'assistant', text: 'partial', state: 'interrupted',
      createdAt: '2026-04-12T00:00:00.001Z',
    } as ChatMessage;
    const conversation = makeConversation({ messages: [userMsg, interruptedMsg] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    saveGenerationParameterOverrides(
      {
        providerId: provider.id,
        modelId: model.id,
        conversationId: conversation.id,
        profileFingerprint: generationParameterProfileFingerprint(provider, model),
      },
      { temperature: valueOverride(0.2) },
    );

    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: 'a-transient', conversation, messages: [userMsg, interruptedMsg], provider, model,
        reasoningMode: 'automatic',
        transientGenerationParameters: { temperature: valueOverride(0.9) },
      },
    );
    await handle.done;

    const relayStreamOptions = mocks.sendStream.mock.calls[0][5] as StreamOptions | undefined;
    expect(relayStreamOptions?.generationParameters).toBeUndefined();
  });

  it('continueAnswering: opaque state is read only at the explicit entry point, and the round completes serially', async () => {
    mocks.continuationForExplicitContinue.mockResolvedValue({ kind: 'previous_id', step: 1, state: { previousResponseId: 'resp_1' } });
    mocks.continuationStarted.mockResolvedValue(undefined);
    mocks.continuationCompleted.mockResolvedValue(undefined);
    const provider = makeProvider(); const model = makeModel();
    const user = { id: 'u-explicit', role: 'user', text: 'question', state: 'delivered', createdAt: '2026-04-12T00:00:00.000Z' } as ChatMessage;
    const interrupted = { id: 'a-explicit', role: 'assistant', text: 'partial', state: 'interrupted', createdAt: '2026-04-12T00:00:00.001Z' } as ChatMessage;
    const conversation = makeConversation({ messages: [user, interrupted] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    const handle = continueAnswering({ store, appendChunk: vi.fn(), te: (key) => key }, { messageId: interrupted.id, conversation, messages: [user, interrupted], provider, model, reasoningMode: 'automatic' });
    await handle.done;
    expect(mocks.continuationForExplicitContinue).toHaveBeenCalledWith(conversation.id, interrupted.id);
    expect(mocks.continuationStarted).toHaveBeenCalledWith(conversation.id, interrupted.id);
    expect(mocks.continuationCompleted).toHaveBeenCalledWith(conversation.id, interrupted.id);
    // previous_id owns the old transcript; the real pipeline receives only the new explicit user input.
    expect(mocks.sendStream.mock.calls.at(-1)?.[3]).toEqual([{ role: 'user', content: '[Continue from where you left off]' }]);
  });
});

describe('a failed half round is not synced (whole-round atomic sync)', () => {
  function makeSyncMock() {
    return {
      didSendMessage: vi.fn(),
      didCompleteAssistantMessage: vi.fn(),
      didCompleteRound: vi.fn(),
    };
  }

  it('success: the whole round syncs through didCompleteRound (user+assistant together) and sending does not call didSendMessage on its own', async () => {
    const sync = makeSyncMock();
    mocks.getSyncAdapter.mockReturnValue(sync);
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { text: 'hello', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic' },
    );
    await handle.done;

    // Sending does not push the user message on its own, which is what keeps a failed half round off the cloud
    expect(sync.didSendMessage).not.toHaveBeenCalled();
    // Once the assistant succeeds, user + assistant sync in a single round
    expect(sync.didCompleteRound).toHaveBeenCalledTimes(1);
    const [userArg, assistantArg, convIdArg] = sync.didCompleteRound.mock.calls[0];
    expect(userArg.role).toBe('user');
    expect(userArg.text).toBe('hello');
    expect(assistantArg.role).toBe('assistant');
    expect(assistantArg.state).toBe('delivered');
    expect(convIdArg).toBe('conv-1');
  });

  it('failure: the half round is not synced - neither didCompleteRound nor didSendMessage is called, but it is marked failed locally', async () => {
    const sync = makeSyncMock();
    mocks.getSyncAdapter.mockReturnValue(sync);
    // Build the object with the production toProviderError from real HTTP semantics instead of
    // hand-writing kind/source. This regression locks down raw text passthrough, the responsibility
    // boundary and the Sentry decision at once.
    const upstreamError = toProviderError(
      429,
      JSON.stringify({
        error: {
          type: 'engine_overloaded_error',
          message: 'The engine is currently overloaded, please try again later',
        },
      }),
      'https://api.moonshot.cn/v1/chat/completions',
    );
    mocks.readStream.mockRejectedValueOnce(upstreamError);
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { text: 'will fail', prevMessages: [], conversation, provider, model, reasoningMode: 'automatic' },
    );
    await handle.done;

    // Still marked failed locally, so the error card and retry are unaffected
    const assistant = store.getState().conversations.find((c) => c.id === 'conv-1')!
      .messages.find((m) => m.role === 'assistant');
    expect(assistant?.state).toBe('failed');
    expect(assistant).toMatchObject({
      errorTitle: 'requestFailed.title',
      errorDetail: 'engine_overloaded_error | The engine is currently overloaded, please try again later',
      errorKind: 'rateLimited',
      errorSource: 'provider',
    });
    expect(mocks.captureException).not.toHaveBeenCalled();
    // But the whole half round (user + assistant) stays off the cloud
    expect(sync.didCompleteRound).not.toHaveBeenCalled();
    expect(sync.didSendMessage).not.toHaveBeenCalled();
  });

  it('continuation: after an interrupted half round succeeds, didCompleteRound resends the paired user + assistant rather than a lone assistant', async () => {
    const sync = makeSyncMock();
    mocks.getSyncAdapter.mockReturnValue(sync);
    const provider = makeProvider();
    const model = makeModel();
    // Interrupted half round: the user message was never synced, and the assistant is marked interrupted
    const userMsg = {
      id: 'u-1', role: 'user', text: 'question', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const interruptedMsg = {
      id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted',
      createdAt: '2026-04-12T00:00:00.001Z',
    } as ChatMessage;
    const conversation = makeConversation({ messages: [userMsg, interruptedMsg] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { messageId: 'a-1', conversation, messages: [userMsg, interruptedMsg], provider, model, reasoningMode: 'automatic' },
    );
    await handle.done;

    // A successful continuation must not send only the assistant, which would leave other clients with an orphan; the paired user + assistant is resent
    expect(sync.didCompleteRound).toHaveBeenCalledTimes(1);
    const [userArg, assistantArg, convIdArg] = sync.didCompleteRound.mock.calls[0];
    expect(userArg.id).toBe('u-1');
    expect(assistantArg.id).toBe('a-1');
    expect(assistantArg.state).toBe('delivered');
    expect(convIdArg).toBe('conv-1');
    expect(sync.didCompleteAssistantMessage).not.toHaveBeenCalled();
  });

  it('continuation: reuses the pinned note context of the conversation for system prompt injection', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg = {
      id: 'u-1', role: 'user', text: 'question about vector recall', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const interruptedMsg = {
      id: 'a-1', role: 'assistant', text: 'partial', state: 'interrupted',
      createdAt: '2026-04-12T00:00:00.001Z',
    } as ChatMessage;
    const conversation = makeConversation({
      messages: [userMsg, interruptedMsg],
      pinnedNoteIds: ['note-a'],
    });
    const store = createAppStore({
      providers: [provider],
      conversations: [conversation],
      notes: [makeNote({ id: 'note-a', title: 'Vector recall', body: 'Use the vector-store notes.' })],
    });

    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      { messageId: 'a-1', conversation, messages: [userMsg, interruptedMsg], provider, model, reasoningMode: 'automatic' },
    );
    await handle.done;

    const history = mocks.sendStream.mock.calls[0][3] as Array<{ role: string; content: string }>;
    expect(history[0].role).toBe('system');
    expect(history[0].content).toContain('[Pinned Notes - untrusted user-saved reference data]');
    expect(history[0].content).toContain('Vector recall');
    expect(history[0].content).toContain('Use the vector-store notes.');
  });

  it('Add context retry after failure restores the documents from assistant citations and reads them again', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg = {
      id: 'u-context', role: 'user', text: 'summarize', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const failedMsg = {
      id: 'a-context', role: 'assistant', text: '', state: 'failed',
      createdAt: '2026-04-12T00:00:00.001Z',
      citations: [{
        url: 'library-context://notion/roadmap',
        title: 'Q3 Roadmap',
        docId: 'roadmap',
        source: 'notion',
      }],
    } as ChatMessage;
    const conversation = makeConversation({ messages: [userMsg, failedMsg] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = retryMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: failedMsg.id,
        conversation,
        messages: [userMsg, failedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );
    expect(handle).not.toBeNull();
    await handle!.done;

    expect(mocks.executeLibraryTool).toHaveBeenCalledWith(
      'library_read',
      { docId: 'roadmap', source: 'notion' },
      expect.any(AbortSignal),
      {
        researchId: 'a-context',
        toolCallId: 'direct:notion:roadmap:1',
        // Explicitly named documents must declare direct so the server applies its own read limit
        // (the agent limit of 6 exists to keep the model from running away, which a user-picked set
        // cannot do). Omitting it falls back to the agent limit and the seventh document 429s the
        // whole message.
        mode: 'direct',
      },
    );
    const assistant = store.getState().conversations[0]?.messages.find((message) => message.role === 'assistant');
    expect(assistant?.state).toBe('delivered');
    expect(assistant?.citations?.[0]).toMatchObject({
      docId: 'roadmap',
      url: 'https://www.notion.so/roadmap',
    });
  });

  // Citations in research mode are retrieved evidence, not documents the user named. Inheriting
  // them would silently turn a retry into "re-read last round's documents", new evidence would
  // never be reachable, and the bubble would show chips the user never picked.
  it('retrying a research-mode message does not treat retrieved citations as named documents', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg = {
      id: 'u-research', role: 'user', text: 'summarize', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const failedMsg = {
      id: 'a-research', role: 'assistant', text: '', state: 'failed',
      createdAt: '2026-04-12T00:00:00.001Z',
      libraryResearchEnabled: true,
      citations: [{
        url: 'https://www.notion.so/roadmap',
        title: 'Q3 Roadmap',
        docId: 'roadmap',
        source: 'notion',
      }],
    } as ChatMessage;
    const conversation = makeConversation({ messages: [userMsg, failedMsg] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = retryMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: failedMsg.id,
        conversation,
        messages: [userMsg, failedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );
    await handle!.done;

    expect(mocks.executeLibraryTool).not.toHaveBeenCalled();
  });

  it('cancelling an Add context continuation keeps the existing answer, clears citations and does not call the model', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg = {
      id: 'u-context', role: 'user', text: 'summarize', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const interruptedMsg = {
      id: 'a-context', role: 'assistant', text: 'Partial answer', state: 'interrupted',
      createdAt: '2026-04-12T00:00:00.001Z',
      citations: [{
        url: 'library-context://notion/roadmap',
        title: 'Q3 Roadmap',
        docId: 'roadmap',
        source: 'notion',
      }],
    } as ChatMessage;
    const conversation = makeConversation({ messages: [userMsg, interruptedMsg] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.executeLibraryTool.mockResolvedValueOnce({
      result: {
        docId: 'roadmap',
        source: 'notion',
        title: 'Q3 Roadmap',
        url: 'https://www.notion.so/roadmap',
        sections: [{ text: 'PRIVATE' }],
        sensitive: { hit: true, kinds: ['credential'] },
        redacted: {
          title: 'Q3 Roadmap',
          sections: [{ text: '[REDACTED_SECRET]' }],
        },
      },
    });
    mocks.requestLibraryConfirmation.mockResolvedValueOnce('cancel');

    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: interruptedMsg.id,
        conversation,
        messages: [userMsg, interruptedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
        libraryContextCancelledText: 'Cancelled locally',
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.id === interruptedMsg.id,
    );
    expect(assistant).toMatchObject({
      state: 'delivered',
      text: 'Partial answer\n\nCancelled locally',
    });
    expect(assistant?.citations).toBeUndefined();
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  // Read steps are persisted with the message; restore routing looks only at libraryResearchEnabled.
  // The steps themselves are progress display and do not double as a pipeline marker.
  it('Add context read steps persist with the message without impersonating the research-mode marker', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        libraryContextDocuments: [{ docId: 'roadmap', source: 'notion', title: 'Q3 Roadmap' }],
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.role === 'assistant',
    );
    expect(assistant?.state).toBe('delivered');
    expect(assistant?.researchSteps).toEqual([
      expect.objectContaining({
        tool: 'library_read',
        label: 'Q3 Roadmap',
        status: 'completed',
      }),
    ]);
    expect(assistant?.libraryResearchEnabled).toBeUndefined();
  });

  // library_* failures take the generic catch on this path: without mapping, the raw server English
  // (or even the snake_case error code) is dumped on the user, and the recovery card cannot tell
  // that it should offer the "reconnect the library" action.
  it('a failed Add context read produces localized text and a library error code', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.executeLibraryTool.mockRejectedValueOnce(
      Object.assign(new Error('library connection expired'), {
        code: 'library_needs_reauth',
        status: 401,
      }),
    );

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        libraryContextDocuments: [{ docId: 'roadmap', source: 'notion', title: 'Q3 Roadmap' }],
        libraryFailurePresentation: {
          errorTitle: 'Library research failed',
          errorDetail: 'Something went wrong.',
          errorDetails: {
            library_needs_reauth: 'Reconnect your Library source.',
          },
        },
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.role === 'assistant',
    );
    expect(assistant).toMatchObject({
      state: 'failed',
      errorTitle: 'Library research failed',
      errorDetail: 'Reconnect your Library source.',
      // The recovery card dispatches its dedicated action on errorKind; writing it as a ProviderError kind leaves only the generic retry
      errorKind: 'library_needs_reauth',
    });
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  it('a failed server-side retrieval produces localized text and a library error code', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.executeLibraryResearch.mockRejectedValueOnce(
      Object.assign(new Error('monthly research quota exhausted'), {
        code: 'library_quota_exceeded',
        status: 429,
      }),
    );

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        libraryServerResearch: { query: 'Summarize the launch date', sources: ['notion'] },
        libraryFailurePresentation: {
          errorTitle: 'Library research failed',
          errorDetail: 'Something went wrong.',
          errorDetails: {
            library_quota_exceeded: 'Monthly Library quota exhausted.',
          },
        },
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.role === 'assistant',
    );
    expect(assistant).toMatchObject({
      state: 'failed',
      errorDetail: 'Monthly Library quota exhausted.',
      errorKind: 'library_quota_exceeded',
    });
  });

  // Error codes without dedicated text (disabled / not_found / source_error and so on) fall back to
  // a single generic sentence; the server snake_case must not be shown as is.
  it('a library error code without dedicated text falls back to the generic message', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.executeLibraryResearch.mockRejectedValueOnce(
      Object.assign(new Error('library_disabled'), {
        code: 'library_disabled',
        status: 403,
      }),
    );

    const handle = sendMessage(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        text: 'Summarize the launch date',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
        libraryServerResearch: { query: 'Summarize the launch date', sources: ['notion'] },
        libraryFailurePresentation: {
          errorTitle: 'Library research failed',
          errorDetail: 'Something went wrong.',
          errorDetails: { library_unavailable: 'Library is unavailable.' },
        },
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.role === 'assistant',
    );
    expect(assistant).toMatchObject({
      state: 'failed',
      errorDetail: 'Library is unavailable.',
      errorKind: 'library_disabled',
    });
  });

  it('a failed document re-read during continuation also produces localized text and a library error code', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const userMsg = {
      id: 'u-context', role: 'user', text: 'summarize', state: 'delivered',
      createdAt: '2026-04-12T00:00:00.000Z',
    } as ChatMessage;
    const interruptedMsg = {
      id: 'a-context', role: 'assistant', text: 'Partial answer', state: 'interrupted',
      createdAt: '2026-04-12T00:00:00.001Z',
      citations: [{
        url: 'library-context://notion/roadmap',
        title: 'Q3 Roadmap',
        docId: 'roadmap',
        source: 'notion',
      }],
    } as ChatMessage;
    const conversation = makeConversation({ messages: [userMsg, interruptedMsg] });
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    mocks.executeLibraryTool.mockRejectedValueOnce(
      Object.assign(new Error('slow down'), {
        code: 'library_rate_limited',
        status: 429,
      }),
    );

    const handle = continueAnswering(
      { store, appendChunk: vi.fn(), te: (key) => key },
      {
        messageId: interruptedMsg.id,
        conversation,
        messages: [userMsg, interruptedMsg],
        provider,
        model,
        reasoningMode: 'automatic',
        libraryFailurePresentation: {
          errorTitle: 'Library research failed',
          errorDetail: 'Something went wrong.',
          errorDetails: { library_rate_limited: 'Library source is busy.' },
        },
      },
    );
    await handle.done;

    const assistant = store.getState().conversations[0]?.messages.find(
      (message) => message.id === interruptedMsg.id,
    );
    expect(assistant).toMatchObject({
      state: 'failed',
      errorDetail: 'Library source is busy.',
      errorKind: 'library_rate_limited',
    });
  });
});
