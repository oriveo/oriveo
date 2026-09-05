import { normalizeUUID, sameNormalizedID } from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type PinActions = Pick<
  AppActions,
  'togglePinConversation' | 'setConversationOrder' | 'removeConversations' | 'applyRemotePinnedConversationIds'
>;

/**
 * Pin and order slice: the pinned list, its LWW timestamp and the conversation order.
 * removeConversations cascades across domains in a single atomic set(), clearing both
 * conversations and locallyDeletedConversationIds.
 */
export function createPinSlice(set: AppStoreSet): PinActions {
  return {
    togglePinConversation: (id, limit) => {
      let didToggle = false;
      set((s) => {
        const normalized = normalizeUUID(id);
        const isPinned = s.pinnedConversationIds.some((pid) => sameNormalizedID(pid, normalized));
        if (!isPinned && limit !== undefined && limit >= 0 && s.pinnedConversationIds.length >= limit) {
          return s;
        }
        const pinned = isPinned
          ? s.pinnedConversationIds.filter((pid) => !sameNormalizedID(pid, normalized))
          : [...s.pinnedConversationIds.map(normalizeUUID), normalized];
        didToggle = true;
        return {
          pinnedConversationIds: pinned,
          pinnedConversationIdsUpdatedAt: new Date().toISOString(),
        };
      });
      return didToggle;
    },
    setConversationOrder: (order) => set({ conversationOrder: order.map(normalizeUUID) }),
    removeConversations: (ids) =>
      set((s) => {
        const normalizedIDs = ids.map(normalizeUUID);
        const locallyDeletedConversationIds = [
          ...s.locallyDeletedConversationIds.filter((existingID) =>
            !normalizedIDs.some((id) => sameNormalizedID(existingID, id)),
          ),
          ...normalizedIDs,
        ];
        const filteredPinned = s.pinnedConversationIds.filter(
          (pid) => !normalizedIDs.some((id) => sameNormalizedID(pid, id)),
        );
        const pinnedChanged = filteredPinned.length !== s.pinnedConversationIds.length;
        return {
          conversations: s.conversations.filter((c) => !normalizedIDs.some((id) => sameNormalizedID(c.id, id))),
          pinnedConversationIds: filteredPinned,
          // Only refresh the timestamp when pinned actually changed, so an unrelated delete does not push sync noise into the preferences document
          pinnedConversationIdsUpdatedAt: pinnedChanged
            ? new Date().toISOString()
            : s.pinnedConversationIdsUpdatedAt,
          conversationOrder: s.conversationOrder.filter((oid) => !normalizedIDs.some((id) => sameNormalizedID(oid, id))),
          locallyDeletedConversationIds,
        };
      }),
    applyRemotePinnedConversationIds: (ids, remoteUpdatedAt) =>
      set({
        pinnedConversationIds: ids.map(normalizeUUID),
        pinnedConversationIdsUpdatedAt: remoteUpdatedAt,
      }),
  };
}
