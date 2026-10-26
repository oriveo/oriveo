// @vitest-environment jsdom
//
// An official connection upstream rejects media by signature (fixture rejection-signatures.v1.json).
// Runs the whole real chain retryMessage -> runChatOutbound -> sendStream -> proxy-client -> readStream, replacing only the network (fetch returns the fixture
// response) and external side effects; asserts the negative cache v2 entry, the next projection and outbound image stripping.

import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

vi.mock('../../chat/send-completion', () => ({ reportSendCompletion: vi.fn(), reportUsageAndBudget: vi.fn() }));
vi.mock('../../sync', () => ({ getSyncAdapter: () => undefined, deleteAttachments: vi.fn() }));
vi.mock('../../usage/usage-reporter', () => ({ enqueueUsageEvent: vi.fn(async () => undefined) }));
vi.mock('../../usage/budget-check', () => ({ checkBudgetExceeded: vi.fn() }));
vi.mock('../../skills/knowledge-api', () => ({ retrieveKnowledgeSnippets: vi.fn() }));
vi.mock('@sentry/nextjs', () => ({ captureException: vi.fn() }));

import { createAppStore } from '../../store/app-store';
import { retryMessage } from '../../chat/operations';
import { INPUT_NEGATIVE_CACHE_STORAGE_KEY } from '../input-negative-cache';
import { resolveInputCapabilityProjections } from '../truth/input-truth-adapter';

interface FixtureCase {
  id: string;
  protocol: string;
  wireFamily?: string;
  response: { status: number; body: unknown };
  expect: { signatureId: string | null };
}

const fixtureCases: FixtureCase[] = (() => {
  let dir = process.cwd();
  for (let depth = 0; depth < 8; depth += 1) {
    const candidate = path.join(dir, 'shared', 'test-fixtures', 'capability', 'rejection-signatures.v1.json');
    if (existsSync(candidate)) return (JSON.parse(readFileSync(candidate, 'utf8')) as { cases: FixtureCase[] }).cases;
    dir = path.dirname(dir);
  }
  throw new Error('rejection-signatures.v1.json not found');
})();
const fixture = (id: string) => fixtureCases.find((item) => item.id === id)!;

const IMAGE_B64 = 'iVBORw0KGgoREJECTEDIMAGE';

// A model on an official DashScope connection: vision ruling unknown / catalog_silent, going through Chat Completions (openai_chat.image_url).
const model: AIModel = {
  id: 'ZHIPU/GLM-5.3', name: 'GLM-5.3', capabilities: ['text'], transport: 'openai_chat_completions',
  reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '$',
  capabilityControls: {
    vision_input: { state: 'unknown', reasonCode: 'catalog_silent', wireFamily: 'openai_chat.image_url' },
  },
} as unknown as AIModel;

const provider: Provider = {
  id: 'official-qwen', kind: 'qwen', status: { kind: 'connected' }, models: [model], catalogModels: [model],
  apiKey: 'sk-test', apiKeyPreview: '••test', authMode: 'apiKey',
} as Provider;

function turn(): Conversation {
  const base = {
    providerID: provider.id, providerKind: provider.kind, providerName: 'Qwen',
    modelID: model.id, modelName: model.name, estimatedCost: 0,
  };
  const user: ChatMessage = {
    ...base, id: 'm-user', role: 'user', text: 'What is in this picture?', state: 'delivered',
    attachments: [{ id: 'img-1', kind: 'image', fileName: 'cat.png', mimeType: 'image/png', base64Data: IMAGE_B64 }],
  };
  const failed: ChatMessage = { ...base, id: 'm-assistant', role: 'assistant', text: '', state: 'failed' };
  return {
    id: 'conv-reject', title: 'Chat', hasCustomTitle: false, providerID: provider.id, providerKind: provider.kind,
    modelID: model.id, previewText: '', estimatedCost: 0, isDraft: false, messages: [user, failed], draftText: '',
    createdAt: '2026-10-19T00:00:00.000Z', updatedAt: '2026-10-19T00:00:00.000Z',
  };
}

const requestBodies: string[] = [];
let respond: () => Response;

beforeEach(() => {
  localStorage.clear();
  requestBodies.length = 0;
  vi.stubGlobal('fetch', vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    // Only the chat stream returns the fixture; side requests such as metadata always get 404 (unrelated to these assertions).
    if (!String(input).endsWith('/api/chat/stream')) return new Response('not found', { status: 404 });
    requestBodies.push(typeof init?.body === 'string' ? init.body : '');
    return respond();
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

function respondWith(item: FixtureCase): void {
  respond = () => new Response(JSON.stringify(item.response.body), {
    status: item.response.status, headers: { 'Content-Type': 'application/json' },
  });
}

async function retry(conversation: Conversation, store: ReturnType<typeof createAppStore>) {
  const handle = retryMessage(
    { store, appendChunk: vi.fn(), te: (key: string) => key },
    {
      messageId: 'm-assistant', conversation, messages: conversation.messages, provider, model,
      reasoningMode: 'automatic',
    },
  );
  await handle?.done;
  return store.getState().conversations.find((item) => item.id === conversation.id)!;
}

describe('official connection upstream rejects images by signature', () => {
  it('signature hit: records negative cache v2, next projection is rejected_recently, resend no longer carries the image', async () => {
    const item = fixture('dashscope_text_model_gets_image');
    expect(item.expect.signatureId).toBe('dashscope.unexpected_item_type');
    const conversation = turn();
    const store = createAppStore({ providers: [provider], conversations: [conversation] });
    expect(resolveInputCapabilityProjections(provider, model, undefined)?.vision_input.disabledReason).toBeNull();

    respondWith(item);
    const after = await retry(conversation, store);
    expect(requestBodies.some((body) => body.includes(IMAGE_B64))).toBe(true);
    // No silent retry: sent only once, and the failure is persisted as usual.
    expect(requestBodies).toHaveLength(1);
    expect(after.messages.at(-1)).toMatchObject({ role: 'assistant', state: 'failed' });
    // The hit result lands on the failed message (the one-tap action on the failure card reads only it).
    expect(after.messages.at(-1)?.inputRejection).toEqual({
      capabilityKey: 'vision_input', signatureId: 'dashscope.unexpected_item_type',
    });

    const stored = JSON.parse(localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY) ?? 'null') as {
      version: number; entries: Array<Record<string, unknown>>;
    };
    expect(stored.version).toBe(2);
    expect(stored.entries).toEqual([expect.objectContaining({
      connectionId: provider.id,
      modelId: model.id,
      wireFamily: 'openai_chat.image_url',
      capabilityKey: 'vision_input',
      signatureId: 'dashscope.unexpected_item_type',
    })]);

    expect(resolveInputCapabilityProjections(provider, model, undefined)?.vision_input).toMatchObject({
      editable: false, outbound: 'placeholder', disabledReason: 'disabled.rejected_recently',
    });

    // The user tapping "resend without images" = sending the same turn again: outbound already strips images per the projection.
    requestBodies.length = 0;
    await retry(after, store);
    expect(requestBodies).toHaveLength(1);
    expect(requestBodies[0]).not.toContain(IMAGE_B64);
  });

  it.each(['generic_400_not_matched', 'candidate_text_is_not_a_signature', 'status_mismatch_not_matched'])(
    'no signature hit (%s): no negative cache, projection unchanged',
    async (id) => {
      const item = fixture(id);
      expect(item.expect.signatureId).toBeNull();
      const conversation = turn();
      const store = createAppStore({ providers: [provider], conversations: [conversation] });
      respondWith(item);
      const after = await retry(conversation, store);
      expect(requestBodies.some((body) => body.includes(IMAGE_B64))).toBe(true);
      expect(after.messages.at(-1)).toMatchObject({ state: 'failed' });
      expect(localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY)).toBeNull();
      expect(resolveInputCapabilityProjections(provider, model, undefined)?.vision_input.disabledReason).toBeNull();
    },
  );
});

describe('official connection upstream rejects parameters by signature', () => {
  // Official Anthropic connection: thinking.type.enabled is rejected (fixture anthropic_thinking_enabled_rejected).
  const claude: AIModel = {
    id: 'claude-fable-5', name: 'Claude Fable 5', capabilities: ['text'], transport: 'anthropic_messages',
    reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '$$',
  } as unknown as AIModel;
  const anthropic: Provider = {
    id: 'official-anthropic', kind: 'anthropic', status: { kind: 'connected' }, models: [claude], catalogModels: [claude],
    apiKey: 'sk-test', apiKeyPreview: '••test', authMode: 'apiKey',
  } as Provider;

  function textTurn(): Conversation {
    const base = {
      providerID: anthropic.id, providerKind: anthropic.kind, providerName: 'Anthropic',
      modelID: claude.id, modelName: claude.name, estimatedCost: 0,
    };
    const user: ChatMessage = { ...base, id: 'm-user', role: 'user', text: 'Think about it.', state: 'delivered' };
    const failed: ChatMessage = { ...base, id: 'm-assistant', role: 'assistant', text: '', state: 'failed' };
    return {
      id: 'conv-param-reject', title: 'Chat', hasCustomTitle: false, providerID: anthropic.id,
      providerKind: anthropic.kind, modelID: claude.id, previewText: '', estimatedCost: 0, isDraft: false,
      messages: [user, failed], draftText: '',
      createdAt: '2026-10-19T00:00:00.000Z', updatedAt: '2026-10-19T00:00:00.000Z',
    };
  }

  it('Anthropic thinking parameter signature hit: records param:thinking, no resend, no media rejection', async () => {
    const item = fixture('anthropic_thinking_enabled_rejected');
    expect(item.expect.signatureId).toBe('anthropic.thinking_type_not_supported');
    const conversation = textTurn();
    const store = createAppStore({ providers: [anthropic], conversations: [conversation] });
    respondWith(item);

    const handle = retryMessage(
      { store, appendChunk: vi.fn(), te: (key: string) => key },
      {
        messageId: 'm-assistant', conversation, messages: conversation.messages, provider: anthropic, model: claude,
        reasoningMode: 'automatic',
      },
    );
    await handle?.done;
    const after = store.getState().conversations.find((entry) => entry.id === conversation.id)!;

    expect(requestBodies).toHaveLength(1);
    expect(after.messages.at(-1)).toMatchObject({ role: 'assistant', state: 'failed' });
    const stored = JSON.parse(localStorage.getItem(INPUT_NEGATIVE_CACHE_STORAGE_KEY) ?? 'null') as {
      version: number; entries: Array<Record<string, unknown>>;
    };
    expect(stored.version).toBe(2);
    expect(stored.entries).toEqual([expect.objectContaining({
      connectionId: anthropic.id,
      modelId: claude.id,
      wireFamily: 'anthropic_messages',
      capabilityKey: 'param:thinking',
      signatureId: 'anthropic.thinking_type_not_supported',
    })]);
  });
  it('after the Anthropic thinking signature is rejected once: the next request body of the same model has no thinking, and the failed attempt is not resent', async () => {
    const item = fixture('anthropic_thinking_enabled_rejected');
    const conversation = textTurn();
    const store = createAppStore({ providers: [anthropic], conversations: [conversation] });
    respondWith(item);
    const send = async () => {
      const current = store.getState().conversations.find((entry) => entry.id === conversation.id)!;
      const handle = retryMessage(
        { store, appendChunk: vi.fn(), te: (key: string) => key },
        {
          messageId: current.messages.at(-1)!.id, conversation: current, messages: current.messages,
          provider: anthropic, model: claude, reasoningMode: 'deep',
        },
      );
      await handle?.done;
    };
    const optionsOf = (raw: string) => (JSON.parse(raw) as { options?: Record<string, unknown> }).options ?? {};

    await send();
    expect(requestBodies).toHaveLength(1);
    expect(optionsOf(requestBodies[0]!)).toMatchObject({ reasoning: 'deep' });

    await send();
    expect(requestBodies).toHaveLength(2);
    const next = optionsOf(requestBodies[1]!);
    expect(next).not.toHaveProperty('reasoning');
    expect((next.capabilityPreferences as Record<string, unknown> | undefined)?.reasoningIntent).toBeUndefined();
  });
});
