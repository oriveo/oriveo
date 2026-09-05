import { sameNormalizedID } from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type SyncActions = Pick<
  AppActions,
  'setSyncBanner' | 'clearRemotelyDeletedConvID' | 'clearLocallyDeletedConversation'
>;

/** Sync slice: cloud sync banner, remote deletion notice, and cleanup of local deletion markers. syncState has no action; the sync adapter writes it with setState directly. */
export function createSyncSlice(set: AppStoreSet): SyncActions {
  return {
    setSyncBanner: (banner) => set({ syncBanner: banner }),
    clearRemotelyDeletedConvID: () => set({ remotelyDeletedConvID: null }),
    clearLocallyDeletedConversation: (id) =>
      set((s) => ({
        locallyDeletedConversationIds: s.locallyDeletedConversationIds.filter(
          (deletedID) => !sameNormalizedID(deletedID, id),
        ),
      })),
  };
}
