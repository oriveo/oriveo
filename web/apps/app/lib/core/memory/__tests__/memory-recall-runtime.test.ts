import { describe, expect, it } from 'vitest';
import { MemoryItems, type MemoryItem, type MemoryItemInput } from '@oriveo/core/context/memory-items';
import { memoryRecallIndexFor, recallForTurn } from '../memory-recall-runtime';

const NOW_MS = Date.parse('2026-10-16T08:00:00.000Z');

function item(id: string, content: string, fields: Partial<MemoryItemInput> = {}): MemoryItem {
  return MemoryItems.canonical({
    id,
    kind: 'event',
    content,
    mutationId: `${id}-m`,
    deviceId: 'device-a',
    layer: 'episodic',
    occurredAt: '2026-10-01T00:00:00Z',
    ...fields,
  });
}

const QUERY = 'When did we migrate the billing database to Postgres?';
const EPISODIC = item('e1', 'Migrated the billing database to Postgres last sprint');

function recall(items: readonly MemoryItem[], useMemory = true) {
  return recallForTurn({ items, useMemory, query: QUERY, conversationId: 'c1', folderId: null, nowMs: NOW_MS });
}

describe('memory recall runtime', () => {
  it('returns ranked episodic hits with date and id', () => {
    expect(recall([EPISODIC])).toEqual([
      { id: 'e1', text: 'Migrated the billing database to Postgres last sprint', date: '2026-10-01' },
    ]);
  });

  it('use_memory_off_does_not_search', () => {
    expect(recall([EPISODIC], false)).toEqual([]);
  });

  it('free_account_still_recalls', () => {
    // The runtime does not look at the account tier: the same input gives the same result under any tier.
    expect(recall([EPISODIC]).map((h) => h.id)).toEqual(['e1']);
  });

  it('semantic_items_are_not_recalled', () => {
    const semantic = item('s1', EPISODIC.content, { layer: 'semantic', kind: 'fact' });
    expect(recall([semantic])).toEqual([]);
  });

  it('same_array_reuses_index', () => {
    const items = [EPISODIC];
    const first = memoryRecallIndexFor(items);
    recall(items);
    expect(memoryRecallIndexFor(items)).toBe(first);
    expect(memoryRecallIndexFor([EPISODIC])).not.toBe(first);
  });
});
