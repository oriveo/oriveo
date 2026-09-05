import {
  dedupeConversationsByID,
  normalizeConversationIDs,
  sameNormalizedID,
} from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet, AppStoreGet } from './types';

type ConversationActions = Pick<
  AppActions,
  'setConversations' | 'addConversation' | 'updateConversation' | 'removeConversation'
>;

/** Conversation slice: CRUD over the conversations array. removeConversation delegates to removeConversations in pinSlice for the cascade cleanup. */
export function createConversationSlice(set: AppStoreSet, get: AppStoreGet): ConversationActions {
  return {
    setConversations: (conversations) => set({ conversations: dedupeConversationsByID(conversations) }),
    addConversation: (conversation) =>
      set((s) => ({ conversations: [normalizeConversationIDs(conversation), ...s.conversations] })),
    updateConversation: (id, patch) =>
      set((s) => ({
        conversations: s.conversations.map((c) =>
          sameNormalizedID(c.id, id) ? normalizeConversationIDs({ ...c, ...patch }) : c,
        ),
      })),
    removeConversation: (id) => {
      // Delegate to removeConversations so pinnedConversationIds and conversationOrder are cleaned up as well
      get().removeConversations([id]);
    },
  };
}
