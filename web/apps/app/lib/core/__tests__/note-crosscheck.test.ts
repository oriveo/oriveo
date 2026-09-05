import { describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { createAppStore } from '../store/app-store';
import { createNoteFromCrosscheck } from '../note-ops';

vi.mock('../sync-port', () => ({
  getSyncAdapter: () => null,
}));

const originProvider: Provider = {
  id: 'provider-origin',
  kind: 'openAI',
  status: { kind: 'connected' },
  apiKey: 'sk-origin',
  apiKeyPreview: 'sk...origin',
  models: [],
  catalogModels: [],
};

const crosscheckProvider: Provider = {
  id: 'provider-crosscheck',
  kind: 'anthropic',
  status: { kind: 'connected' },
  apiKey: 'sk-crosscheck',
  apiKeyPreview: 'sk...crosscheck',
  models: [],
  catalogModels: [],
};

const originModel: AIModel = {
  id: 'gpt-4.1',
  name: 'GPT-4.1',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
};

const crosscheckModel: AIModel = {
  id: 'claude-sonnet-4',
  name: 'Claude Sonnet 4',
  capabilities: ['text'],
  reasoningModeAvailable: false,
  isAvailable: true,
  isDefault: true,
  priceTier: '',
};

function message(overrides: Partial<ChatMessage>): ChatMessage {
  return {
    id: overrides.id ?? 'm1',
    role: overrides.role ?? 'assistant',
    text: overrides.text ?? '',
    providerKind: overrides.providerKind ?? 'openAI',
    providerID: overrides.providerID,
    providerName: overrides.providerName ?? 'OpenAI',
    modelID: overrides.modelID,
    modelName: overrides.modelName ?? 'GPT-4.1',
    estimatedCost: 0,
    state: overrides.state ?? 'delivered',
    createdAt: overrides.createdAt ?? '2026-06-19T00:00:00.000Z',
    ...overrides,
  };
}

function conversation(): Conversation {
  return {
    id: 'conv-1',
    title: 'Chat',
    hasCustomTitle: false,
    providerID: originProvider.id,
    providerKind: originProvider.kind,
    modelID: originModel.id,
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [
      message({ id: 'user-1', role: 'user', text: 'What is vector search?' }),
      message({
        id: 'assistant-1',
        role: 'assistant',
        text: 'Vector search compares embeddings.',
        providerID: originProvider.id,
        providerKind: originProvider.kind,
        providerName: 'OpenAI',
        modelID: originModel.id,
        modelName: originModel.name,
      }),
    ],
    draftText: '',
    createdAt: '2026-06-19T00:00:00.000Z',
    updatedAt: '2026-06-19T00:00:00.000Z',
  };
}

describe('createNoteFromCrosscheck', () => {
  it('creates a full-answer note with two structured provenance entries', () => {
    const store = createAppStore();
    const conv = conversation();

    const note = createNoteFromCrosscheck(store, {
      conversation: conv,
      originMessage: conv.messages[1],
      originalPrompt: conv.messages[0].text,
      originalAnswer: conv.messages[1].text,
      originProvider,
      originModel,
      crosscheckProvider,
      crosscheckModel,
      crosscheckText: 'Mostly correct, but mention cosine similarity.',
    });

    expect(note.captureKind).toBe('fullAnswer');
    expect(note.sourceConversationId).toBe('conv-1');
    expect(note.sourceMessageId).toBe('assistant-1');
    expect(note.sourcePrompt).toBe('What is vector search?');
    expect(note.sourceModelID).toBe('gpt-4.1');
    expect(note.sourceModelName).toBe('GPT-4.1');
    expect(note.sourceProviderKind).toBe('openAI');
    expect(note.sourceProviderName).toBe('OpenAI');
    expect(note.body).toContain('## Original answer');
    expect(note.body).toContain('Vector search compares embeddings.');
    expect(note.body).toContain('## Cross-check (Claude Sonnet 4)');
    expect(note.body).toContain('Mostly correct, but mention cosine similarity.');
    expect(note.provenance).toEqual([
      expect.objectContaining({
        kind: 'origin',
        modelID: 'gpt-4.1',
        modelName: 'GPT-4.1',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        conversationId: 'conv-1',
        messageId: 'assistant-1',
      }),
      expect.objectContaining({
        kind: 'crosscheck',
        modelID: 'claude-sonnet-4',
        modelName: 'Claude Sonnet 4',
        providerKind: 'anthropic',
        providerName: 'Anthropic',
        conversationId: 'conv-1',
        messageId: 'assistant-1',
      }),
    ]);
    expect(store.getState().notes[0].id).toBe(note.id);
  });
});
