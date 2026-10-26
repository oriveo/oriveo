// Conversation writes at the start of a send: sending in a conversation that is already bound to a model never rewrites modelID / providerID.
import { describe, expect, it, vi } from 'vitest';
import type { StoreApi } from 'zustand';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import type { AppStore } from '../../store/app-store';
import { prepareSendStart } from '../send-start';

const provider = {
  id: 'deepseek-1',
  kind: 'deepSeek',
  status: { kind: 'connected' },
  models: [],
  catalogModels: [],
  apiKey: 'sk-test',
  apiKeyPreview: 'sk-...test',
} as unknown as Provider;

function makeModel(id: string, canonicalModelId?: string): AIModel {
  return {
    id,
    name: id,
    canonicalModelId,
    capabilities: ['text'],
    reasoningModeAvailable: false,
    isAvailable: true,
    isDefault: false,
    priceTier: '$',
  };
}

function makeMessage(id: string, role: 'user' | 'assistant'): ChatMessage {
  return { id, role, text: role === 'user' ? 'Hello' : '', state: role === 'user' ? 'delivered' : 'generating' } as unknown as ChatMessage;
}

function makeStore(conversation: Conversation) {
  const state = {
    conversations: [conversation],
    updateConversation: vi.fn((id: string, patch: Partial<Conversation>) => {
      state.conversations = state.conversations.map((c) => (c.id === id ? { ...c, ...patch } : c));
    }),
    beginStreamingForConversation: vi.fn(),
    setLastUsedModelRef: vi.fn(),
  };
  const store = { getState: () => state } as unknown as StoreApi<AppStore>;
  return { store, state };
}

function runSend(conversation: Conversation, model: AIModel, attemptKind?: 'send' | 'retry' | 'regenerate' | 'edit' | 'continue') {
  const { store, state } = makeStore(conversation);
  prepareSendStart({
    store,
    userMsg: makeMessage('user-2', 'user'),
    assistantMsg: makeMessage('assistant-2', 'assistant'),
    prevMessages: conversation.messages,
    conversation,
    provider,
    model,
    reasoningMode: 'automatic',
    webSearchEnabled: false,
    attachments: undefined,
    skillId: undefined,
    attemptKind,
  });
  const patch = state.updateConversation.mock.calls[0]?.[1] as Partial<Conversation>;
  return { patch, stored: state.conversations[0], setLastUsedModelRef: state.setLastUsedModelRef };
}

function makeConversation(modelID: string): Conversation {
  return {
    id: 'conversation-1',
    title: 'Chat',
    providerID: 'deepseek-1',
    providerKind: 'deepSeek',
    modelID,
    messages: [makeMessage('user-1', 'user'), { ...makeMessage('assistant-1', 'assistant'), state: 'delivered' }],
    createdAt: '2026-10-01T00:00:00.000Z',
    updatedAt: '2026-10-01T00:00:00.000Z',
  } as unknown as Conversation;
}

describe('prepareSendStart conversation model writes', () => {
  it('existing conversation with a non-empty model: sending with another model does not write modelID / providerID', () => {
    const { patch, stored } = runSend(makeConversation('deepseek-old'), makeModel('deepseek-flash'));

    expect(patch).not.toHaveProperty('modelID');
    expect(patch).not.toHaveProperty('providerID');
    expect(stored.modelID).toBe('deepseek-old');
    expect(stored.providerID).toBe('deepseek-1');
    expect(stored.messages.map((m) => m.id)).toEqual(['user-1', 'assistant-1', 'user-2', 'assistant-2']);
  });

  it('existing conversation stores a dated alias while the send uses the canonical id: the conversation keeps the alias', () => {
    const { patch, stored } = runSend(makeConversation('gpt-4o-2024-08-06'), makeModel('gpt-4o', 'gpt-4o'));

    expect(patch).not.toHaveProperty('modelID');
    expect(patch).not.toHaveProperty('providerID');
    expect(stored.modelID).toBe('gpt-4o-2024-08-06');
  });

  it('existing conversation with an empty model: the model and connection used for this send are written in', () => {
    const { patch, stored } = runSend(makeConversation(''), makeModel('deepseek-flash'));

    expect(patch).toMatchObject({ modelID: 'deepseek-flash', providerID: 'deepseek-1', providerKind: 'deepSeek' });
    expect(stored.modelID).toBe('deepseek-flash');
  });
});

describe('prepareSendStart last used', () => {
  it('sending in an existing conversation also writes last used: the connection and model actually used for this send', () => {
    const { setLastUsedModelRef, stored } = runSend(makeConversation('deepseek-old'), makeModel('deepseek-flash'));

    expect(setLastUsedModelRef).toHaveBeenCalledTimes(1);
    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'deepseek-1', modelID: 'deepseek-flash' });
    // Writing last used does not change the conversation binding
    expect(stored.modelID).toBe('deepseek-old');
  });

  it.each(['retry', 'regenerate', 'continue'] as const)('%s is not a send: last used is not written and the messages still enter the conversation as usual', (attemptKind) => {
    const { setLastUsedModelRef, stored } = runSend(makeConversation('deepseek-old'), makeModel('deepseek-flash'), attemptKind);

    expect(setLastUsedModelRef).not.toHaveBeenCalled();
    expect(stored.messages.map((m) => m.id)).toEqual(['user-1', 'assistant-1', 'user-2', 'assistant-2']);
  });

  it('resending after an edit still counts as a send: last used is written', () => {
    const { setLastUsedModelRef } = runSend(makeConversation('deepseek-old'), makeModel('deepseek-flash'), 'edit');

    expect(setLastUsedModelRef).toHaveBeenCalledWith({ providerID: 'deepseek-1', modelID: 'deepseek-flash' });
  });
});
