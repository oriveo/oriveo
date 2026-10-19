import { sameNormalizedID } from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type MemoryActions = Pick<AppActions, 'setConversationUseMemory' | 'setMemoryItems'>;

/**
 * Memory slice: the per-conversation memory switch and the local memory items.
 * setConversationUseMemory updates the conversations domain in a single set().
 * setMemoryItems replaces the whole table (the caller passes items already sorted and free of tombstones).
 */
export function createMemorySlice(set: AppStoreSet): MemoryActions {
  return {
    setConversationUseMemory: (conversationId, useMemory) =>
      set((s) => ({
        conversations: s.conversations.map((c) =>
          sameNormalizedID(c.id, conversationId)
            ? { ...c, useMemory }
            : c,
        ),
      })),
    setMemoryItems: (memoryItems) => set({ memoryItems }),
  };
}
