import 'fake-indexeddb/auto';
// @vitest-environment jsdom
/**
 * Confirmation gate (Web, main send path): after the pre-send compaction and before the transport, it suspends according to decideCapConfirm and waits for the user's decision;
 * confirm sends once, cancel = rollback (this message pair is deleted locally, no chat is sent, and done carries the refill payload).
 * Prices and the price line come from the production metadata decoder; B comes from the conversation tier; P̂ is the estimatedInput of the plan at the gate.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { StreamOptions } from '@oriveo/core/providers/types';

const mocks = vi.hoisted(() => ({
  sendStream: vi.fn(),
  store: null as unknown,
  syncAdapter: undefined as undefined | Record<string, ReturnType<typeof vi.fn>>,
  cleanupCloudAttachments: vi.fn(),
}));

vi.mock('../../../../providers/StoreProvider', () => ({ getVanillaStore: () => mocks.store, tryGetVanillaStore: () => mocks.store }));
vi.mock('../../providers/service', () => ({ sendStream: (...args: unknown[]) => mocks.sendStream(...args) }));
vi.mock('../cleanup-attachments', () => ({ cleanupCloudAttachments: (...args: unknown[]) => mocks.cleanupCloudAttachments(...args) }));
vi.mock('../../sync-port', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../../sync-port')>()),
  getSyncAdapter: () => mocks.syncAdapter ?? null,
}));
vi.mock('next/navigation', () => ({ useRouter: () => ({ back: vi.fn(), push: vi.fn(), replace: vi.fn() }) }));
vi.mock('next-intl', () => ({ useLocale: () => 'en', useTranslations: (namespace: string) => (key: string) => `${namespace}.${key}` }));
vi.mock('../stop-stream', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../stop-stream')>();
  return { ...actual, stopStream: vi.fn(actual.stopStream) };
});
vi.mock('../../telemetry', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../telemetry')>();
  return { ...actual, trackEvent: vi.fn(actual.trackEvent) };
});

import { sendRelayStream } from '@oriveo/core/providers/relay-orchestrator';
import { createAppStore, type AppStore } from '../../store/app-store';
import { __resetMetadataClientForTest, __seedMetadataCacheForTest, initMetadata } from '../../metadata/metadata-client';
import { editAndResend, retryMessage, sendMessage } from '../operations';
import { ContextCompactionStore } from '../context-compaction/context-compaction-store';
import { batchAppendStreaming } from '../stream-batcher';
import {
  type CapConfirmChoice,
  type CapConfirmRequest,
  resolveCapConfirmation,
} from '../context-visibility/cap-confirm-gate';
import { readCapConfirmState } from '../context-visibility/cap-confirm';
import { act, renderHook, waitFor } from '@testing-library/react';
import { stopStream } from '../stop-stream';
import { trackEvent } from '../../telemetry';
import { SEND_BLOCKED, useStreamChat } from '../../../hooks/useStreamChat';

const GROK_ID = 'grok-4.7';
// Price line 100000: in the over-tier cases P̂ is below the line (only the tier is asked); in the price-line cases P̂ is above it.
const PRICE_LINE = 100000;

async function seedMetadata() {
  const grokModels = {
    [GROK_ID]: {
      canonicalModelId: GROK_ID,
      contextLength: 2000000,
      pricingUnit: 'per_token',
      pricingStatus: 'priced',
      capabilities: ['text'],
      pricing: {
        promptPerMToken: 2,
        completionPerMToken: 6,
        longContext: { thresholdTokens: PRICE_LINE, promptPerMToken: 4, completionPerMToken: 12, cacheReadPerMToken: 1 },
      },
    },
  };
  await __seedMetadataCacheForTest({
    data: {
      version: 1, contractVersion: 1, updatedAt: '2026-10-17T00:00:00Z',
      profiles: { reasoning: {}, webSearch: {}, imageGen: {} },
      providers: { grok: { models: grokModels } },
      providerConfigs: [],
    } as never,
    timestamp: Date.now(),
  });
  await initMetadata();
}

const model = {
  id: GROK_ID, name: 'Grok 4.7', capabilities: ['text'], reasoningModeAvailable: false, isAvailable: true, isDefault: true, priceTier: '',
  transport: 'openai_chat_completions',
} as unknown as AIModel;
const provider = {
  id: 'grok-official', kind: 'grok', status: { kind: 'connected' }, models: [model], catalogModels: [], apiKey: 'sk-grok', apiKeyPreview: '••',
} as unknown as Provider;

const okOpenAIChat = () => new Response([
  'data: {"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}',
  'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
  'data: [DONE]',
].map((f) => `${f}\n\n`).join(''), { status: 200, headers: { 'Content-Type': 'text/event-stream' } });

let conversationId = 'conv-gate-0';
let conversationSeq = 0;

/** English body text of about `tokens` tokens (the estimate basis follows the plan at the gate; the cases separately assert which side P̂ falls on). */
function longText(tokens: number): string {
  return 'The quick brown fox jumps over the lazy dog. '.repeat(Math.ceil(tokens / 10));
}

function storeWith(extra: Partial<Conversation> = {}, messages: ChatMessage[] = []): StoreApi<AppStore> {
  const conversation = {
    id: conversationId, title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: provider.kind,
    previewText: '', estimatedCost: 0, isDraft: false, messages, draftText: '',
    updatedAt: '2026-10-17T00:00:00.000Z', createdAt: '2026-10-17T00:00:00.000Z',
    ...extra,
  } as Conversation;
  const store = createAppStore({ providers: [provider], conversations: [conversation] });
  mocks.store = store;
  return store;
}

function conversationOf(store: StoreApi<AppStore>): Conversation {
  return store.getState().conversations.find((c) => c.id === conversationId)!;
}

/** Records every request the gate pops up and answers it with `answer` (simulates the user clicking a button). */
function answerEveryConfirm(store: StoreApi<AppStore>, answer: CapConfirmChoice): CapConfirmRequest[] {
  const seen: CapConfirmRequest[] = [];
  store.subscribe((state, previous) => {
    for (const request of Object.values(state.contextCapConfirmations)) {
      if (Object.values(previous.contextCapConfirmations).includes(request)) continue;
      seen.push(request);
      queueMicrotask(() => resolveCapConfirmation(request.conversationId, answer));
    }
  });
  return seen;
}

function send(store: StoreApi<AppStore>, text: string) {
  const conversation = conversationOf(store);
  return sendMessage({
    store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
  }, { text, prevMessages: conversation.messages, conversation, provider, model, reasoningMode: 'automatic' });
}

function chatMessage(id: string, role: 'user' | 'assistant', text: string): ChatMessage {
  return {
    id, role, text, providerKind: 'grok', providerName: 'grok', modelName: GROK_ID, estimatedCost: 0, state: 'delivered',
    createdAt: '2026-10-17T00:00:00.000Z',
  } as unknown as ChatMessage;
}

beforeEach(async () => {
  conversationSeq += 1;
  conversationId = `conv-gate-${conversationSeq}`;
  localStorage.clear();
  __resetMetadataClientForTest();
  mocks.syncAdapter = undefined;
  mocks.cleanupCloudAttachments.mockReset();
  mocks.sendStream.mockReset().mockImplementation((_kind: unknown, apiKey: string, modelID: string, messages: never, baseURL: string | null, options: StreamOptions) =>
    sendRelayStream(apiKey, modelID, messages, baseURL ?? 'https://api.official.example/v1', options, {
      transport: { fetch: async () => okOpenAIChat() },
      buildFetchArgs: (url, headers) => ({ url, headers }),
      getRelayRuntimeConfig: () => null,
    }));
  await seedMetadata();
});

afterEach(() => {
  __resetMetadataClientForTest();
  localStorage.clear();
  vi.restoreAllMocks();
});

describe('context cap confirm gate (main send path)', () => {
  it('gate_over_cap_cancel_rolls_back', async () => {
    const store = storeWith({ contextCap: 32000 });
    const asked = answerEveryConfirm(store, { kind: 'cancel' });
    const text = longText(25000);
    const handle = send(store, text);
    const outcome = await handle.done;

    expect(asked).toHaveLength(1);
    expect(asked[0].decision.kind).toBe('overCap');
    expect(asked[0].B).toBe(32000);
    expect(asked[0].estimatedInput).toBeGreaterThan(32000);
    expect(asked[0].estimatedInput).toBeLessThan(PRICE_LINE);
    // No chat request; this message pair is not in the conversation; the conversation is kept
    expect(mocks.sendStream).not.toHaveBeenCalled();
    const conversation = conversationOf(store);
    expect(conversation).toBeDefined();
    expect(conversation.messages.find((m) => m.id === handle.msgId)).toBeUndefined();
    expect(conversation.messages).toEqual([]);
    // The refill payload contains the original text; the dialog and the streaming state are dismissed
    expect(outcome).toMatchObject({ rolledBack: { text } });
    expect(store.getState().contextCapConfirmations).toEqual({});
    expect(store.getState().streamingTexts[conversationId]).toBeUndefined();
    // Cancel writes no local state
    expect(readCapConfirmState(conversationId)).toEqual({ suppressed: false, acknowledged: null });
  });

  it('gate_over_cap_confirm_sends_once', async () => {
    const store = storeWith({ contextCap: 32000 });
    const asked = answerEveryConfirm(store, { kind: 'confirm', dontAsk: false });
    const handle = send(store, longText(25000));
    const outcome = await handle.done;

    expect(asked).toHaveLength(1);
    expect(asked[0].decision.kind).toBe('overCap');
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(outcome).toBeUndefined();
    const assistant = conversationOf(store).messages.find((m) => m.id === handle.msgId);
    expect(assistant).toMatchObject({ state: 'delivered', text: 'ok' });
    expect(store.getState().contextCapConfirmations).toEqual({});
  });

  it('gate_price_line_asks_once_per_conversation', async () => {
    const store = storeWith({ contextCap: 'unlimited' });
    const asked = answerEveryConfirm(store, { kind: 'confirm', dontAsk: false });
    await send(store, longText(110000)).done;

    expect(asked).toHaveLength(1);
    expect(asked[0].decision.kind).toBe('priceLine');
    expect(asked[0].decision.acknowledgeOnConfirm).toEqual({ model: GROK_ID, T: PRICE_LINE });
    expect(asked[0].priceLineTokens).toBe(PRICE_LINE);
    expect(asked[0].modelName).toBe('Grok 4.7');
    expect(readCapConfirmState(conversationId)).toEqual({ suppressed: false, acknowledged: { model: GROK_ID, T: PRICE_LINE } });

    // Second time with the same model and the same price line: no question, send as usual
    await send(store, 'follow-up question').done;
    expect(asked).toHaveLength(1);
    expect(mocks.sendStream).toHaveBeenCalledTimes(2);
  });

  it('gate_regenerate_skips_confirm', async () => {
    const big = longText(25000);
    const store = storeWith({ contextCap: 32000 }, [chatMessage('u1', 'user', big), chatMessage('a1', 'assistant', 'old answer')]);
    const asked = answerEveryConfirm(store, { kind: 'cancel' });
    const conversation = conversationOf(store);
    const handle = retryMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
    }, { messageId: 'a1', conversation, messages: conversation.messages, provider, model, reasoningMode: 'automatic' });
    expect(handle?.attemptKind).toBe('regenerate');
    await handle!.done;

    expect(asked).toEqual([]);
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
  });

  it('gate_reminder_off_skips_price_line', async () => {
    const store = storeWith({ contextCap: 'unlimited' });
    store.setState({ preferences: { ...store.getState().preferences, contextPriceLineReminderEnabled: false } });
    const asked = answerEveryConfirm(store, { kind: 'cancel' });
    const handle = send(store, longText(110000));
    await handle.done;

    expect(asked).toEqual([]);
    expect(mocks.sendStream).toHaveBeenCalledTimes(1);
    expect(conversationOf(store).messages.find((m) => m.id === handle.msgId)).toMatchObject({ state: 'delivered' });
  });

  it('gate_inputs_follow_plan_snapshot', async () => {
    // Tier is 32000 at send time: the plan is built with 32000; after the plan the user changes the tier to unlimited, and the gate still judges by the plan's B
    const store = storeWith({ contextCap: 32000 });
    const asked = answerEveryConfirm(store, { kind: 'cancel' });
    const handle = send(store, longText(25000));
    store.getState().updateConversation(conversationId, { contextCap: 'unlimited' });
    await handle.done;

    expect(asked).toHaveLength(1);
    expect(asked[0].decision.kind).toBe('overCap');
    expect(asked[0].B).toBe(32000);
    expect(asked[0].priceLineTokens).toBe(PRICE_LINE);
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  it('gate_pending_per_conversation', async () => {
    const conversationA = `${conversationId}-a`;
    const conversationB = `${conversationId}-b`;
    const base = {
      title: 'T', hasCustomTitle: false, providerID: provider.id, modelID: model.id, providerKind: provider.kind,
      previewText: '', estimatedCost: 0, isDraft: false, messages: [], draftText: '', contextCap: 32000,
      updatedAt: '2026-10-17T00:00:00.000Z', createdAt: '2026-10-17T00:00:00.000Z',
    };
    const store = createAppStore({
      providers: [provider],
      conversations: [{ ...base, id: conversationA }, { ...base, id: conversationB }] as Conversation[],
    });
    mocks.store = store;
    vi.mocked(stopStream).mockClear();
    vi.mocked(trackEvent).mockClear();
    const text = longText(25000);
    const find = (id: string) => store.getState().conversations.find((c) => c.id === id)!;

    // A is suspended and unanswered
    const handleA = sendMessage({
      store, appendChunk: (chunk: string) => batchAppendStreaming(conversationA, chunk), te: (key: string) => key,
    }, { text, prevMessages: [], conversation: find(conversationA), provider, model, reasoningMode: 'automatic' });
    await waitFor(() => expect(store.getState().contextCapConfirmations[conversationA]?.conversationId).toBe(conversationA), { timeout: 5000 });

    // B sends: B's own dialog pops up, A's is still pending
    const { result } = renderHook(() => useStreamChat({
      provider, currentModel: model, conversation: find(conversationB), messages: [], reasoningMode: 'automatic', onSendFailed: vi.fn(),
    }));
    let sendingB!: Promise<unknown>;
    act(() => {
      sendingB = result.current.send(text, [], find(conversationB));
    });
    await waitFor(() => expect(store.getState().contextCapConfirmations[conversationB]?.conversationId).toBe(conversationB), { timeout: 5000 });
    expect(store.getState().contextCapConfirmations[conversationA]?.conversationId).toBe(conversationA);

    // Stop on B: only B is cancelled (rolled back, not recorded as stopped), A is unaffected
    act(() => result.current.stop());
    await expect(sendingB).resolves.toBe(SEND_BLOCKED);
    expect(find(conversationB).messages).toEqual([]);
    expect(store.getState().contextCapConfirmations[conversationB]).toBeUndefined();
    expect(store.getState().contextCapConfirmations[conversationA]?.conversationId).toBe(conversationA);
    expect(find(conversationA).messages).toHaveLength(2);
    expect(vi.mocked(stopStream)).not.toHaveBeenCalled();
    expect(vi.mocked(trackEvent).mock.calls.some(([event]) => event === 'chat_message_stopped')).toBe(false);

    resolveCapConfirmation(conversationA, { kind: 'cancel' });
    await expect(handleA.done).resolves.toMatchObject({ rolledBack: { text } });
    expect(store.getState().contextCapConfirmations).toEqual({});
    expect(mocks.sendStream).not.toHaveBeenCalled();
  });

  describe('edit and resend', () => {
    // Edit the first message: the answer after it and the second round are both cut off (to feed the plan); remote deletion / checkpoint invalidation / cloud attachment cleanup are deferred until after confirmation.
    function editFirst(answer: CapConfirmChoice) {
      const store = storeWith({ contextCap: 32000 }, [
        chatMessage('u1', 'user', 'first question'), chatMessage('a1', 'assistant', 'first answer'),
        chatMessage('u2', 'user', 'second question'), chatMessage('a2', 'assistant', 'second answer'),
      ]);
      mocks.syncAdapter = {
        didDeleteMessages: vi.fn(), didCompleteRound: vi.fn(), didDeleteCheckpoints: vi.fn(), didSaveCheckpoint: vi.fn(),
        didUpdatePreferences: vi.fn(), didCompleteAssistantMessage: vi.fn(), didRegenerate: vi.fn(),
      };
      const invalidate = vi.spyOn(ContextCompactionStore, 'invalidateAndSync').mockResolvedValue(undefined);
      const asked = answerEveryConfirm(store, answer);
      const before = conversationOf(store).messages;
      const conversation = conversationOf(store);
      const handle = editAndResend({
        store, appendChunk: (chunk: string) => batchAppendStreaming(conversationId, chunk), te: (key: string) => key,
      }, { messageId: 'u1', newText: longText(25000), conversation, messages: conversation.messages, provider, model, reasoningMode: 'automatic' });
      return { store, asked, before, handle: handle!, invalidate };
    }

    it('gate_edit_cancel_keeps_original_tail', async () => {
      const { store, asked, before, handle, invalidate } = editFirst({ kind: 'cancel' });
      const outcome = await handle.done;

      expect(asked).toHaveLength(1);
      expect(asked[0].decision.kind).toBe('overCap');
      expect(outcome).toMatchObject({ rolledBack: { text: longText(25000) } });
      expect(mocks.sendStream).not.toHaveBeenCalled();
      // The conversation returns to its pre-edit state: the original messages and the answers after them are all present
      expect(conversationOf(store).messages).toEqual(before);
      expect(mocks.syncAdapter!.didDeleteMessages).not.toHaveBeenCalled();
      expect(invalidate).not.toHaveBeenCalled();
      expect(mocks.cleanupCloudAttachments).not.toHaveBeenCalled();
    });

    it('gate_edit_confirm_applies_tail_deletion', async () => {
      const { store, asked, handle, invalidate } = editFirst({ kind: 'confirm', dontAsk: false });
      await handle.done;

      expect(asked).toHaveLength(1);
      expect(mocks.sendStream).toHaveBeenCalledTimes(1);
      expect(mocks.syncAdapter!.didDeleteMessages).toHaveBeenCalledTimes(1);
      expect(mocks.syncAdapter!.didDeleteMessages).toHaveBeenCalledWith(['u1', 'a1', 'u2', 'a2'], conversationId, undefined);
      expect(invalidate).toHaveBeenCalledTimes(1);
      expect(mocks.cleanupCloudAttachments).toHaveBeenCalledTimes(1);
      const ids = conversationOf(store).messages.map((m) => m.id);
      expect(ids).toEqual([expect.any(String), handle.msgId]);
      expect(ids).not.toContain('u1');
    });
  });
});
