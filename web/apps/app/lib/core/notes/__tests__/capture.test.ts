import { describe, expect, it, vi } from 'vitest';
import type { ChatMessage, Conversation, Provider } from '@oriveo/shared';
import {
  buildBlankNoteInput,
  buildMessageNoteInput,
  buildMessageNoteInputFromSnapshot,
  buildSelectionNoteInput,
  captureMessageAsNote,
} from '../capture';

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: 'provider-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [{ id: 'gpt-5', name: 'GPT-5', enabled: true, capabilities: ['text'] }],
    catalogModels: [],
    apiKey: 'sk',
    apiKeyPreview: 'sk...',
    ...overrides,
  };
}

function makeMessage(overrides: Partial<ChatMessage>): ChatMessage {
  return {
    id: overrides.id ?? 'assistant-1',
    role: overrides.role ?? 'assistant',
    text: overrides.text ?? 'Answer body',
    providerID: overrides.providerID ?? 'provider-1',
    providerKind: overrides.providerKind ?? 'openAI',
    providerName: overrides.providerName ?? 'OpenAI',
    modelID: overrides.modelID ?? 'gpt-5',
    modelName: overrides.modelName ?? 'GPT-5',
    estimatedCost: 0,
    state: overrides.state ?? 'delivered',
  };
}

function makeConversation(messages: ChatMessage[]): Conversation {
  return {
    id: 'conversation-1',
    title: 'Conversation',
    hasCustomTitle: false,
    providerID: 'provider-1',
    modelID: 'gpt-5',
    providerKind: 'openAI',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    createdAt: '2026-06-01T00:00:00.000Z',
    updatedAt: '2026-06-01T00:00:00.000Z',
  };
}

describe('buildMessageNoteInput', () => {
  it('captures a full assistant answer with source and provider snapshots', () => {
    const user = makeMessage({ id: 'user-1', role: 'user', text: 'What changed?' });
    const assistant = makeMessage({ id: 'assistant-1', text: '# Result\n\nFull markdown' });
    const input = buildMessageNoteInput({
      conversation: makeConversation([user, assistant]),
      message: assistant,
      provider: makeProvider(),
    });

    expect(input.captureKind).toBe('fullAnswer');
    expect(input.body).toBe('# Result\n\nFull markdown');
    expect(input.bodySnapshot).toBe('# Result\n\nFull markdown');
    expect(input.sourceConversationId).toBe('conversation-1');
    expect(input.sourceMessageId).toBe('assistant-1');
    expect(input.sourceModelID).toBe('gpt-5');
    expect(input.sourceModelName).toBe('GPT-5');
    expect(input.sourceProviderKind).toBe('openAI');
    expect(input.sourceProviderName).toBe('OpenAI');
    expect(input.sourcePrompt).toBe('What changed?');
  });

  it('captures a user message as userMessage', () => {
    const user = makeMessage({ id: 'user-1', role: 'user', text: 'My prompt' });
    const input = buildMessageNoteInput({
      conversation: makeConversation([user]),
      message: user,
      provider: makeProvider(),
    });

    expect(input.captureKind).toBe('userMessage');
    expect(input.body).toBe('My prompt');
    expect(input.sourcePrompt).toBe('My prompt');
  });
});

describe('buildSelectionNoteInput', () => {
  it('stores selected text as body while snapshot keeps the full source message', () => {
    const user = makeMessage({ id: 'user-1', role: 'user', text: 'Explain' });
    const assistant = makeMessage({ id: 'assistant-1', text: 'First\n\nSecond selected' });
    const input = buildSelectionNoteInput({
      conversation: makeConversation([user, assistant]),
      message: assistant,
      provider: makeProvider(),
      selectedText: 'Second selected',
    });

    expect(input.captureKind).toBe('selection');
    expect(input.body).toBe('Second selected');
    expect(input.bodySnapshot).toBe('First\n\nSecond selected');
    expect(input.sourcePrompt).toBe('Explain');
  });
});

describe('buildMessageNoteInputFromSnapshot', () => {
  it('builds source fields without requiring a full conversation object', () => {
    const assistant = makeMessage({ id: 'assistant-1', text: 'Body' });
    const input = buildMessageNoteInputFromSnapshot({
      conversationId: 'conversation-1',
      message: assistant,
      provider: makeProvider(),
      sourcePrompt: 'Prompt snapshot',
    });

    expect(input).toMatchObject({
      body: 'Body',
      bodySnapshot: 'Body',
      captureKind: 'fullAnswer',
      sourceConversationId: 'conversation-1',
      sourceMessageId: 'assistant-1',
      sourcePrompt: 'Prompt snapshot',
      sourceModelName: 'GPT-5',
      sourceProviderName: 'OpenAI',
    });
  });
});

describe('buildBlankNoteInput', () => {
  it('creates a blank local draft with no source fields', () => {
    expect(buildBlankNoteInput()).toEqual({ body: '', captureKind: 'blank' });
  });

  it('does not persist the uncategorized folder filter sentinel as a folder id', () => {
    expect(buildBlankNoteInput('__uncategorized__')).toEqual({ body: '', captureKind: 'blank' });
  });
});

describe('captureMessageAsNote', () => {
  it('delegates creation through the injected createNote function', () => {
    const createNote = vi.fn(() => ({ id: 'note-1' }));
    const assistant = makeMessage({ id: 'assistant-1', text: 'Body' });

    const note = captureMessageAsNote({
      store: {} as never,
      conversation: makeConversation([assistant]),
      message: assistant,
      provider: makeProvider(),
      createNote,
    });

    expect(note).toEqual({ id: 'note-1' });
    expect(createNote).toHaveBeenCalledWith(expect.anything(), expect.objectContaining({
      body: 'Body',
      captureKind: 'fullAnswer',
    }));
  });
});
