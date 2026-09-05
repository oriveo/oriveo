// @vitest-environment jsdom
//
// Signature of the options parameter on flushPartialToMessage / stopStream, plus the chat-tuning
// constants. Behaviour is verified against a real createAppStore (state, text and reasoning
// concatenation) to pin the options API down.

import { describe, expect, it } from 'vitest';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import { createAppStore } from '../../store/app-store';
import { flushPartialToMessage } from '../partial-flush';
import { stopStream } from '../stop-stream';
import { PARTIAL_FLUSH_THRESHOLD_CHARS, PARTIAL_FLUSH_THRESHOLD_MS } from '../chat-tuning';

const MSG_ID = 'assistant-1';

function makeGeneratingConversation(): Conversation {
  const assistant: ChatMessage = {
    id: MSG_ID,
    role: 'assistant',
    text: '',
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'gpt-4o',
    estimatedCost: 0,
    state: 'generating',
  };
  return {
    id: 'conv-1',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: 'p-1',
    providerKind: 'openAI',
    modelID: 'gpt-4o',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [
      { id: 'user-1', role: 'user', text: 'hi', providerKind: 'openAI', providerName: 'OpenAI', modelName: 'gpt-4o', estimatedCost: 0, state: 'delivered' },
      assistant,
    ],
    draftText: '',
    createdAt: '2026-04-12T00:00:00.000Z',
    updatedAt: '2026-04-12T00:00:00.000Z',
  };
}

describe('chat-tuning constants', () => {
  it('keeps the partial flush thresholds in chat-tuning at fixed values', () => {
    expect(PARTIAL_FLUSH_THRESHOLD_CHARS).toBe(4000);
    expect(PARTIAL_FLUSH_THRESHOLD_MS).toBe(60_000);
  });
});

describe('flushPartialToMessage options signature', () => {
  it('{ state: "interrupted" } syncs the partial text and marks the message interrupted', () => {
    const store = createAppStore({ conversations: [makeGeneratingConversation()] });
    store.getState().beginStreamingForConversation('conv-1', MSG_ID);
    store.getState().appendStreamingText('conv-1', 'streamed partial');

    flushPartialToMessage(store, 'conv-1', MSG_ID, { state: 'interrupted' });

    const msg = store.getState().conversations[0].messages.find((m) => m.id === MSG_ID);
    expect(msg?.text).toBe('streamed partial');
    expect(msg?.state).toBe('interrupted');
  });

  it('without a state, syncs the text but stays generating', () => {
    const store = createAppStore({ conversations: [makeGeneratingConversation()] });
    store.getState().beginStreamingForConversation('conv-1', MSG_ID);
    store.getState().appendStreamingText('conv-1', 'lifecycle flush');

    flushPartialToMessage(store, 'conv-1', MSG_ID, {});

    const msg = store.getState().conversations[0].messages.find((m) => m.id === MSG_ID);
    expect(msg?.text).toBe('lifecycle flush');
    expect(msg?.state).toBe('generating');
  });

  it('{ prevReasoning } concatenates with this round of reasoning partials', () => {
    const store = createAppStore({ conversations: [makeGeneratingConversation()] });
    store.getState().beginStreamingForConversation('conv-1', MSG_ID);
    store.getState().appendStreamingReasoningText('conv-1', 'new thinking');

    flushPartialToMessage(store, 'conv-1', MSG_ID, { state: 'interrupted', prevReasoning: 'old thinking' });

    const msg = store.getState().conversations[0].messages.find((m) => m.id === MSG_ID);
    expect(msg?.reasoningText).toBe('old thinking\n\nnew thinking');
  });
});

describe('stopStream options signature', () => {
  it('options { streamStartedAt, initialReasoning } marks the last generating assistant message interrupted and concatenates the reasoning', () => {
    const conv = makeGeneratingConversation();
    const store = createAppStore({ conversations: [conv] });
    store.getState().beginStreamingForConversation('conv-1', MSG_ID);
    store.getState().appendStreamingReasoningText('conv-1', 'newR');

    stopStream(store, conv, conv.messages, 'partial answer', null, {
      streamStartedAt: 1000,
      initialReasoning: 'prevR',
    });

    const msg = store.getState().conversations[0].messages.find((m) => m.id === MSG_ID);
    expect(msg?.state).toBe('interrupted');
    expect(msg?.text).toBe('partial answer');
    expect(msg?.reasoningText).toBe('prevR\n\nnewR');
  });

  it('options { msgId } targets the message bound to the session instead of hitting the last one', () => {
    const base = makeGeneratingConversation();
    // Another generating assistant message follows (a cross-session or concurrent case); stopping must not touch it.
    const later: ChatMessage = { ...base.messages[1], id: 'assistant-2' };
    const messages = [...base.messages, later];
    const conv: Conversation = { ...base, messages };
    const store = createAppStore({ conversations: [conv] });

    stopStream(store, conv, messages, 'partial answer', null, { msgId: MSG_ID });

    const stored = store.getState().conversations[0].messages;
    expect(stored.find((m) => m.id === MSG_ID)?.state).toBe('interrupted');
    expect(stored.find((m) => m.id === MSG_ID)?.text).toBe('partial answer');
    expect(stored.find((m) => m.id === 'assistant-2')?.state).toBe('generating');
  });

  it('with options omitted, defaults to streamStartedAt=null and still marks the message interrupted', () => {
    const conv = makeGeneratingConversation();
    const store = createAppStore({ conversations: [conv] });

    stopStream(store, conv, conv.messages, 'short', null);

    const msg = store.getState().conversations[0].messages.find((m) => m.id === MSG_ID);
    expect(msg?.state).toBe('interrupted');
    expect(msg?.text).toBe('short');
  });
});
