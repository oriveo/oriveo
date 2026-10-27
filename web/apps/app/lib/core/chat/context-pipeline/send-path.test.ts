import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Main chat path projection: send / retry / regenerate / send after edit all converge on operations-send.sendMessage,
 * and the request body is produced by ContextAssembler.assemble. The assertions are on the request body the production Relay orchestration layer actually sent through transport.fetch,
 * without mocking buildChatHistory / prompt assembly.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, Attachment, ChatMessage, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';
import { CONTEXT_ASSEMBLE_CONSTANTS, ContextAssembler } from '@oriveo/core/context/assemble';
import { UNANSWERED_ENVELOPE_NOTE } from '@oriveo/core/context/sanitize';
import { MemoryItems, type MemoryItem, type MemoryItemInput } from '@oriveo/core/context/memory-items';
import { searchedRecordLine } from '@oriveo/core/search/search-turn';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  /** When on, the vision gate runs the production implementation (vision_gate_* cases). */
  realImageGate: false,
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
// The fixture has no relay capability evidence identity (local identity + metadata ETag), so the production vision gate would strip the images as "no evidence";
// images are let through on the same basis as purposes.test, measuring only the plan projection and the outbound request.
vi.mock('../attachment-policy', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../attachment-policy')>();
  return {
    ...actual,
    withoutUnreceivableImages: (...args: Parameters<typeof actual.withoutUnreceivableImages>) =>
      (mocks.realImageGate ? actual.withoutUnreceivableImages(...args) : args[0]),
    filterCurrentTurnAttachments: <T,>(messages: T[]) => messages,
  };
});
// Outbound history construction reads the same image-recognition projection (only native_part produces image parts): let it through together with the images, and use the real projection when measuring the real gate.
vi.mock('../../capability/truth/input-truth-adapter', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../capability/truth/input-truth-adapter')>();
  const { projectInputCapability } = await import('@oriveo/core/providers/capability-evidence-facade');
  const native = (key: 'vision_input' | 'file_input' | 'video_input') => projectInputCapability({
    key, verdict: { state: 'auto_available' }, endImplements: true, override: null, negativeCacheHit: false, connection: 'official',
  });
  return {
    ...actual,
    resolveInputCapabilityProjections: (...args: Parameters<typeof actual.resolveInputCapabilityProjections>) =>
      (mocks.realImageGate
        ? actual.resolveInputCapabilityProjections(...args)
        : { vision_input: native('vision_input'), file_input: native('file_input'), video_input: native('video_input') }),
  };
});

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore } from '../../store/app-store';
import { __resetMetadataClientForTest } from '../../metadata/metadata-client';
import { editAndResend, retryMessage, sendMessage } from '../operations';
import { batchAppendStreaming } from '../stream-batcher';
import { AttachmentInjector } from '../../attachments/attachment-injector';
import {
  beginCapabilityEvidenceIdentityIfAbsent,
  resetCapabilityEvidenceIdentitiesForTesting,
} from '../../providers/capability-evidence-identity';
import { getActiveUIDSync } from '../../../infra/storage/partition';

const provider = {
  id: 'relay-ctx', kind: 'relay', status: { kind: 'connected' }, models: [], catalogModels: [], apiKey: 'sk-relay', apiKeyPreview: '••',
  baseURLText: 'https://relay.example/v1',
  relayRequested: { transport: 'openai_chat_completions', resolvedAPIBaseURL: 'https://relay.example/v1' },
  relayResolvedTransport: 'openai_chat_completions', relayResolvedAuthMode: 'bearer',
} as unknown as Provider;
const model = {
  id: 'ctx-model', name: 'ctx-model', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
} as AIModel;

const MEMORY = 'I prefer green tea';
const NOTE = { id: 'note-1', title: 'Trip', body: 'Kyoto in May' };

interface WireMessage { role: string; content: string | Array<{ type: string; text?: string }> }
const sentBodies: Array<{ messages: WireMessage[] }> = [];
let respond: () => Response;
const ok = () => new Response(['data: {"choices":[{"delta":{"content":"ok"}}]}', 'data: [DONE]'].map((f) => `${f}\n\n`).join(''), {
  status: 200, headers: { 'Content-Type': 'text/event-stream' },
});
const fail = () => new Response(JSON.stringify({ error: { message: 'upstream boom' } }), {
  status: 500, headers: { 'Content-Type': 'application/json' },
});

/** Local memory entries (injection reads store.memoryItems, no longer memoryText). */
function memoryItem(id: string, content: string, extra: Partial<MemoryItemInput> = {}): MemoryItem {
  return MemoryItems.canonical({
    id, kind: 'fact', content, mutationId: `${id}-m`, deviceId: 'device-test', createdAt: '2026-10-01T00:00:00.000Z', ...extra,
  });
}

function newStore(options: { useMemory?: boolean; messages?: ChatMessage[]; memoryItems?: MemoryItem[]; memoryText?: string } = {}) {
  const conv = {
    id: 'conv-ctx', title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: 'relay', previewText: '', estimatedCost: 0,
    isDraft: false, messages: options.messages ?? [], draftText: '', updatedAt: '2026-10-15T00:00:00.000Z', createdAt: '2026-10-15T00:00:00.000Z',
    pinnedNoteIds: [NOTE.id],
    ...(options.useMemory === undefined ? {} : { useMemory: options.useMemory }),
  };
  const store = createAppStore({ providers: [provider], conversations: [conv as never] });
  store.setState({
    preferences: { ...store.getState().preferences, memoryText: options.memoryText ?? MEMORY },
    notes: [{ ...NOTE, titleSource: 'manual', tags: [] } as never],
    memoryItems: options.memoryItems ?? [memoryItem('memory', MEMORY)],
  });
  mocks.store = store;
  return store;
}
const ctxOf = (store: ReturnType<typeof createAppStore>) => ({
  store, appendChunk: (chunk: string) => batchAppendStreaming('conv-ctx', chunk), te: (key: string) => key,
});
const conversationOf = (store: ReturnType<typeof createAppStore>) => store.getState().conversations[0];
const lastBody = () => sentBodies[sentBodies.length - 1];

async function send(store: ReturnType<typeof createAppStore>, text: string, extra: { attachments?: Attachment[]; prevMessages?: ChatMessage[]; model?: AIModel } = {}) {
  const conv = conversationOf(store);
  await sendMessage(ctxOf(store), {
    text, prevMessages: extra.prevMessages ?? conv.messages, conversation: conv, provider, model: extra.model ?? model, reasoningMode: 'automatic',
    ...(extra.attachments ? { attachments: extra.attachments } : {}),
  }).done;
}

/** The system the assembler produces directly from the same input: the request body's system must equal it verbatim. */
function expectedSystem(useMemory: boolean): string | null {
  return ContextAssembler.assemble({
    purpose: 'chat',
    window: { W: null, windowKind: 'total', maxOutput: {} },
    conversation: { id: 'conv-ctx', useMemory, pinnedNotes: [{ title: NOTE.title, text: NOTE.body }] },
    memoryItems: [{ id: 'memory', kind: 'fact', content: MEMORY }],
    history: [],
    current: 'hello',
  }).system;
}

function textOf(message: WireMessage): string {
  return typeof message.content === 'string'
    ? message.content
    : message.content.filter((part) => part.type === 'text').map((part) => part.text ?? '').join('');
}

function expectSystemFromPlan(body: { messages: WireMessage[] }) {
  const system = expectedSystem(true);
  expect(system).toContain('<oriveo-memory>');
  expect(body.messages[0]).toEqual({ role: 'system', content: system });
  expect(body.messages.filter((m) => m.role === 'system')).toHaveLength(1);
  expect(JSON.stringify(body)).not.toContain('[Pinned Notes');
}

beforeEach(() => {
  localStorage.clear();
  sentBodies.length = 0;
  respond = ok;
  __resetMetadataClientForTest();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL, options, {
      transport: {
        fetch: async (_url, init) => {
          sentBodies.push(JSON.parse(String(init.body)) as { messages: WireMessage[] });
          return respond();
        },
      },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
});

afterEach(() => {
  __resetMetadataClientForTest();
  resetCapabilityEvidenceIdentitiesForTesting();
  localStorage.clear();
});

describe('context pipeline send path', () => {
  it('send_body_system_from_plan', async () => {
    const store = newStore();
    await send(store, 'hello');
    const body = lastBody();
    expectSystemFromPlan(body);
    expect(body.messages[0].content).toContain(`<entry title="${NOTE.title}">${NOTE.body}</entry>`);
    expect(body.messages[body.messages.length - 1]).toEqual({ role: 'user', content: 'hello' });
  });

  it('send_body_dynamic_block_last', async () => {
    const store = newStore();
    const file: Attachment = { id: 'file-1', kind: 'file', fileName: 'draft.txt', mimeType: 'text/plain', base64Data: 'draft body' } as Attachment;
    await send(store, 'read this', { attachments: [file] });
    const body = lastBody();
    const guide = `<oriveo-attachment-guide>\n${AttachmentInjector.SYSTEM_PROMPT_GUIDANCE}\n</oriveo-attachment-guide>`;
    expect(body.messages[0].role).toBe('system');
    expect(textOf(body.messages[0])).not.toContain(AttachmentInjector.SYSTEM_PROMPT_GUIDANCE);
    const last = body.messages[body.messages.length - 1];
    expect(last.role).toBe('user');
    expect(textOf(last)).toContain('read this');
    expect(textOf(last).endsWith(`\n\n${guide}`)).toBe(true);
  });

  it('transport_input_carries_plan_system_and_dynamic', async () => {
    const store = newStore();
    const file: Attachment = { id: 'file-1', kind: 'file', fileName: 'draft.txt', mimeType: 'text/plain', base64Data: 'draft body' } as Attachment;
    await send(store, 'read this', { attachments: [file] });
    // The arguments the production path hands to sendStream: first system == plan.system, StreamOptions.dynamicText == the [D] text.
    const call = mocks.sendStream.mock.calls[mocks.sendStream.mock.calls.length - 1];
    const messages = call[3] as WireMessage[];
    const options = call[5] as StreamOptions;
    expect(messages[0]).toEqual({ role: 'system', content: expectedSystem(true) });
    expect(messages.filter((m) => m.role === 'system')).toHaveLength(1);
    const guide = `<oriveo-attachment-guide>\n${AttachmentInjector.SYSTEM_PROMPT_GUIDANCE}\n</oriveo-attachment-guide>`;
    expect(options.dynamicText).toBe(guide);
    expect(textOf(messages[messages.length - 1]).endsWith(`\n\n${guide}`)).toBe(true);
  });

  it('image_only_message_reaches_wire', async () => {
    const store = newStore();
    const image: Attachment = { id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
    await send(store, '', { attachments: [image], model: { ...model, capabilities: ['text', 'image'] } as AIModel });
    // Empty body with only images: the last message sendStream receives is still a user message carrying the images.
    const call = mocks.sendStream.mock.calls[mocks.sendStream.mock.calls.length - 1];
    const messages = call[3] as WireMessage[];
    const last = messages[messages.length - 1];
    expect(last.role).toBe('user');
    expect(Array.isArray(last.content) && last.content.some((part) => part.type === 'image_url')).toBe(true);
    const body = lastBody();
    expect(body.messages[body.messages.length - 1].role).toBe('user');
  });

  it('vision_gate_unknown_sends_real_image', async () => {
    const store = newStore();
    const image: Attachment = { id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
    // Production vision gate: for a Relay with a registered local connection identity, unknown image recognition (no negative evidence, no negative cache) sends the real image.
    beginCapabilityEvidenceIdentityIfAbsent(getActiveUIDSync(), provider.id);
    mocks.realImageGate = true;
    try {
      await send(store, '', { attachments: [image] });
    } finally {
      mocks.realImageGate = false;
    }
    const call = mocks.sendStream.mock.calls[mocks.sendStream.mock.calls.length - 1];
    const messages = call[3] as WireMessage[];
    const last = messages[messages.length - 1];
    expect(last.role).toBe('user');
    expect(Array.isArray(last.content) && last.content.some((part) => part.type === 'image_url')).toBe(true);
    expect(textOf(last)).not.toContain('[Image omitted');
    expect(JSON.stringify(lastBody())).toContain('iVBORw0KGgo=');
  });

  it('vision_gate_image_only_keeps_placeholder', async () => {
    const store = newStore();
    const image: Attachment = { id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
    // Production vision gate: the fixture has no relay capability evidence identity (fail-closed), so the image is stripped; the relay Chat route declares no placeholder, so the generic placeholder is used.
    // With an identity, the user overriding image recognition to off is stripped the same way.
    const noVision = { ...model, relayCapabilityOverrides: { image: { value: false, source: 'user' } } } as AIModel;
    mocks.realImageGate = true;
    try {
      await send(store, '', { attachments: [image], model: noVision });
    } finally {
      mocks.realImageGate = false;
    }
    const call = mocks.sendStream.mock.calls[mocks.sendStream.mock.calls.length - 1];
    const messages = call[3] as WireMessage[];
    const last = messages[messages.length - 1];
    expect(last.role).toBe('user');
    expect(Array.isArray(last.content) && last.content.some((part) => part.type === 'image_url')).toBe(false);
    expect(textOf(last)).toContain('[Image omitted: this route sends text only]');
    const body = lastBody();
    const wireLast = body.messages[body.messages.length - 1];
    expect(wireLast.role).toBe('user');
    expect(textOf(wireLast)).toContain('[Image omitted: this route sends text only]');
    expect(JSON.stringify(body)).not.toContain('iVBORw0KGgo=');
  });

  it('empty_body_with_attachment_dynamic_is_d_only', async () => {
    const store = newStore();
    const image: Attachment = { id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' } as Attachment;
    await send(store, '', { attachments: [image], model: { ...model, capabilities: ['text', 'image'] } as AIModel });
    const call = mocks.sendStream.mock.calls[mocks.sendStream.mock.calls.length - 1];
    const messages = call[3] as WireMessage[];
    const options = call[5] as StreamOptions;
    const guide = `<oriveo-attachment-guide>\n${AttachmentInjector.SYSTEM_PROMPT_GUIDANCE}\n</oriveo-attachment-guide>`;
    expect(options.dynamicText).toBe(guide);
    // When the body is empty the current user's text is just [D] itself, with no leading newline.
    const last = messages[messages.length - 1];
    expect(last.role).toBe('user');
    expect(textOf(last)).toBe(guide);
    const body = lastBody();
    expect(textOf(body.messages[body.messages.length - 1])).toBe(guide);
  });

  it('send_body_memory_switch_off', async () => {
    const store = newStore({ useMemory: false });
    await send(store, 'hello');
    const body = lastBody();
    const system = expectedSystem(false);
    expect(system).not.toContain(MEMORY);
    expect(body.messages[0]).toEqual({ role: 'system', content: system });
    expect(JSON.stringify(body)).not.toContain(MEMORY);
  });

  it('memory_items_injected_and_recorded', async () => {
    const standing = memoryItem('item-standing', 'Always answer in English.', { kind: 'instruction', pinned: true });
    const fact = memoryItem('item-fact', 'Lives in Berlin.');
    const scoped = memoryItem('item-scoped', 'Planning a Kyoto trip.', { scope: { type: 'conversation', id: 'conv-ctx' } });
    const otherConversation = memoryItem('item-other', 'Other chat only.', { scope: { type: 'conversation', id: 'conv-other' } });
    const folder = memoryItem('item-folder', 'Folder only.', { scope: { type: 'folder', id: 'folder-1' } });
    const paused = memoryItem('item-paused', 'Paused memory.', { status: 'paused' });
    const expired = memoryItem('item-expired', 'Expired memory.', { expiresAt: '2026-01-01T00:00:00.000Z' });
    const store = newStore({
      memoryItems: [fact, standing, scoped, otherConversation, folder, paused, expired],
      memoryText: 'Legacy memory text',
    });
    await send(store, 'hello');

    const body = lastBody();
    const system = ContextAssembler.assemble({
      purpose: 'chat',
      window: { W: null, windowKind: 'total', maxOutput: {} },
      conversation: { id: 'conv-ctx', useMemory: true, pinnedNotes: [{ title: NOTE.title, text: NOTE.body }] },
      memoryItems: [
        { id: standing.id, kind: 'instruction', content: standing.content, pinned: true },
        { id: fact.id, kind: 'fact', content: fact.content },
        { id: scoped.id, kind: 'fact', content: scoped.content },
      ],
      history: [],
      current: 'hello',
    }).system;
    expect(system).toContain('<oriveo-standing-instructions>');
    expect(body.messages[0]).toEqual({ role: 'system', content: system });
    const wire = JSON.stringify(body);
    for (const absent of ['Legacy memory text', 'Other chat only.', 'Folder only.', 'Paused memory.', 'Expired memory.']) {
      expect(wire).not.toContain(absent);
    }
    // What lands on this assistant message is the memoryIds of the final plan: the standing conventions first, the other memories after.
    const assistant = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(assistant).toMatchObject({ state: 'delivered', memoryItemIds: [standing.id, fact.id, scoped.id] });
    // Stored locally only: the user message does not carry it.
    const user = conversationOf(store).messages.find((m) => m.role === 'user') as ChatMessage;
    expect('memoryItemIds' in user).toBe(false);
  });

  it('memory_recall_episodic_in_dynamic', async () => {
    const episodic = memoryItem('item-l3', 'Migrated the billing database to Postgres last sprint', {
      layer: 'episodic', kind: 'event', occurredAt: '2026-10-01T00:00:00Z',
    });
    const store = newStore({ memoryItems: [episodic] });
    await send(store, 'When did we migrate the billing database to Postgres?');
    const users = lastBody().messages.filter((m) => m.role === 'user');
    const lastUser = JSON.stringify(users[users.length - 1].content);
    expect(lastUser).toContain('<oriveo-recall>');
    expect(lastUser).toContain('date=\\"2026-10-01\\"');
    expect(lastUser).toContain('Migrated the billing database to Postgres last sprint');
    const assistant = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(assistant.memoryItemIds).toContain(episodic.id);
  });

  it('memory_switch_off_no_items', async () => {
    const store = newStore({ useMemory: false, memoryItems: [memoryItem('item-fact', 'Lives in Berlin.')] });
    await send(store, 'hello');
    expect(JSON.stringify(lastBody())).not.toContain('Lives in Berlin.');
    const assistant = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(assistant.state).toBe('delivered');
    // An empty array writes no field.
    expect('memoryItemIds' in assistant).toBe(false);
  });

  it('send_body_unanswered_merged', async () => {
    const earlier: ChatMessage = {
      id: 'user-earlier', role: 'user', text: 'first question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z',
    } as ChatMessage;
    const store = newStore({ messages: [earlier] });
    await send(store, 'second question', { prevMessages: [earlier] });
    const body = lastBody();
    const users = body.messages.filter((m) => m.role === 'user');
    expect(users).toHaveLength(1);
    expect(users[0].content).toBe(
      `<oriveo-unanswered>\n<note>${UNANSWERED_ENVELOPE_NOTE}</note>\nfirst question\n</oriveo-unanswered>\n\nsecond question`,
    );
    expectSystemFromPlan(body);
  });

  it('history_search_record_without_body_has_no_leading_blank', async () => {
    const citations = [
      { url: 'https://a.example/', title: 'A', snippet: 'a', source: 'external_search', query: 'q1', index: 1 },
    ] as ChatMessage['citations'];
    const history: ChatMessage[] = [
      { id: 'u1', role: 'user', text: 'first question', state: 'delivered', createdAt: '2026-10-15T00:00:01.000Z' } as ChatMessage,
      { id: 'a1', role: 'assistant', text: '', state: 'delivered', citations, createdAt: '2026-10-15T00:00:02.000Z' } as ChatMessage,
      { id: 'u2', role: 'user', text: 'second question', state: 'delivered', createdAt: '2026-10-15T00:00:03.000Z' } as ChatMessage,
      { id: 'a2', role: 'assistant', text: 'answer two', state: 'delivered', citations, createdAt: '2026-10-15T00:00:04.000Z' } as ChatMessage,
    ];
    const store = newStore({ messages: history });
    await send(store, 'third question', { prevMessages: history });
    const record = searchedRecordLine([{ source: 'external_search', query: 'q1', title: 'A', url: 'https://a.example/' }]);
    const assistants = lastBody().messages.filter((m) => m.role === 'assistant').map(textOf);
    expect(assistants).toEqual([record, `answer two\n\n${record}`]);
  });

  it('retry_body_from_plan', async () => {
    const store = newStore();
    respond = fail;
    await send(store, 'hello');
    const failed = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(failed.state).toBe('failed');
    respond = ok;
    const conv = conversationOf(store);
    await retryMessage(ctxOf(store), {
      messageId: failed.id, conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
    })!.done;
    const body = lastBody();
    expectSystemFromPlan(body);
    expect(body.messages.slice(1)).toEqual([{ role: 'user', content: 'hello' }]);
  });

  it('regenerate_body_from_plan', async () => {
    const store = newStore();
    await send(store, 'hello');
    const delivered = conversationOf(store).messages.find((m) => m.role === 'assistant') as ChatMessage;
    expect(delivered.state).toBe('delivered');
    const conv = conversationOf(store);
    await retryMessage(ctxOf(store), {
      messageId: delivered.id, conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
    })!.done;
    const body = lastBody();
    expectSystemFromPlan(body);
    expect(body.messages.slice(1)).toEqual([{ role: 'user', content: 'hello' }]);
  });

  it('edit_resend_body_from_plan', async () => {
    const store = newStore();
    await send(store, 'hello');
    const user = conversationOf(store).messages.find((m) => m.role === 'user') as ChatMessage;
    const conv = conversationOf(store);
    await editAndResend(ctxOf(store), {
      messageId: user.id, newText: 'hello again', conversation: conv, messages: conv.messages, provider, model, reasoningMode: 'automatic',
    })!.done;
    const body = lastBody();
    expectSystemFromPlan(body);
    expect(body.messages.slice(1)).toEqual([{ role: 'user', content: 'hello again' }]);
  });
});
