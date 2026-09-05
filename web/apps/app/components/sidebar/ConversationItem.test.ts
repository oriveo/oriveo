import { describe, expect, it, vi } from 'vitest';
import type { Conversation, Provider } from '@oriveo/shared';
import {
  resolveConversationItemModelName,
  resolveConversationItemProviderKind,
} from './ConversationItem';

const { mockCreateModelDisplayLookup } = vi.hoisted(() => ({
  mockCreateModelDisplayLookup: vi.fn(),
}));

vi.mock('../../lib/core/providers/model-display-lookup', () => ({
  createModelDisplayLookup: mockCreateModelDisplayLookup,
}));

function makeConversation(): Conversation {
  return {
    id: 'conversation-1',
    title: 'History',
    hasCustomTitle: false,
    providerID: 'provider-1',
    providerKind: 'openAI',
    modelID: 'o4-mini-2026-04-10',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [
      {
        id: 'assistant-1',
        role: 'assistant',
        text: 'Hello',
        providerID: 'provider-1',
        providerKind: 'openAI',
        providerName: 'OpenAI',
        modelID: 'o4-mini-2026-04-10',
        modelName: 'Stored Snapshot Name',
        state: 'delivered',
        estimatedCost: 0,
      },
    ],
    draftText: '',
    createdAt: '2026-04-10T00:00:00.000Z',
    updatedAt: '2026-04-10T00:00:00.000Z',
  };
}

function makeProvider(): Provider {
  return {
    id: 'provider-1',
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test',
    apiKeyPreview: 'sk-...test',
  };
}

describe('resolveConversationItemModelName', () => {
  it('prefers display lookup for historical metadata-backed models', () => {
    mockCreateModelDisplayLookup.mockReset();
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue({
        modelId: 'o4-mini',
        canonicalModelId: 'o4-mini',
        displayName: 'o4-mini',
      }),
    });

    const modelName = resolveConversationItemModelName(makeConversation(), makeProvider());

    expect(modelName).toBe('o4-mini');
  });

  it('falls back to the persisted assistant model name when lookup misses', () => {
    mockCreateModelDisplayLookup.mockReset();
    mockCreateModelDisplayLookup.mockReturnValue({
      resolve: vi.fn().mockReturnValue(null),
    });

    const modelName = resolveConversationItemModelName(makeConversation(), makeProvider());

    expect(modelName).toBe('Stored Snapshot Name');
  });
});

describe('resolveConversationItemProviderKind', () => {
  it('returns conversation.providerKind directly, since the type layer requires it and there is no fallback', () => {
    const conversation: Conversation = {
      ...makeConversation(),
      providerKind: 'anthropic',
    };
    expect(resolveConversationItemProviderKind(conversation)).toBe('anthropic');
  });

  it('a relay conversation also only reads providerKind, leaving relayKind to ProviderIcon', () => {
    const conversation: Conversation = {
      ...makeConversation(),
      providerKind: 'relay',
      relayKind: 'anthropic_compatible',
    };
    expect(resolveConversationItemProviderKind(conversation)).toBe('relay');
  });

  it('uses conversation.providerKind when present', () => {
    const conversation: Conversation = {
      ...makeConversation(),
      providerKind: 'openAI',
    };
    expect(resolveConversationItemProviderKind(conversation)).toBe('openAI');
  });
});
