import { normalizeUUID } from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type AppMiscActions = Pick<
  AppActions,
  | 'setActiveConversationId'
  | 'setSelectedTab'
  | 'setSidebarOpen'
  | 'setHasCompletedOnboarding'
  | 'setAccount'
  | 'setPreferences'
  | 'setLastUsedModelRef'
  | 'setSearchQuery'
  | 'setSearchMatchIndex'
  | 'setImageGenMode'
>;

/**
 * App slice: setters for navigation, UI, conversation and search state that belongs to no domain
 * slice (selectedTab / activeConversationId / sidebarOpen / onboarding / account / preferences /
 * lastUsedModelRef / search / imageGenMode).
 * hydrationPhase has no action; bootstrap and StoreProvider write it with setState directly.
 */
export function createAppSlice(set: AppStoreSet): AppMiscActions {
  return {
    setActiveConversationId: (id) => set({ activeConversationId: id ? normalizeUUID(id) : null }),
    setSelectedTab: (tab) => set({ selectedTab: tab }),
    setSidebarOpen: (open) => set({ sidebarOpen: open }),
    setHasCompletedOnboarding: (value) => set({ hasCompletedOnboarding: value }),
    setAccount: (account) => set({ account }),
    setPreferences: (prefs) =>
      set((s) => ({ preferences: { ...s.preferences, ...prefs } })),
    setLastUsedModelRef: (ref) => set({ lastUsedModelRef: ref }),
    setSearchQuery: (query) => set({ searchQuery: query, searchMatchIndex: 0 }),
    setSearchMatchIndex: (index) => set({ searchMatchIndex: index }),
    setImageGenMode: (mode) => set({ imageGenMode: mode }),
  };
}
