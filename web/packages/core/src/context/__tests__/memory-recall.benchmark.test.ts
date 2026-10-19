/**
 * L3 recall micro-benchmark: 1000 deterministic synthetic items + 200 queries.
 * Gate: with the index built, a single recall p95 < 30 ms over >= 200 runs; index build time is printed.
 */

import { describe, expect, it } from 'vitest';

import { MemoryItems, type MemoryItem } from '../memory-items';
import { buildMemoryRecallIndex, recallMemory } from '../memory-recall';

const ITEM_COUNT = 1000;
const QUERY_COUNT = 200;
const WARMUP = 30;
const NOW_MS = Date.parse('2026-10-16T08:00:00.000Z');

const EN = ['billing', 'database', 'postgres', 'migration', 'release', 'invoice', 'cache', 'deploy', 'review', 'budget',
  'sprint', 'design', 'mobile', 'sync', 'quota', 'vendor', 'contract', 'meeting', 'outage', 'latency'];
const ZH = ['\u6570\u636e\u5e93', '\u8fc1\u79fb', '\u53d1\u5e03', '\u8d26\u5355', '\u7f13\u5b58', '\u90e8\u7f72', '\u8bc4\u5ba1', '\u9884\u7b97', '\u4f1a\u8bae', '\u5408\u540c', '\u6545\u969c', '\u5ef6\u8fdf'];

/** Deterministic LCG so all runs see the same dataset. */
function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
}

function sentence(next: () => number, words: number): string {
  const parts: string[] = [];
  for (let i = 0; i < words; i += 1) {
    parts.push(next() < 0.7 ? EN[Math.floor(next() * EN.length)] : ZH[Math.floor(next() * ZH.length)]);
  }
  return parts.join(' ');
}

const random = rng(20261016);
const items: MemoryItem[] = Array.from({ length: ITEM_COUNT }, (_, i) =>
  MemoryItems.canonical({
    id: `item-${String(i).padStart(4, '0')}`,
    kind: i % 2 === 0 ? 'event' : 'decision',
    layer: 'episodic',
    content: `${sentence(random, 12 + (i % 20))} v${i % 7}.${i % 3}`,
    mutationId: `m-${i}`,
    deviceId: 'bench',
    occurredAt: new Date(NOW_MS - (i % 365) * 86_400_000).toISOString(),
    scope: i % 5 === 0 ? { type: 'conversation', id: 'c1' } : { type: 'global', id: null },
  }),
);
const queries = Array.from({ length: QUERY_COUNT }, () => sentence(random, 6 + Math.floor(random() * 30)));

function percentile(sorted: number[], q: number): number {
  return sorted[Math.ceil(q * sorted.length) - 1];
}

describe('memory recall benchmark', () => {
  it('recall_p95_under_30ms', () => {
    const buildStarted = performance.now();
    const index = buildMemoryRecallIndex(items);
    const buildMs = performance.now() - buildStarted;
    const context = { conversationId: 'c1', folderId: null, nowMs: NOW_MS };
    for (let i = 0; i < WARMUP; i += 1) recallMemory(index, queries[i % QUERY_COUNT], context);
    const samples: number[] = [];
    let hits = 0;
    for (const query of queries) {
      const started = performance.now();
      hits += recallMemory(index, query, context).length;
      samples.push(performance.now() - started);
    }
    const sorted = [...samples].sort((a, b) => a - b);
    const p95 = percentile(sorted, 0.95);
    console.info(
      `MemoryRecallBenchmark build=${buildMs.toFixed(2)}ms p50=${percentile(sorted, 0.5).toFixed(2)} p95=${p95.toFixed(2)} n=${sorted.length} hits=${hits}`,
    );
    expect(index.docs.length).toBe(ITEM_COUNT);
    expect(hits).toBeGreaterThan(0);
    expect(sorted.length).toBeGreaterThanOrEqual(200);
    expect(p95).toBeLessThan(30);
  });
});
