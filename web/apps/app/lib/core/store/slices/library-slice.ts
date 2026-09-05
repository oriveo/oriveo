import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type LibraryActions = Pick<AppActions,
  | 'setLibraryConnections'
  | 'setLibraryQuota'
  | 'setLibraryConnectionQuota'
  | 'setLibraryLoadState'
  | 'setLibraryResearchEnabled'
  | 'setLibraryResearchSteps'
  | 'setLibraryConfirmation'
  | 'resetLibraryState'
>;

export function createLibrarySlice(set: AppStoreSet): LibraryActions {
  return {
    setLibraryConnections: (connections) => set({ libraryConnections: connections }),
    setLibraryQuota: (quota) => set({ libraryQuota: quota }),
    setLibraryConnectionQuota: (quota) => set({ libraryConnectionQuota: quota }),
    setLibraryLoadState: (state, errorCode = null) => set({
      libraryLoadState: state,
      libraryErrorCode: errorCode,
    }),
    setLibraryResearchEnabled: (enabled) => set({ libraryResearchEnabled: enabled }),
    setLibraryResearchSteps: (conversationId, steps) => set((current) => ({
      libraryResearchSteps: {
        ...current.libraryResearchSteps,
        [conversationId]: steps,
      },
    })),
    setLibraryConfirmation: (confirmation) => set({ libraryConfirmation: confirmation }),
    resetLibraryState: () => set({
      libraryConnections: [],
      libraryQuota: null,
      libraryConnectionQuota: null,
      libraryLoadState: 'idle',
      libraryErrorCode: null,
      libraryResearchEnabled: false,
      libraryResearchSteps: {},
      libraryConfirmation: null,
    }),
  };
}
