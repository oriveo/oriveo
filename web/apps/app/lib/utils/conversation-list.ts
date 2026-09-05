import type { Conversation } from '@oriveo/shared';

export interface SidebarConversationBuckets {
  pinned: Conversation[];
  unpinned: Conversation[];
  byFolder: Map<string, Conversation[]>;
}

function parseTimestamp(value?: string): number {
  if (!value) return 0;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : 0;
}

export function isVisibleConversation(
  conversation: Pick<Conversation, 'isDraft' | 'messages' | 'folderID' | 'isConflictCopy'>,
): boolean {
  // Merge conflict copies are hidden from the main list by default and rendered by ConflictCopyGroup.
  // Full-text search hits are kept separately, since search results do not pass through this filter.
  if (conversation.isConflictCopy) return false;
  return Boolean(conversation.folderID) || !conversation.isDraft || conversation.messages.length > 0;
}

export function isConflictCopy(
  conversation: Pick<Conversation, 'isConflictCopy'>,
): boolean {
  return conversation.isConflictCopy === true;
}

/**
 * Sorts on the single field updatedAt, descending.
 *
 * updatedAt means the createdAt of the last delivered message, falling back to conv.createdAt for
 * an empty conversation, so that one field is enough to keep ordering consistent everywhere.
 * A firestoreUpdatedAt or UUID tie-break is unnecessary and would only make this client disagree
 * with the mobile ones.
 */
export function compareConversationsByActivity(
  left: Pick<Conversation, 'updatedAt'>,
  right: Pick<Conversation, 'updatedAt'>,
): number {
  return parseTimestamp(right.updatedAt) - parseTimestamp(left.updatedAt);
}

export function sortConversationsByActivity(conversations: Conversation[]): Conversation[] {
  return [...conversations].sort(compareConversationsByActivity);
}

export function partitionSidebarConversations(
  conversations: Conversation[],
  pinnedIds: string[],
): SidebarConversationBuckets {
  const pinnedOrder = new Map<string, number>();
  pinnedIds.forEach((id, index) => pinnedOrder.set(id, index));

  const pinnedSlots: Array<Conversation | undefined> = new Array(pinnedIds.length);
  const unpinned: Conversation[] = [];
  const byFolder = new Map<string, Conversation[]>();

  for (const conversation of conversations) {
    const pinnedIndex = pinnedOrder.get(conversation.id);
    if (pinnedIndex != null) {
      pinnedSlots[pinnedIndex] = conversation;
    }

    if (conversation.folderID) {
      const bucket = byFolder.get(conversation.folderID);
      if (bucket) {
        bucket.push(conversation);
      } else {
        byFolder.set(conversation.folderID, [conversation]);
      }
      continue;
    }

    if (pinnedIndex == null) {
      unpinned.push(conversation);
    }
  }

  return {
    pinned: pinnedSlots.filter((conversation): conversation is Conversation => Boolean(conversation)),
    unpinned,
    byFolder,
  };
}
