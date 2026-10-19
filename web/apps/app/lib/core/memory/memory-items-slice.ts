/**
 * Memory item store slice: local rows -> store.memoryItems.
 * The slice holds only undeleted items in list order; at send time injection runs `MemoryItems.injectable` over it.
 * Refresh points: hydration (persistence), after a local repository write, and after a sync backend (if any) merges remote changes locally.
 */

import { MemoryItems, type MemoryItem } from '@oriveo/core/context/memory-items';
import { getActiveUIDSync } from '../../infra/storage/partition';
import type { MemoryItemRowStore } from './memory-item-row-store';

/** Only setMemoryItems is needed; a fake store in repository tests may omit the rest. */
export interface MemoryItemsSliceStore {
  getState(): { setMemoryItems?: (items: MemoryItem[]) => void };
}

/** Slice content: tombstones removed, in list order. */
export function memoryItemsForSlice(items: readonly MemoryItem[]): MemoryItem[] {
  return MemoryItems.listOrder([...items]).filter((m) => m.status !== 'deleted');
}

/** Read this account's rows to refresh the slice; nothing is written once the partition has switched away, so another account's items never land in the current store. */
export async function refreshMemoryItemsSlice(
  store: MemoryItemsSliceStore,
  uid: string,
  rows: Pick<MemoryItemRowStore, 'all'>,
): Promise<void> {
  const items = (await rows.all()).map((row) => row.item);
  if (getActiveUIDSync() !== uid) return;
  store.getState().setMemoryItems?.(memoryItemsForSlice(items));
}
