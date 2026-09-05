/**
 * Grouping conversations by time.
 * Extracted from ConversationList as a standalone utility.
 */
import type { Conversation, Folder } from '@oriveo/shared';
import {
  isVisibleConversation,
  sortConversationsByActivity,
} from './conversation-list';

export type GroupKey = 'today' | 'yesterday' | 'thisWeek' | 'earlier';

/**
 * Whether a conversation belongs to a folder that still exists.
 * A folderID present in the folders list means it belongs to that folder;
 * a folderID pointing at a deleted folder (an orphan) counts as unfiled.
 */
function isInValidFolder(c: Conversation, folders?: Folder[]): boolean {
  if (!c.folderID) return false;
  // Without a folders list, fall back to the older rule: any folderID means it is in a folder.
  if (!folders) return true;
  return folders.some((f) => f.id === c.folderID);
}

export function groupConversations(conversations: Conversation[], folders?: Folder[]) {
  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const yesterday = new Date(today.getTime() - 86_400_000);
  const weekAgo = new Date(today.getTime() - 7 * 86_400_000);

  const groups: { key: GroupKey; items: Conversation[] }[] = [
    { key: 'today', items: [] },
    { key: 'yesterday', items: [] },
    { key: 'thisWeek', items: [] },
    { key: 'earlier', items: [] },
  ];

  const sorted = sortConversationsByActivity(
    conversations.filter((c) => isVisibleConversation(c) && !isInValidFolder(c, folders)),
  );

  for (const c of sorted) {
    const d = new Date(c.updatedAt);
    if (d >= today) groups[0].items.push(c);
    else if (d >= yesterday) groups[1].items.push(c);
    else if (d >= weekAgo) groups[2].items.push(c);
    else groups[3].items.push(c);
  }

  return groups.filter((g) => g.items.length > 0);
}
