// @vitest-environment jsdom
/**
 * Chat send path for image generation: a send decideChatImageDispatch puts on the studio
 * pipeline goes through runChatImageStudio and lands as chat image attachments; everything
 * else keeps the legacy chat/stream path. Runs the real sendMessage -> runChatOutbound ->
 * runner chain; only the wire (sendStream / runStudioByokRound), the metadata slice, the
 * image store writes and the thumbnail generator are faked.
 */
import 'fake-indexeddb/auto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamEvent } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  round: vi.fn(),
  slice: null as unknown,
  store: null as unknown,
  saved: [] as Array<{ id: string; mime: string; hasThumbnail: boolean }>,
  thumbBytes: new Uint8Array([7, 8, 9, 10]),
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn(), addBreadcrumb: vi.fn(), withScope: vi.fn() }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('../../studio/byok-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../studio/byok-client')>()),
  runStudioByokRound: (...args: unknown[]) => mocks.round(...args),
}));
vi.mock('../../metadata/metadata-client', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../metadata/metadata-client')>()),
  getImageMetadataSlice: () => mocks.slice,
  // The model's legacy imageGen profile dispatches to the prompt-only images endpoint.
  getImageGenRoute: (profile: string | null | undefined) => (profile === 'openai_image_gen'
    ? 'images_api'
    : profile === 'openai_chat_image_gen' ? 'chat_api' : null),
  resolveCatalogModel: () => ({
    pricingStatus: 'priced',
    pricingUnit: 'per_image',
    currencyCode: 'USD',
    pricingV2: { currencyCode: 'USD', unit: 'per_image', perUnit: 0.04 },
  }),
}));
vi.mock('../../../infra/storage/image-store', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../../infra/storage/image-store')>()),
  generateThumbnail: async () => new Blob([mocks.thumbBytes], { type: 'image/jpeg' }),
  saveImage: async (id: string, _image: Blob, thumbnail: Blob | null, mime: string) => {
    mocks.saved.push({ id, mime, hasThumbnail: thumbnail !== null });
  },
}));

import { createAppStore } from '../../store/app-store';
import { sendMessage } from '../operations';
import { setActiveUID } from '../../../infra/storage/partition';

const ROOT = resolve(__dirname, '../../../../../../..');
// Shared contracts directory name, spelled by code point to keep this file ASCII.
const SHARED = resolve(ROOT, 'shared');
const fixture = JSON.parse(readFileSync(resolve(SHARED, 'studio-contracts/chat_image_dispatch.v1.json'), 'utf8')) as {
  profiles: Record<string, Record<string, unknown>>;
};
const decodeCases = (JSON.parse(readFileSync(resolve(SHARED, 'model-contracts/image_response_samples.v1/index.json'), 'utf8')) as {
  decodeCases: Array<{ name: string; b64: string }>;
}).decodeCases;
const IMAGE_B64 = decodeCases.find((c) => c.name === 'png_rgba_3x2')!.b64;
const IMAGE_BYTES = Uint8Array.from(atob(IMAGE_B64), (c) => c.charCodeAt(0));
const THUMB_B64 = btoa(String.fromCharCode(...mocks.thumbBytes));

const PROFILE_REF = 'openai_images_square';
const MODEL_ID = 'gpt-image-1';
const USER_TEXT = '  a cat in the snow  ';
const IMAGE_PROMPT = 'a cat in the snow';

const imageModel = {
  id: MODEL_ID, name: MODEL_ID, capabilities: ['text', 'imageGeneration'], imageGenProfile: 'openai_image_gen',
  reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;
const officialProvider = {
  id: 'p-openai', kind: 'openAI', status: { kind: 'connected' }, models: [imageModel], catalogModels: [],
  apiKey: 'sk-test', apiKeyPreview: '••', baseURLText: 'https://api.openai.com/v1',
} as unknown as Provider;
const relayProvider = {
  id: 'relay-image', kind: 'relay', status: { kind: 'connected' }, models: [imageModel], catalogModels: [], apiKey: 'sk-relay',
  apiKeyPreview: '••', baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;

/** Metadata slice; withProfile false is a legacyOnly model (no v2 imageProfile). */
function sliceOf(providerKind: string, withProfile: boolean) {
  return {
    profiles: { image: { [PROFILE_REF]: fixture.profiles[PROFILE_REF] } },
    providers: { [providerKind]: { models: { [MODEL_ID]: withProfile ? { imageProfile: PROFILE_REF } : {} } } },
  };
}

function legacyImageStream(): { stream: ReadableStream<StreamEvent>; abort: () => void } {
  return {
    stream: new ReadableStream<StreamEvent>({
      start(controller) {
        controller.enqueue({ type: 'image', url: `data:image/png;base64,${IMAGE_B64}` } as StreamEvent);
        controller.enqueue({ type: 'usage', usage: { prompt_tokens: 12, completion_tokens: 34, total_tokens: 46 } } as StreamEvent);
        controller.enqueue({ type: 'done' } as StreamEvent);
        controller.close();
      },
    }),
    abort: () => undefined,
  };
}

/** Legacy stream that stays open until the send aborts it. */
function hangingLegacyStream(): { stream: ReadableStream<StreamEvent>; abort: () => void } {
  let close: () => void = () => undefined;
  const stream = new ReadableStream<StreamEvent>({
    start(controller) {
      close = () => {
        try { controller.close(); } catch { /* already closed */ }
      };
    },
  });
  return { stream, abort: () => close() };
}

function roundResult(status: 'completed' | 'cancelled') {
  const delivered = status === 'completed';
  return {
    status,
    errorKind: null,
    message: null,
    mayBeBilled: delivered,
    retried: false,
    nRequested: 1,
    delivered: delivered ? 1 : 0,
    composedPrompt: delivered ? IMAGE_PROMPT : null,
    adjustments: { prompt: [], params: [] },
    usage: delivered ? { inputTokens: 12, outputTokens: 34, totalTokens: 46 } : null,
    images: delivered
      ? [{ data: IMAGE_BYTES, mime: 'image/png', width: 3, height: 2, revisedPrompt: null }]
      : [],
  };
}

function makeConversation(provider: Provider): Conversation {
  return {
    id: 'conv-img', title: 'T', hasCustomTitle: false, providerID: provider.id, providerKind: provider.kind, modelID: MODEL_ID,
    previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '',
    createdAt: '2026-11-03T00:00:00.000Z', updatedAt: '2026-11-03T00:00:00.000Z',
  } as Conversation;
}

function startImageSend(provider: Provider, model: AIModel = imageModel) {
  const conversation = makeConversation(provider);
  const store = createAppStore({ providers: [provider], conversations: [conversation] });
  mocks.store = store;
  const handle = sendMessage({ store, appendChunk: vi.fn(), te: (key: string) => key }, {
    text: USER_TEXT, prevMessages: [], conversation, provider, model, reasoningMode: 'automatic',
  });
  const assistant = (): ChatMessage => store.getState().conversations.find((c) => c.id === conversation.id)!
    .messages.find((m) => m.role === 'assistant')!;
  return { handle, assistant };
}

async function sendImageTurn(provider: Provider, model: AIModel = imageModel): Promise<ChatMessage> {
  const send = startImageSend(provider, model);
  await send.handle.done;
  return send.assistant();
}

/** What a chat image reply persists, compared between the legacy and the studio path. */
function persistedShape(message: ChatMessage) {
  return {
    state: message.state,
    text: message.text,
    stopReason: message.stopReason,
    errorTitle: message.errorTitle,
    estimatedCost: message.estimatedCost,
    costSource: message.costSource,
    inputTokens: message.inputTokens,
    outputTokens: message.outputTokens,
    attachments: (message.attachments ?? []).map((attachment) => ({
      kind: attachment.kind,
      fileName: attachment.fileName,
      mimeType: attachment.mimeType,
      hasLocalImage: typeof attachment.localImageID === 'string' && attachment.localImageID !== '',
      thumbnailBase64: attachment.thumbnailBase64,
      base64Data: attachment.base64Data,
    })),
  };
}

beforeEach(async () => {
  mocks.sendStream.mockReset().mockImplementation(() => legacyImageStream());
  mocks.round.mockReset().mockImplementation(async () => roundResult('completed'));
  mocks.saved.length = 0;
  mocks.slice = null;
  await setActiveUID('guest');
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe('chat send path for studio image generation', () => {
  it('persistsLikeLegacy', async () => {
    mocks.slice = sliceOf('openAI', false);
    const legacy = await sendImageTurn(officialProvider);
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(mocks.round).not.toHaveBeenCalled();
    const legacySaved = mocks.saved.splice(0);

    mocks.sendStream.mockClear();
    mocks.slice = sliceOf('openAI', true);
    const studio = await sendImageTurn(officialProvider);
    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(mocks.round).toHaveBeenCalledTimes(1);
    const roundInput = mocks.round.mock.calls[0]![0] as {
      providerKind: string; modelId: string; apiKey: string; baseURL: string; operation: string; prompt: { userPrompt: string };
    };
    expect(roundInput.baseURL).toBe('https://api.openai.com/v1');
    expect(roundInput.providerKind).toBe('openAI');
    expect(roundInput.modelId).toBe(MODEL_ID);
    expect(roundInput.apiKey).toBe('sk-test');
    expect(roundInput.operation).toBe('generate');
    // Same prompt string the legacy path sends (plan.imagePrompt).
    expect(roundInput.prompt.userPrompt).toBe(IMAGE_PROMPT);

    expect(persistedShape(legacy).state).toBe('delivered');
    expect(persistedShape(legacy).attachments).toHaveLength(1);
    expect(persistedShape(legacy).estimatedCost).toBeCloseTo(0.04, 10);
    expect(persistedShape(studio)).toEqual(persistedShape(legacy));
    expect(studio.attachments![0]!.thumbnailBase64).toBe(THUMB_B64);
    // The stored image id is the attachment's localImageID and is written with its thumbnail.
    expect(mocks.saved).toEqual([{ id: studio.attachments![0]!.localImageID, mime: 'image/png', hasThumbnail: true }]);
    expect(legacySaved).toEqual([{ id: legacy.attachments![0]!.localImageID, mime: 'image/png', hasThumbnail: true }]);
  });

  it('legacyOnlyStaysLegacy', async () => {
    // legacyOnly model (no v2 imageProfile): legacy images path.
    mocks.slice = sliceOf('openAI', false);
    const legacyOnly = await sendImageTurn(officialProvider);
    expect(mocks.round).not.toHaveBeenCalled();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(legacyOnly.state).toBe('delivered');
    expect(legacyOnly.attachments).toHaveLength(1);

    // Relay keeps chat/stream even when the model resolves a profile.
    mocks.sendStream.mockClear();
    mocks.slice = sliceOf('relay', true);
    const relay = await sendImageTurn(relayProvider);
    expect(mocks.round).not.toHaveBeenCalled();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(relay.state).toBe('delivered');

    // Conversational image generation (chat_api route) is a chat request, not the studio pipeline.
    mocks.sendStream.mockClear();
    mocks.slice = sliceOf('openAI', true);
    const conversational = await sendImageTurn(officialProvider, { ...imageModel, imageGenProfile: 'openai_chat_image_gen' } as AIModel);
    expect(mocks.round).not.toHaveBeenCalled();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(conversational.state).toBe('delivered');
  });

  it('missingBaseURLStaysLegacy', async () => {
    // No base URL can be resolved for the connection: the studio request cannot be built, so legacy runs.
    mocks.slice = sliceOf('openAI', true);
    const noBaseURL = { ...officialProvider, baseURLText: undefined } as Provider;
    const message = await sendImageTurn(noBaseURL);
    expect(mocks.round).not.toHaveBeenCalled();
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(message.state).toBe('delivered');
    expect(message.attachments).toHaveLength(1);
  });

  it('dashscopeConnectionUsesNativeApiV1', async () => {
    // A DashScope connection stores the compatible-mode address; the studio request goes to the native /api/v1 root.
    const qwenModel = { ...imageModel, id: 'qwen-image', name: 'qwen-image' } as AIModel;
    const qwenProvider = {
      ...officialProvider, id: 'p-qwen', kind: 'qwen', models: [qwenModel], apiKey: 'sk-qwen',
      baseURLText: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
    } as unknown as Provider;
    mocks.slice = {
      profiles: { image: { dashscope_square: fixture.profiles.dashscope_square } },
      providers: { qwen: { models: { 'qwen-image': { imageProfile: 'dashscope_square' } } } },
    };
    await sendImageTurn(qwenProvider, qwenModel);
    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(mocks.round).toHaveBeenCalledTimes(1);
    const roundInput = mocks.round.mock.calls[0]![0] as { providerKind: string; baseURL: string };
    expect(roundInput.providerKind).toBe('qwen');
    expect(roundInput.baseURL).toBe('https://dashscope-intl.aliyuncs.com/api/v1');
  });

  it('cancelLeavesNoAttachments', async () => {
    // Legacy cancel: the stream is aborted before any image arrives.
    mocks.slice = sliceOf('openAI', false);
    mocks.sendStream.mockImplementation(() => hangingLegacyStream());
    const legacySend = startImageSend(officialProvider);
    await vi.waitFor(() => expect(mocks.sendStream).toHaveBeenCalledTimes(1));
    legacySend.handle.abort();
    await legacySend.handle.done;
    const legacy = legacySend.assistant();

    // Studio cancel: the stop aborts the signal the runner hands to the round.
    mocks.sendStream.mockClear();
    mocks.slice = sliceOf('openAI', true);
    mocks.round.mockImplementation((_input: unknown, options: { signal?: AbortSignal }) => new Promise((resolveRound) => {
      options.signal?.addEventListener('abort', () => resolveRound(roundResult('cancelled')), { once: true });
    }));
    const studioSend = startImageSend(officialProvider);
    await vi.waitFor(() => expect(mocks.round).toHaveBeenCalledTimes(1));
    studioSend.handle.abort();
    await studioSend.handle.done;
    const studio = studioSend.assistant();

    expect(mocks.sendStream).not.toHaveBeenCalled();
    expect(studio.attachments).toBeUndefined();
    expect(mocks.saved).toEqual([]);
    expect(studio.state).not.toBe('failed');
    expect(studio.stopReason).toBe('interrupted');
    expect(persistedShape(studio)).toEqual(persistedShape(legacy));
  });
});
