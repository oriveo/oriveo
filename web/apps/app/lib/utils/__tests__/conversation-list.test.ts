import { describe, expect, it } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import {
  compareConversationsByActivity,
  isVisibleConversation,
  partitionSidebarConversations,
  sortConversationsByActivity,
} from '../conversation-list';

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: crypto.randomUUID(),
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'provider-1',
    modelID: 'gpt-4o',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    createdAt: '2026-03-29T10:00:00.000Z',
    updatedAt: '2026-03-29T10:00:00.000Z',
    ...overrides,
  };
}

describe('conversation-list utils', () => {
  it('filters out empty draft conversations', () => {
    expect(isVisibleConversation(makeConversation({ isDraft: true, messages: [] }))).toBe(false);
    expect(
      isVisibleConversation(
        makeConversation({
          isDraft: true,
          messages: [{
            id: 'msg-1',
            role: 'user',
            text: 'Hello',
            providerKind: 'openAI',
            providerName: 'OpenAI',
            modelName: 'gpt-4o',
            estimatedCost: 0,
            state: 'delivered',
            createdAt: '2026-03-29T10:01:00.000Z',
          }],
        }),
      ),
    ).toBe(true);
  });

  it('keeps empty drafts visible when they already belong to a folder', () => {
    expect(
      isVisibleConversation(
        makeConversation({
          isDraft: true,
          messages: [],
          folderID: 'folder-1',
        }),
      ),
    ).toBe(true);
  });

  it('sorts strictly by updatedAt desc to stay aligned with iOS / Android', () => {
    const older = makeConversation({
      id: 'conv-old',
      updatedAt: '2026-03-29T11:00:00.000Z',
    });
    const newer = makeConversation({
      id: 'conv-new',
      updatedAt: '2026-03-29T12:00:00.000Z',
    });

    expect(compareConversationsByActivity(older, newer)).toBeGreaterThan(0);
    expect(sortConversationsByActivity([older, newer]).map((item) => item.id)).toEqual(['conv-new', 'conv-old']);
  });

  it('treats identical updatedAt as a tie (preserves input order, no firestoreUpdatedAt tie-break)', () => {
    // There is no secondary firestoreUpdatedAt tie-break: for an identical updatedAt millisecond,
    // the stability of Array.prototype.sort preserves the input order.
    const sameTime = '2026-03-29T12:00:00.000Z';
    const a = makeConversation({
      id: 'conv-a',
      updatedAt: sameTime,
      firestoreUpdatedAt: '2026-03-29T12:00:00.100Z',
    });
    const b = makeConversation({
      id: 'conv-b',
      updatedAt: sameTime,
      firestoreUpdatedAt: '2026-03-29T12:00:00.900Z',
    });

    expect(compareConversationsByActivity(a, b)).toBe(0);
    expect(sortConversationsByActivity([a, b]).map((item) => item.id)).toEqual(['conv-a', 'conv-b']);
  });

  it('partitions sidebar conversations in one pass while preserving visible ordering rules', () => {
    const folderAFirst = makeConversation({ id: 'folder-a-1', folderID: 'folder-a' });
    const pinnedSecond = makeConversation({ id: 'pinned-2' });
    const loose = makeConversation({ id: 'loose-1' });
    const folderASecond = makeConversation({ id: 'folder-a-2', folderID: 'folder-a' });
    const folderBOnly = makeConversation({ id: 'folder-b-1', folderID: 'folder-b' });
    const pinnedFirst = makeConversation({ id: 'pinned-1' });

    const result = partitionSidebarConversations(
      [folderAFirst, pinnedSecond, loose, folderASecond, folderBOnly, pinnedFirst],
      ['pinned-1', 'pinned-2'],
    );

    expect(result.pinned.map((item) => item.id)).toEqual(['pinned-1', 'pinned-2']);
    expect(result.unpinned.map((item) => item.id)).toEqual(['loose-1']);
    expect(result.byFolder.get('folder-a')?.map((item) => item.id)).toEqual(['folder-a-1', 'folder-a-2']);
    expect(result.byFolder.get('folder-b')?.map((item) => item.id)).toEqual(['folder-b-1']);
  });
});
