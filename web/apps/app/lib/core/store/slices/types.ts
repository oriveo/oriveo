import type { StoreApi } from 'zustand';
import type { AppStore } from '../app-store';

// Shared set/get types for slice creators: they are the top-level setState/getState of the
// composed store, so a single set() in any slice can atomically update fields owned by another
// slice (zustand v5 merges at the top level).
export type AppStoreSet = StoreApi<AppStore>['setState'];
export type AppStoreGet = StoreApi<AppStore>['getState'];
