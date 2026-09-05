import {
  dedupeProvidersByID,
  normalizeProviderIDs,
  sameNormalizedID,
} from '../../../utils/id-utils';
import type { AppActions } from '../app-store';
import type { AppStoreSet } from './types';

type ProviderActions = Pick<
  AppActions,
  'setProviders' | 'addProvider' | 'updateProvider' | 'removeProvider'
>;

/** Provider slice: CRUD over the providers array, deduplicating and matching on the normalized id. */
export function createProviderSlice(set: AppStoreSet): ProviderActions {
  return {
    setProviders: (providers) => set({ providers: dedupeProvidersByID(providers) }),
    addProvider: (provider) =>
      set((s) => {
        const normalized = normalizeProviderIDs(provider);
        const idx = s.providers.findIndex((p) => sameNormalizedID(p.id, normalized.id));
        if (idx !== -1) {
          const next = s.providers.slice();
          next[idx] = normalized;
          return { providers: next };
        }
        return { providers: [...s.providers, normalized] };
      }),
    updateProvider: (id, patch) =>
      set((s) => ({
        providers: s.providers.map((p) =>
          sameNormalizedID(p.id, id) ? normalizeProviderIDs({ ...p, ...patch }) : p,
        ),
      })),
    removeProvider: (id) =>
      set((s) => ({ providers: s.providers.filter((p) => !sameNormalizedID(p.id, id)) })),
  };
}
