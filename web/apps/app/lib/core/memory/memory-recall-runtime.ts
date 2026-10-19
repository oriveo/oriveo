/**
 * L3 recall runtime: the store.memoryItems slice -> index cache -> recallMemory -> dynamic.recall.
 * - The slice array is immutable, so a new array is a new key: a WeakMap keyed by the array caches the index, and it rebuilds naturally when the item set changes.
 * - No retrieval when the effective useMemory is off; the account tier is not considered (L3 stays on this device).
 */

import type { RecallEntry } from '@oriveo/core/context/assemble';
import type { MemoryItem } from '@oriveo/core/context/memory-items';
import { buildMemoryRecallIndex, recallMemory, type MemoryRecallIndex } from '@oriveo/core/context/memory-recall';

const indexCache = new WeakMap<readonly MemoryItem[], MemoryRecallIndex>();

/** The same array reuses the same index. */
export function memoryRecallIndexFor(items: readonly MemoryItem[]): MemoryRecallIndex {
  const cached = indexCache.get(items);
  if (cached) return cached;
  const index = buildMemoryRecallIndex(items);
  indexCache.set(items, index);
  return index;
}

export interface TurnRecallInput {
  /** The original store.memoryItems slice array (do not copy it, copying invalidates the cache). */
  items: readonly MemoryItem[] | undefined;
  /** Same criterion as L2 injection (resolvePromptUseMemory). */
  useMemory: boolean;
  /** Raw text of the user message this turn answers. */
  query: string;
  conversationId: string;
  folderId: string | null;
  nowMs?: number;
}

/** This turn's L3 recall result (in rank order); all legs of the same turn reuse this one. */
export function recallForTurn(input: TurnRecallInput): RecallEntry[] {
  if (!input.useMemory || !input.items || input.items.length === 0) return [];
  const hits = recallMemory(memoryRecallIndexFor(input.items), input.query, {
    conversationId: input.conversationId,
    folderId: input.folderId,
    nowMs: input.nowMs ?? Date.now(),
  });
  return hits.map((hit) => ({ id: hit.id, text: hit.text, date: hit.date }));
}

export interface RecallableItemsInput {
  items: readonly MemoryItem[] | undefined;
  conversationId: string;
  folderId: string | null;
  nowMs?: number;
}

/**
 * Number of effective L3 items visible to this conversation (the recallableItems criterion of search_memory mode): only items that entered the index are counted,
 * with scope and expiry following the same rules as memory-recall (global; conversation / folder compared by id, case-insensitively).
 */
export function recallableMemoryItemCount(input: RecallableItemsInput): number {
  if (!input.items || input.items.length === 0) return 0;
  const nowMs = input.nowMs ?? Date.now();
  const conversationId = input.conversationId.toLowerCase();
  const folderId = input.folderId?.toLowerCase() ?? null;
  let count = 0;
  for (const { item } of memoryRecallIndexFor(input.items).docs) {
    if (item.expiresAt !== null && !(Date.parse(item.expiresAt) > nowMs)) continue;
    const scopeId = item.scope.id?.toLowerCase() ?? null;
    const visible = item.scope.type === 'global'
      || (item.scope.type === 'conversation' && scopeId !== null && scopeId === conversationId)
      || (item.scope.type === 'folder' && scopeId !== null && folderId !== null && scopeId === folderId);
    if (visible) count += 1;
  }
  return count;
}
