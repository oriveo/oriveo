import type { Conversation, Note } from '@oriveo/shared';
import { normalizeUUID, sameNormalizedID } from '../../utils/id-utils';

export type NoteSourceLinkState =
  | { available: true; conversationId: string }
  | { available: false; reason: 'noSource' | 'deleted' };

export function getNoteSourceLinkState(
  note: Pick<Note, 'sourceConversationId'>,
  _conversations: Pick<Conversation, 'id'>[],
  _locallyDeletedConversationIds: string[],
): NoteSourceLinkState {
  const sourceConversationId = note.sourceConversationId;
  if (!sourceConversationId) return { available: false, reason: 'noSource' };
  return { available: true, conversationId: normalizeUUID(sourceConversationId) };
}

export function countNotesReferencingConversation(
  notes: Pick<Note, 'sourceConversationId'>[],
  conversationId: string,
): number {
  return notes.filter((note) =>
    note.sourceConversationId && sameNormalizedID(note.sourceConversationId, conversationId),
  ).length;
}
