import { sameNormalizedID } from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type MemoryActions = Pick<AppActions, 'setConversationUseMemory'>;

/**
 * Memory slice: the per-conversation memory switch.
 * setConversationUseMemory updates the conversations domain in a single set().
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
  };
}
