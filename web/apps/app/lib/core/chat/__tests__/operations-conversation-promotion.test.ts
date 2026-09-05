// @vitest-environment jsdom

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Conversation, Provider, Skill } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { sendMessage } from '../operations';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  buildChatHistory: vi.fn(),
  readStream: vi.fn(),
  processImageAttachments: vi.fn(),
  resolveCatalogModel: vi.fn(),
  lookupPricing: vi.fn(),
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
  getSyncAdapter: () => undefined,
  deleteAttachments: vi.fn(),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUID: vi.fn(),
}));

// Keep the real exports and stub only what needs stubbing: a factory that replaces the whole module
// and misses a newly added export on the send path (such as getCapabilityRuntime, which
// operations-send calls unconditionally) makes the send path throw
// "undefined is not a function" before dispatch, turning the test red somewhere unrelated to the
// behavior under test.
vi.mock('../../metadata/metadata-client', async () => {
  const actual = await vi.importActual<typeof import('../../metadata/metadata-client')>(
    '../../metadata/metadata-client',
  );
  return {
    ...actual,
    // These fixtures carry no metadata ETag, so identity resolves no revision and the negative cache fails closed.
    getMetadataRevision: () => undefined,
    // The send path goes activeGenerationParameterIds -> resolveGenerationProfileForModel, which
    // calls this one export unconditionally; these fixtures have no metadata profile to begin with.
    resolveGenerationProfileRef: vi.fn(() => undefined),
    getDeclaredReasoningDefaultLevel: vi.fn(() => undefined),
    resolveCatalogModel: (...args: unknown[]) => mocks.resolveCatalogModel(...args),
    lookupPricing: (...args: unknown[]) => mocks.lookupPricing(...args),
  };
});

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'openai-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [{ id: 'gpt-5.4-mini', name: 'GPT-5.4 mini' } as Provider['models'][number]],
    catalogModels: [],
    apiKey: 'sk-openai',
    apiKeyPreview: '••••openai',
    baseURLText: 'https://api.openai.com/v1',
    ...overrides,
  };
}

function makeModel(overrides: Partial<AIModel> = {}): AIModel {
  return {
    id: 'gpt-4.1',
    name: 'GPT-4.1',
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: true,
    priceTier: 'standard',
    promptPrice: 0.001,
    completionPrice: 0.002,
    contextLength: 16_000,
    ...overrides,
  };
}

function makeSkill(overrides: Partial<Skill> = {}): Skill {
  return {
    id: overrides.id ?? 'skill-1',
    name: overrides.name ?? 'Knowledge Skill',
    description: overrides.description ?? 'Uses knowledge files',
    icon: overrides.icon ?? '✨',
    color: overrides.color ?? '#8B5CF6',
    systemPrompt: overrides.systemPrompt ?? 'Answer with grounded citations.',
    modelCapabilityHint: overrides.modelCapabilityHint ?? 'any',
    starterMessages: overrides.starterMessages ?? [],
    knowledgeFiles: overrides.knowledgeFiles ?? [
      {
        id: 'ref-1',
        name: 'notes.txt',
        mimeType: 'text/plain',
        sourceType: 'text',
        content: 'Reference context',
        charCount: 17,
        createdAt: '2026-04-12T00:00:00.000Z',
        updatedAt: '2026-04-12T00:00:00.000Z',
      },
    ],
    knowledgeBase: overrides.knowledgeBase ?? {
      provider: 'openai',
      retrievalModel: 'gpt-5.4-mini',
      vectorStoreId: 'vs_123',
      expiresAfterDays: 90,
      files: [
        {
          id: 'kb-1',
          name: 'guide.txt',
          mimeType: 'text/plain',
          sizeBytes: 120,
          ingestionMode: 'native_file',
          openAIFileId: 'file-1',
          status: 'ready',
          createdAt: '2026-04-12T00:00:00.000Z',
          updatedAt: '2026-04-12T00:00:00.000Z',
        },
      ],
      updatedAt: '2026-04-12T00:00:00.000Z',
    },
    useMemory: overrides.useMemory ?? true,
    isPinned: overrides.isPinned ?? false,
    pinOrder: overrides.pinOrder ?? 0,
    source: overrides.source ?? 'user',
    sortOrder: overrides.sortOrder ?? 0,
    usageCount: overrides.usageCount ?? 0,
    createdAt: overrides.createdAt ?? '2026-04-12T00:00:00.000Z',
    updatedAt: overrides.updatedAt ?? '2026-04-12T00:00:00.000Z',
  };
}

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'conv-1',
    title: 'Knowledge Chat',
    hasCustomTitle: false,
    providerID: 'openai-1',
    modelID: 'gpt-4.1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-04-12T00:00:00.000Z',
    skillId: 'skill-1',
    ...overrides,
  };
}

describe('sendMessage conversation promotion', () => {
  beforeEach(() => {
    mocks.sendStream.mockReset();
    mocks.buildChatHistory.mockReset();
    mocks.readStream.mockReset();
    mocks.processImageAttachments.mockReset();
    mocks.resolveCatalogModel.mockReset();
    mocks.lookupPricing.mockReset();

    mocks.buildChatHistory.mockResolvedValue([{ role: 'user', content: 'What changed?' }]);
    mocks.sendStream.mockReturnValue({ stream: {} as ReadableStream, abort: vi.fn() });
    mocks.readStream.mockResolvedValue({
      fullText: 'Final answer',
      reasoningText: '',
      usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
      imageAttachments: [],
      servedModelID: 'gpt-4.1',
    });
    mocks.processImageAttachments.mockResolvedValue({
      finalText: 'Final answer',
      processedAttachments: [],
    });
    mocks.lookupPricing.mockReturnValue({
      promptPerToken: 0.001,
      completionPerToken: 0.002,
    });
  });

  it('promotes a folder draft to a normal conversation after the first send', async () => {
    const provider = makeProvider();
    const model = makeModel();
    const conversation = makeConversation({
      id: 'conv-folder-draft',
      title: '',
      previewText: '',
      isDraft: true,
      folderID: 'folder-1',
    });
    const store = createAppStore({
      providers: [provider],
      preferences: {
        theme: 'system',
        language: 'system',
        sendShortcut: 'enter',
      },
      conversations: [conversation],
    });

    const handle = sendMessage(
      {
        store,
        appendChunk: vi.fn(),
        te: (key) => key,
      },
      {
        text: 'Hello from folder draft',
        prevMessages: [],
        conversation,
        provider,
        model,
        reasoningMode: 'automatic',
      },
    );

    await handle.done;

    const updated = store.getState().conversations.find((item) => item.id === 'conv-folder-draft');
    expect(updated?.isDraft).toBe(false);
    expect(updated?.folderID).toBe('folder-1');
    expect(updated?.messages).toHaveLength(2);
  });
});
