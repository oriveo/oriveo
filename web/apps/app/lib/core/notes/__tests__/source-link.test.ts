import { describe, expect, it } from 'vitest';
import type { Conversation, Note } from '@oriveo/shared';
import { countNotesReferencingConversation, getNoteSourceLinkState } from '../source-link';

function makeConversation(id: string): Conversation {
  return {
    id,
    title: id,
    hasCustomTitle: false,
    messages: [],
    providerID: 'provider-1',
    providerKind: 'openAI',
    modelID: 'gpt-5',
    previewText: '',
    createdAt: '2026-06-01T00:00:00.000Z',
    updatedAt: '2026-06-01T00:00:00.000Z',
    estimatedCost: 0,
    isDraft: false,
    draftText: '',
  };
}

function makeNote(id: string, sourceConversationId?: string): Note {
  return {
    id,
    title: id,
    titleSource: 'manual',
    body: '',
    tags: [],
    captureKind: sourceConversationId ? 'fullAnswer' : 'blank',
    sourceConversationId,
    createdAt: '2026-06-01T00:00:00.000Z',
    updatedAt: '2026-06-01T00:00:00.000Z',
  };
}

describe('source-link', () => {
  it('treats notes without a source conversation as unavailable', () => {
    expect(getNoteSourceLinkState(makeNote('n1'), [makeConversation('c1')], [])).toEqual({ available: false, reason: 'noSource' });
  });

  it('keeps the source link available from the saved anchor even when local conversation state is missing', () => {
    const note = makeNote('n1', 'c1');

    expect(getNoteSourceLinkState(note, [makeConversation('c1')], [])).toEqual({ available: true, conversationId: 'c1' });
    expect(getNoteSourceLinkState(note, [], [])).toEqual({ available: true, conversationId: 'c1' });
    expect(getNoteSourceLinkState(note, [makeConversation('c1')], ['c1'])).toEqual({ available: true, conversationId: 'c1' });
  });

  it('returns a canonical conversation id for source anchors', () => {
    const note = makeNote('n1', 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa');

    expect(getNoteSourceLinkState(note, [], [])).toEqual({
      available: true,
      conversationId: 'AAAAAAAA-AAAA-4AAA-AAAA-AAAAAAAAAAAA',
    });
  });

  it('counts active notes referencing a conversation', () => {
    expect(countNotesReferencingConversation([
      makeNote('n1', 'c1'),
      makeNote('n2', 'c1'),
      makeNote('n3', 'c2'),
      makeNote('n4'),
    ], 'c1')).toBe(2);
  });
});
