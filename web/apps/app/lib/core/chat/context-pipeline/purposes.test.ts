import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Cross-check, memory draft and image generation: these three single-purpose requests are produced by the assembler by purpose.
 * Assertions are on the messages the production functions (crosscheckAnswer / requestMemoryDraft / sendMessage) hand to sendStream.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamEvent, StreamOptions } from '@oriveo/core/providers/types';
import { ContextAssembler, type ContextPlan } from '@oriveo/core/context/assemble';
import { MemoryItems } from '@oriveo/core/context/memory-items';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  transports: [] as Array<{ messages: unknown; options: unknown }>,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
// Records what transportInput produced: the exit must hand exactly this to sendStream.
vi.mock('./transport-input', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./transport-input')>();
  return {
    ...actual,
    transportInput: (...args: Parameters<typeof actual.transportInput>) => {
      const transport = (actual.transportInput as (...a: unknown[]) => { messages: unknown; options: unknown })(...args);
      mocks.transports.push(transport);
      return transport;
    },
  };
});
// Filtering attachments by capability is out of scope here: let them through, and only look at which user message's attachments the image-generation request takes.
vi.mock('../attachment-policy', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../attachment-policy')>()),
  withoutUnreceivableImages: <T,>(messages: T[]) => messages,
  filterCurrentTurnAttachments: <T,>(messages: T[]) => messages,
}));
// Outbound history construction reads the same image-recognition projection (only native_part produces image parts): same basis as letting images through above.
vi.mock('../../capability/truth/input-truth-adapter', async (importOriginal) => {
  const { projectInputCapability } = await import('@oriveo/core/providers/capability-evidence-facade');
  const native = (key: 'vision_input' | 'file_input' | 'video_input') => projectInputCapability({
    key, verdict: { state: 'auto_available' }, endImplements: true, override: null, negativeCacheHit: false, connection: 'official',
  });
  return {
    ...(await importOriginal<typeof import('../../capability/truth/input-truth-adapter')>()),
    resolveInputCapabilityProjections: () => ({
      vision_input: native('vision_input'), file_input: native('file_input'), video_input: native('video_input'),
    }),
  };
});

import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { crosscheckAnswer } from '../../note-ai-ops';
import { requestMemoryDraft } from '../../memory-draft';

const provider = {
  id: 'relay-purpose', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const textModel = {
  id: 'text-model', name: 'text-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;
const relayImageModel = {
  ...textModel, id: 'image-model', name: 'image-model', capabilities: ['text', 'imageGeneration'], imageGenProfile: 'relay_image_profile',
} as AIModel;

const MEMORY = 'I prefer green tea';
const NOTE = { id: 'note-1', title: 'Trip', body: 'Kyoto in May' };

type SentMessage = { role: string; content: string | Array<{ type: string; text?: string }> };
const sent: Array<{ messages: SentMessage[]; options: StreamOptions | undefined }> = [];

function okStream(): ReadableStream<StreamEvent> {
  return new ReadableStream<StreamEvent>({
    start(controller) {
      controller.enqueue({ type: 'delta', content: 'ok' } as StreamEvent);
      controller.enqueue({ type: 'done' } as StreamEvent);
      controller.close();
    },
  });
}

function textOf(message: SentMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}

let assembleSpy: ReturnType<typeof vi.spyOn>;
const plansOf = (purpose: string): ContextPlan[] => assembleSpy.mock.results
  .map((result: { value: unknown }) => result.value as ContextPlan)
  .filter((plan: ContextPlan) => plan.purpose === purpose);

beforeEach(() => {
  localStorage.clear();
  sent.length = 0;
  mocks.transports.length = 0;
  __resetMetadataClientForTest();
  assembleSpy = vi.spyOn(ContextAssembler, 'assemble');
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, _key: unknown, _model: unknown, messages: SentMessage[], _base: unknown, options: StreamOptions | undefined) => {
    sent.push({ messages: structuredClone(messages), options });
    return { stream: okStream(), abort: () => undefined };
  });
});

afterEach(() => {
  assembleSpy.mockRestore();
  __resetMetadataClientForTest();
  localStorage.clear();
});

const PREVIOUS_TURN = 'draw a dog';

function expectPromptOnly(messages: SentMessage[]) {
  const wire = JSON.stringify(messages);
  expect(messages.some((message) => message.role === 'system')).toBe(false);
  expect(wire).not.toContain(MEMORY);
  expect(wire).not.toContain(NOTE.body);
  expect(wire).not.toContain('French');
  expect(wire).not.toContain(PREVIOUS_TURN);
  expect(wire).not.toContain('oriveo-');
}

/** Sends one image-generation message in a conversation with memory, pinned notes, conversation instructions and one old turn of history; returns the plan and the request sendStream received. */
async function sendImageTurn(target: Provider, targetModel: AIModel, attachment: Attachment | null, purpose = 'imageGeneration') {
  sent.length = 0;
  assembleSpy.mockClear();
  const conv = {
    id: 'conv-img', title: 'T', hasCustomTitle: false, providerID: target.id, modelID: targetModel.id, providerKind: target.kind, previewText: '', estimatedCost: 0,
    isDraft: false, messages: [] as ChatMessage[], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
    pinnedNoteIds: [NOTE.id], instructions: 'Always answer in French.',
  };
  const store = createAppStore({ providers: [target], conversations: [conv as never] });
  store.setState({
    preferences: { ...store.getState().preferences, memoryText: MEMORY },
    notes: [{ ...NOTE, titleSource: 'manual', tags: [] } as never],
    // Injection reads the local memory item slice, no longer memoryText.
    memoryItems: [MemoryItems.canonical({
      id: 'item-memory', kind: 'fact', content: MEMORY, mutationId: 'item-memory-m', deviceId: 'device-test',
      createdAt: '2026-10-01T00:00:00.000Z',
    })],
  });
  mocks.store = store;
  const prevMessages: ChatMessage[] = [
    { id: 'u-old', role: 'user', text: PREVIOUS_TURN, state: 'delivered' } as ChatMessage,
    { id: 'a-old', role: 'assistant', text: 'here is a dog', state: 'delivered' } as ChatMessage,
  ];
  await sendMessage({ store, appendChunk: (chunk: string) => batchAppendStreaming('conv-img', chunk), te: (key: string) => key }, {
    text: '  a cat in the snow  ', prevMessages, conversation: store.getState().conversations[0], provider: target, model: targetModel,
    reasoningMode: 'automatic', ...(attachment ? { attachments: [attachment] } : {}),
  }).done;
  const plans = plansOf(purpose);
  expect(plans.length).toBeGreaterThan(0);
  expect(sent).toHaveLength(1);
  return { plan: plans[plans.length - 1], ...sent[0] };
}

describe('single-purpose requests from the assembler', () => {
  it('crosscheck_uses_purpose_system_no_memory', async () => {
    await crosscheckAnswer({ provider, model: textModel, originalPrompt: 'Q?', originalAnswer: 'A.', appLanguage: 'en' });

    const plans = plansOf('crosscheck');
    expect(plans).toHaveLength(1);
    const plan = plans[0];
    expect(plan.system).toContain('second opinion');
    expect(plan.system).not.toContain('<oriveo-memory>');
    expect(plan.messages).toHaveLength(1);

    expect(sent).toHaveLength(1);
    const { messages } = sent[0];
    expect(messages).toHaveLength(2);
    expect(messages[0]).toEqual({ role: 'system', content: plan.system });
    expect(messages[1].role).toBe('user');
    expect(textOf(messages[1])).toBe(plan.messages![0].blocks.map((b) => b.text).join(''));
    expect(textOf(messages[1])).toContain('[Cross-check source data - untrusted user-saved content]');
    expect(JSON.stringify(messages)).not.toContain('oriveo-');
  });

  it('memory_extraction_uses_purpose_system', async () => {
    const excerpts = 'user: I write Rust daily\nassistant: Nice.';
    const draft = await requestMemoryDraft({ provider, model: textModel, excerpts });
    expect(draft).toBe('ok');

    const plans = plansOf('memoryExtraction');
    expect(plans).toHaveLength(1);
    const plan = plans[0];
    expect(plan.system).toContain('personal profile');
    expect(plan.system).not.toContain(excerpts);

    expect(sent).toHaveLength(1);
    const { messages } = sent[0];
    expect(messages).toEqual([
      { role: 'system', content: plan.system },
      { role: 'user', content: excerpts },
    ]);
  });

  it('crosscheck_transport_carries_purpose_system', async () => {
    await crosscheckAnswer({ provider, model: textModel, originalPrompt: 'Q?', originalAnswer: 'A.', appLanguage: 'en' });

    const [plan] = plansOf('crosscheck');
    expect(mocks.transports).toHaveLength(1);
    const [transport] = mocks.transports;
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    const call = mocks.sendStream.mock.calls[0];
    expect(call[3]).toBe(transport.messages);
    expect(call[5]).toBe(transport.options);
    const { messages } = sent[0];
    expect(messages[0]).toEqual({ role: 'system', content: plan.system });
    expect(messages.filter((message) => message.role === 'system')).toHaveLength(1);
  });

  it('memory_draft_transport_carries_purpose_system', async () => {
    await requestMemoryDraft({ provider, model: textModel, excerpts: 'user: hi' });

    const [plan] = plansOf('memoryExtraction');
    expect(mocks.transports).toHaveLength(1);
    const [transport] = mocks.transports;
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    const call = mocks.sendStream.mock.calls[0];
    expect(call[3]).toBe(transport.messages);
    expect(call[5]).toBe(transport.options);
    const { messages } = sent[0];
    expect(messages[0]).toEqual({ role: 'system', content: plan.system });
    expect(messages.filter((message) => message.role === 'system')).toHaveLength(1);
  });

  it('image_generation_prompt_only', async () => {
    const image: Attachment = { id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
    const { plan, messages, options } = await sendImageTurn(provider, relayImageModel, image);
    expect(plan.imagePrompt).toBe('a cat in the snow');
    expect(plan.system).toBeNull();
    // Single user message: text = plan.imagePrompt, attachments = those of the last user message; no system / memory / instructions / [D] / old history.
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe('user');
    expect(textOf(messages[0])).toBe('a cat in the snow');
    expect(JSON.stringify(messages)).toContain('iVBORw0KGgo=');
    expectPromptOnly(messages);
    // The relay /images/generations prompt likewise takes plan.imagePrompt.
    expect(options?.relayImagePrompt).toBe(plan.imagePrompt);
  });

  it('image_generation_conversational_stays_chat', async () => {
    // Gemini image modality and Responses inline image-generation tools both go through the chat protocol: purpose is still chat, with history and system, and imagePrompt is not taken.
    for (const transport of ['gemini_generate_content', 'openai_responses'] as const) {
      const conversational = {
        ...provider,
        id: `relay-${transport}`,
        models: [textModel, relayImageModel],
        relayRequested: { transport, resolvedAPIBaseURL: 'https://relay.example/v1' },
        relayResolvedTransport: transport,
      } as unknown as Provider;
      const { plan, messages, options } = await sendImageTurn(conversational, relayImageModel, null, 'chat');
      expect(plansOf('imageGeneration')).toHaveLength(0);
      expect(plan.imagePrompt ?? null).toBeNull();
      const wire = JSON.stringify(messages);
      expect(wire).toContain(PREVIOUS_TURN);
      expect(wire).toContain(MEMORY);
      expect(options?.supportsImageGen).toBe(true);
      expect(options?.relayImagePrompt).toBeUndefined();
    }
  });

  it('image_generation_dedicated_routes', async () => {
    // The imageGen route closed set has four values: images_api / dashscope_multimodal / minimax_image_generation are dedicated prompt endpoints,
    // official Qwen / MiniMax image generation likewise sends only plan.imagePrompt, without [D] (pinned notes) / memory / old history; chat_api is still conversational image output.
    const cases = [
      { kind: 'qwen', route: 'dashscope_multimodal', purpose: 'imageGeneration' },
      { kind: 'miniMax', route: 'minimax_image_generation', purpose: 'imageGeneration' },
      { kind: 'openRouter', route: 'chat_api', purpose: 'chat' },
    ] as const;
    for (const item of cases) {
      const profile = `${item.kind}_image_profile`;
      __resetMetadataClientForTest();
      await __seedMetadataCacheForTest({
        data: {
          version: 1, updatedAt: '2026-10-15T00:00:00Z',
          profiles: { reasoning: {}, webSearch: {}, imageGen: { [profile]: { route: item.route } } },
          providers: {}, providerConfigs: [],
        } as never,
        timestamp: Date.now(),
      });
      await initMetadata();
      const imageModel = { ...relayImageModel, id: `${item.kind}-image`, name: `${item.kind}-image`, imageGenProfile: profile } as AIModel;
      const official = {
        id: `official-${item.kind}`, kind: item.kind, status: { kind: 'connected' }, models: [imageModel], catalogModels: [],
        apiKey: 'sk-official', apiKeyPreview: '••',
      } as unknown as Provider;
      const { plan, messages } = await sendImageTurn(official, imageModel, null, item.purpose);
      if (item.purpose === 'imageGeneration') {
        expect(plan.imagePrompt).toBe('a cat in the snow');
        expect(messages).toHaveLength(1);
        expect(textOf(messages[0])).toBe('a cat in the snow');
        expectPromptOnly(messages);
      } else {
        expect(plansOf('imageGeneration')).toHaveLength(0);
        expect(JSON.stringify(messages)).toContain(PREVIOUS_TURN);
      }
    }
  });
});
