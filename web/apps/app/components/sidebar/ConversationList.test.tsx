import { describe, expect, it } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import type { GroupKey } from '../../lib/utils/conversation-grouping';
import {
  EARLIER_PAGE_SIZE,
  resolveConversationGroupDisplay,
} from './ConversationList';

function makeConversation(index: number): Conversation {
  return {
    id: `conversation-${index}`,
    title: `Conversation ${index}`,
    hasCustomTitle: false,
    providerID: 'provider-1',
    providerKind: 'openAI',
    modelID: 'model-1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: '2026-04-10T00:00:00.000Z',
    updatedAt: '2026-04-10T00:00:00.000Z',
  };
}

function makeConversations(count: number): Conversation[] {
  return Array.from({ length: count }, (_, index) => makeConversation(index + 1));
}

describe('resolveConversationGroupDisplay', () => {
  it('limits earlier groups to the configured page size in normal mode', () => {
    const result = resolveConversationGroupDisplay(
      'earlier',
      makeConversations(EARLIER_PAGE_SIZE + 2),
      false,
      EARLIER_PAGE_SIZE,
    );

    expect(result.items).toHaveLength(EARLIER_PAGE_SIZE);
    expect(result.remainingCount).toBe(2);
    expect(result.items.map((conversation) => conversation.id)).toEqual([
      'conversation-1',
      'conversation-2',
      'conversation-3',
      'conversation-4',
      'conversation-5',
      'conversation-6',
      'conversation-7',
      'conversation-8',
      'conversation-9',
      'conversation-10',
    ]);
  });

  it('shows all earlier conversations while editing so bulk actions can target the full group', () => {
    const conversations = makeConversations(EARLIER_PAGE_SIZE + 2);

    const result = resolveConversationGroupDisplay(
      'earlier',
      conversations,
      true,
      EARLIER_PAGE_SIZE,
    );

    expect(result.items).toEqual(conversations);
    expect(result.remainingCount).toBe(0);
  });

  it('does not truncate non-earlier groups', () => {
    const conversations = makeConversations(EARLIER_PAGE_SIZE + 4);

    const groupKeys: GroupKey[] = ['today', 'yesterday', 'thisWeek'];
    for (const groupKey of groupKeys) {
      const result = resolveConversationGroupDisplay(
        groupKey,
        conversations,
        false,
        EARLIER_PAGE_SIZE,
      );

      expect(result.items).toEqual(conversations);
      expect(result.remainingCount).toBe(0);
    }
  });
});
