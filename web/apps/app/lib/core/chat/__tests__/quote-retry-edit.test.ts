import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { AIModel, ChatMessage, Conversation, Provider } from '@oriveo/shared';

const { mockSendMessage } = vi.hoisted(() => ({ mockSendMessage: vi.fn() }));

vi.mock('../operations-send', () => ({
  sendMessage: (...args: unknown[]) => mockSendMessage(...args),
}));
vi.mock('../cleanup-attachments', () => ({ cleanupCloudAttachments: vi.fn() }));
vi.mock('../../sync-port', () => ({ getSyncAdapter: () => undefined }));
vi.mock('../../telemetry', async () => ({
  trackEvent: vi.fn(),
  telemetryProviderKind: (kind: string) => kind,
  // relay  
  telemetryModelID: (await vi.importActual<typeof import('../../telemetry')>('../../telemetry')).telemetryModelID,
}));

import { editAndResend } from '../operations-edit';
import { retryMessageWithSender } from '../operations-retry';

const quoteContext = {
  schemaVersion: 1 as const,
  sourceMessageId: 'source-1',
  sourceRole: 'assistant' as const,
  contentKind: 'prose' as const,
  leadingText: 'before ', selectedText: 'selected', trailingText: ' after',
  contextTruncated: false,
};

const provider: Provider = {
  id: 'provider-1', kind: 'openAI', status: { kind: 'connected' },
  models: [], catalogModels: [], apiKey: 'key', apiKeyPreview: 'key',
};
const model: AIModel = {
  id: 'model-1', name: 'GPT', capabilities: ['text'], reasoningModeAvailable: false,
  isAvailable: true, isDefault: true, priceTier: '$', groupKey: 'gpt', groupName: 'GPT',
};
const user: ChatMessage = {
  id: 'user-1', role: 'user', text: 'Original input', providerKind: 'openAI',
  providerName: 'OpenAI', modelName: 'GPT', estimatedCost: 0, state: 'delivered',
  createdAt: '2026-08-04T00:00:00.000Z', quoteContext,
};
const assistant: ChatMessage = {
  ...user, id: 'assistant-1', role: 'assistant', text: 'Answer',
  createdAt: '2026-08-04T00:00:00.001Z',
};
const conversation: Conversation = {
  id: 'conversation-1', title: 'Chat', hasCustomTitle: false, providerID: provider.id,
  providerKind: provider.kind, modelID: model.id, previewText: 'Original input', estimatedCost: 0,
  isDraft: false, messages: [user, assistant], draftText: '',
  updatedAt: assistant.createdAt!, createdAt: user.createdAt!,
};

function makeContext() {
  return {
    store: { getState: () => ({ updateConversation: vi.fn() }) },
    appendChunk: vi.fn(),
    te: (key: string) => key,
  } as never;
}

describe('QuoteContext retry/edit recovery', () => {
  beforeEach(() => {
    mockSendMessage.mockReset();
    mockSendMessage.mockReturnValue({ convId: conversation.id, msgId: 'next', abort: vi.fn(), done: Promise.resolve() });
  });

  it('retry reuses the original user message quote snapshot', () => {
    const sender = vi.fn().mockReturnValue({ convId: conversation.id, msgId: 'retry', abort: vi.fn(), done: Promise.resolve() });
    retryMessageWithSender(makeContext(), {
      messageId: assistant.id,
      conversation,
      messages: [user, assistant],
      provider,
      model,
      reasoningMode: 'automatic',
    }, sender);

    expect(sender.mock.calls[0][1]).toMatchObject({
      text: 'Original input',
      quoteContext,
    });
  });

  it('validated model-control resend appends to and preserves partial production message content', () => {
    const userAttachment = { id: 'user-file', kind: 'file' as const, fileName: 'draft.txt', mimeType: 'text/plain', base64Data: 'draft' };
    const generatedAttachment = { id: 'generated-image', kind: 'image' as const, fileName: 'partial.png', mimeType: 'image/png', localImageID: 'image-1' };
    const failedUser: ChatMessage = { ...user, attachments: [userAttachment] };
    const partialAssistant: ChatMessage = {
      ...assistant,
      state: 'failed',
      text: 'Already generated',
      reasoningText: 'Partial reasoning',
      reasoningDurationMs: 420,
      attachments: [generatedAttachment],
      citations: [{ url: 'https://example.com/source', title: 'Existing source' }],
      estimatedCost: 0.25,
      capabilityRecovery: {
        version: 1,
        action: 'user_confirmed_resend_without_located_setting',
        source: 'provider_recipe',
        owners: ['web'],
        recipeRef: 'fixture.web.v1',
        locatedPointers: ['/web_search_options'],
      },
    };
    const sender = vi.fn().mockReturnValue({ convId: conversation.id, msgId: partialAssistant.id, abort: vi.fn(), done: Promise.resolve() });

    retryMessageWithSender(makeContext(), {
      messageId: partialAssistant.id,
      conversation: { ...conversation, messages: [failedUser, partialAssistant] },
      messages: [failedUser, partialAssistant],
      provider,
      model,
      reasoningMode: 'automatic',
      capabilityRecipeOmissions: [{ recipeRef: 'fixture.web.v1', locatedPointers: ['/web_search_options'] }],
      capabilityRecipeResendOwners: ['web'],
    }, sender);

    expect(sender.mock.calls[0][1]).toMatchObject({
      appendToAssistant: true,
      attachments: [userAttachment],
      assistantMessageOverride: {
        id: partialAssistant.id,
        text: 'Already generated',
        reasoningText: 'Partial reasoning',
        reasoningDurationMs: 420,
        attachments: [generatedAttachment],
        citations: [{ url: 'https://example.com/source', title: 'Existing source' }],
        estimatedCost: 0.25,
        state: 'generating',
      },
    });
    expect(sender.mock.calls[0][1].assistantMessageOverride.capabilityRecovery).toBeUndefined();
  });

  it('ordinary failed retry still clears partial assistant output', () => {
    const partialAssistant: ChatMessage = {
      ...assistant, state: 'failed', text: 'Partial', reasoningText: 'Reasoning',
      attachments: [{ id: 'generated-image', kind: 'image', fileName: 'partial.png', mimeType: 'image/png' }],
      citations: [{ url: 'https://example.com/source' }],
    };
    const sender = vi.fn().mockReturnValue({ convId: conversation.id, msgId: partialAssistant.id, abort: vi.fn(), done: Promise.resolve() });

    retryMessageWithSender(makeContext(), {
      messageId: partialAssistant.id,
      conversation: { ...conversation, messages: [user, partialAssistant] },
      messages: [user, partialAssistant], provider, model, reasoningMode: 'automatic',
    }, sender);

    expect(sender.mock.calls[0][1]).toMatchObject({
      assistantMessageOverride: { text: '', state: 'generating' },
    });
    expect(sender.mock.calls[0][1].appendToAssistant).toBeUndefined();
    expect(sender.mock.calls[0][1].assistantMessageOverride.reasoningText).toBeUndefined();
    expect(sender.mock.calls[0][1].assistantMessageOverride.attachments).toBeUndefined();
    expect(sender.mock.calls[0][1].assistantMessageOverride.citations).toBeUndefined();
  });

  it('edit and resend restores the quote while replacing only Current User Input', () => {
    editAndResend(makeContext(), {
      messageId: user.id,
      newText: 'Rewritten input',
      conversation,
      messages: [user, assistant],
      provider,
      model,
      reasoningMode: 'automatic',
    });

    expect(mockSendMessage.mock.calls[0][1]).toMatchObject({
      text: 'Rewritten input',
      quoteContext,
    });
  });
});
