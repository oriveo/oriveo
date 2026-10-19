/**
 * L3 recall (contract: context-contracts/memory-recall.v1.json).
 * Pure and in-memory: one tokenizer + BM25 for all three clients, so the same items and query give the same hits
 * byte for byte. No FTS table: client FTS engines differ (FTS5 trigram / FTS4 / none) and cannot be fixture-locked.
 */

import type { MemoryItem } from './memory-items';

export const MEMORY_RECALL_CONSTANTS = {
  k1: 1.2,
  b: 0.75,
  topK: 5,
  coverageMin: 0.25,
  minMatchedTerms: 2,
  idfPriorDocs: 20,
  scopeFactor: { conversation: 1.2, folder: 1.1, global: 1 },
  pinnedFactor: 1.2,
  halfLifeDays: 180,
  timeFloor: 0.5,
  confidenceFloor: 0.5,
  maxQueryCodePoints: 8000,
  conflictJaccardMin: 0.5,
  joiners: '_.-/#',
} as const;

const DAY_MS = 86_400_000;
const WORD = /[\p{L}\p{N}\p{M}]/u;
// Per-code-point ranges instead of the Script property: Swift cannot read the Unicode Script, so all platforms have to use the same range table
const CJK_RANGES: ReadonlyArray<readonly [number, number]> = [
  [0x1100, 0x11ff],
  [0x3040, 0x309f],
  [0x30a0, 0x30ff],
  [0x3130, 0x318f],
  [0x31f0, 0x31ff],
  [0x3400, 0x4dbf],
  [0x4e00, 0x9fff],
  [0xac00, 0xd7af],
  [0xf900, 0xfaff],
  [0x20000, 0x3134f],
];

function isCjk(cp: number): boolean {
  return CJK_RANGES.some(([lo, hi]) => cp >= lo && cp <= hi);
}

function isWord(ch: string): boolean {
  return WORD.test(ch);
}

function isJoiner(ch: string): boolean {
  return MEMORY_RECALL_CONSTANTS.joiners.includes(ch);
}

/** floor(x·1e6 + 0.5) / 1e6: the only rounding, applied before any comparison. */
function round6(x: number): number {
  return Math.floor(x * 1e6 + 0.5) / 1e6;
}

/** NFKC → lowercase (ς folded to σ) → code points. */
function normalized(text: string): string[] {
  return [...text.normalize('NFKC').toLowerCase().replace(/ς/g, 'σ')];
}

function wordTokens(cps: readonly string[], out: string[]): void {
  let run: string[] = [];
  let runCjk = false;
  const flush = () => {
    if (run.length === 0) return;
    if (!runCjk) out.push(run.join(''));
    else if (run.length === 1) out.push(run[0]);
    else for (let i = 0; i + 1 < run.length; i++) out.push(run[i] + run[i + 1]);
    run = [];
  };
  for (const ch of cps) {
    if (!isWord(ch)) {
      flush();
      continue;
    }
    const cjk = isCjk(ch.codePointAt(0)!);
    if (run.length > 0 && cjk !== runCjk) flush();
    runCjk = cjk;
    run.push(ch);
  }
  flush();
}

/** Identifiers such as foo_bar.ts, v2.3 or 2026-10-01 also count as one exact token. */
function compoundTokens(cps: readonly string[], out: string[]): void {
  let i = 0;
  while (i < cps.length) {
    if (!isWord(cps[i]) && !isJoiner(cps[i])) {
      i++;
      continue;
    }
    let j = i;
    while (j < cps.length && (isWord(cps[j]) || isJoiner(cps[j]))) j++;
    let start = i;
    let end = j;
    while (start < end && isJoiner(cps[start])) start++;
    while (end > start && isJoiner(cps[end - 1])) end--;
    const run = cps.slice(start, end);
    if (run.some(isJoiner)) out.push(run.join(''));
    i = j;
  }
}

/** Tokens in order: words (CJK runs as bigrams, a lone CJK char as itself), then compound identifiers. */
export function memoryRecallTokens(text: string): string[] {
  const cps = normalized(text);
  const out: string[] = [];
  wordTokens(cps, out);
  compoundTokens(cps, out);
  return out;
}

interface IndexedItem {
  item: MemoryItem;
  tf: Map<string, number>;
  length: number;
}

export interface MemoryRecallIndex {
  readonly docs: readonly IndexedItem[];
  readonly df: ReadonlyMap<string, number>;
  readonly avgdl: number;
}

/** Index over active L3 items (all scopes); scope / expiry are per request. Rebuild when the item set changes. */
export function buildMemoryRecallIndex(items: readonly MemoryItem[]): MemoryRecallIndex {
  const docs: IndexedItem[] = [];
  const df = new Map<string, number>();
  let total = 0;
  for (const item of items) {
    if (item.layer !== 'episodic' || item.status !== 'active') continue;
    const tokens = memoryRecallTokens(item.content);
    if (tokens.length === 0) continue;
    const tf = new Map<string, number>();
    for (const t of tokens) tf.set(t, (tf.get(t) ?? 0) + 1);
    for (const t of tf.keys()) df.set(t, (df.get(t) ?? 0) + 1);
    docs.push({ item, tf, length: tokens.length });
    total += tokens.length;
  }
  return { docs, df, avgdl: docs.length > 0 ? total / docs.length : 0 };
}

export interface MemoryRecallContext {
  readonly conversationId: string;
  readonly folderId: string | null;
  readonly nowMs: number;
}

export interface MemoryRecallHit {
  readonly id: string;
  readonly text: string;
  /** UTC YYYY-MM-DD of occurredAt ?? source.observedAt ?? createdAt; null when none parses. */
  readonly date: string | null;
  readonly score: number;
  readonly coverage: number;
}

function scopeFactor(item: MemoryItem, context: MemoryRecallContext): number | null {
  const id = item.scope.id?.toLowerCase() ?? null;
  switch (item.scope.type) {
    case 'global':
      return MEMORY_RECALL_CONSTANTS.scopeFactor.global;
    case 'conversation':
      return id !== null && id === context.conversationId.toLowerCase()
        ? MEMORY_RECALL_CONSTANTS.scopeFactor.conversation
        : null;
    case 'folder':
      return id !== null && context.folderId !== null && id === context.folderId.toLowerCase()
        ? MEMORY_RECALL_CONSTANTS.scopeFactor.folder
        : null;
    default:
      return null;
  }
}

function itemTimeMs(item: MemoryItem): number | null {
  for (const value of [item.occurredAt, item.source.observedAt, item.createdAt]) {
    if (value === null) continue;
    const ms = Date.parse(value);
    if (!Number.isNaN(ms)) return ms;
  }
  return null;
}

function utcDate(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

// N plus idfPriorDocs virtual documents that contain no words: with few items, topical words are not squashed to 0 by df≈N and do not lock relevant items out
function idf(index: MemoryRecallIndex, term: string): number {
  const n = index.df.get(term) ?? 0;
  const N = index.docs.length + MEMORY_RECALL_CONSTANTS.idfPriorDocs;
  return Math.log(1 + (N - n + 0.5) / (n + 0.5));
}

/** Relevance gate of one ranking: automatic [D] recall uses the constants, search_memory its own (memory-search.v1). */
export interface MemoryRecallGate {
  readonly coverageMin: number;
  readonly minMatchedTerms: number;
}

/** Top-K hits for the current user message; empty when nothing clears the coverage gate. */
export function recallMemory(index: MemoryRecallIndex, query: string, context: MemoryRecallContext): MemoryRecallHit[] {
  return rankMemory(index, query, context, MEMORY_RECALL_CONSTANTS, new Set());
}

/** Same scoring as recallMemory under another gate; excluded ids are skipped before Top-K. */
export function rankMemory(
  index: MemoryRecallIndex,
  query: string,
  context: MemoryRecallContext,
  gate: MemoryRecallGate,
  excludeIds: ReadonlySet<string>,
): MemoryRecallHit[] {
  const k = MEMORY_RECALL_CONSTANTS;
  const clipped = [...query].slice(0, k.maxQueryCodePoints).join('');
  const terms = new Set(memoryRecallTokens(clipped));
  if (terms.size === 0 || index.docs.length === 0) return [];
  const hits: MemoryRecallHit[] = [];
  for (const doc of index.docs) {
    const { item } = doc;
    if (excludeIds.has(item.id)) continue;
    if (item.expiresAt !== null && !(Date.parse(item.expiresAt) > context.nowMs)) continue;
    const scope = scopeFactor(item, context);
    if (scope === null) continue;
    let bm25 = 0;
    let matched = 0;
    let matchedIdf = 0;
    let allIdf = 0;
    for (const [term, tf] of doc.tf) {
      const w = idf(index, term);
      allIdf += w;
      if (!terms.has(term)) continue;
      matched += 1;
      matchedIdf += w;
      bm25 += (w * tf * (k.k1 + 1)) / (tf + k.k1 * (1 - k.b + (k.b * doc.length) / index.avgdl));
    }
    if (bm25 <= 0 || allIdf <= 0 || matched < Math.min(gate.minMatchedTerms, doc.tf.size)) continue;
    const coverage = round6(matchedIdf / allIdf);
    if (coverage < gate.coverageMin) continue;
    const timeMs = itemTimeMs(item);
    const ageDays = timeMs === null ? 0 : Math.max(0, (context.nowMs - timeMs) / DAY_MS);
    const time = k.timeFloor + (1 - k.timeFloor) * Math.pow(0.5, ageDays / k.halfLifeDays);
    const confidence = k.confidenceFloor + (1 - k.confidenceFloor) * Math.min(1, Math.max(0, item.confidence));
    const pinned = item.pinned ? k.pinnedFactor : 1;
    hits.push({
      id: item.id,
      text: item.content,
      date: timeMs === null ? null : utcDate(timeMs),
      score: round6(bm25 * scope * pinned * time * confidence),
      coverage,
    });
  }
  hits.sort((a, b) => (b.score !== a.score ? b.score - a.score : a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return hits.slice(0, k.topK);
}

function sameScope(a: MemoryItem, b: MemoryItem): boolean {
  return a.scope.type === b.scope.type && (a.scope.id?.toLowerCase() ?? null) === (b.scope.id?.toLowerCase() ?? null);
}

/**
 * The active L3 item a newly saved one conflicts with: same kind and scope, token-set Jaccard in
 * [conflictJaccardMin, 1). Equal token sets are a duplicate, not a conflict. Highest Jaccard wins, then id.
 */
export function memoryRecallConflict(saved: MemoryItem, items: readonly MemoryItem[]): string | null {
  const mine = new Set(memoryRecallTokens(saved.content));
  if (mine.size === 0) return null;
  let best: { id: string; jaccard: number } | null = null;
  for (const other of items) {
    if (other.id === saved.id || other.layer !== 'episodic' || other.status !== 'active') continue;
    if (other.kind !== saved.kind || !sameScope(saved, other)) continue;
    const theirs = new Set(memoryRecallTokens(other.content));
    let shared = 0;
    for (const t of mine) if (theirs.has(t)) shared++;
    const union = mine.size + theirs.size - shared;
    const jaccard = union === 0 ? 0 : round6(shared / union);
    if (jaccard < MEMORY_RECALL_CONSTANTS.conflictJaccardMin || jaccard >= 1) continue;
    if (best === null || jaccard > best.jaccard || (jaccard === best.jaccard && other.id < best.id)) {
      best = { id: other.id, jaccard };
    }
  }
  return best?.id ?? null;
}

export type MemoryRecallResolution = 'useNew' | 'keepBoth' | 'useOld';

export interface MemoryRecallPatch {
  readonly id: string;
  readonly status: 'active' | 'superseded';
  readonly conflictGroupId: null;
  readonly supersedes: string[];
}

/** The two writes that settle a conflicted pair; the repository bumps revision / mutationId as for any edit. */
export function resolveMemoryRecallConflict(
  newer: MemoryItem,
  older: MemoryItem,
  resolution: MemoryRecallResolution,
): [MemoryRecallPatch, MemoryRecallPatch] {
  const keep = (m: MemoryItem, extra: string[] = []): MemoryRecallPatch => ({
    id: m.id,
    status: 'active',
    conflictGroupId: null,
    supersedes: [...m.supersedes, ...extra.filter((id) => !m.supersedes.includes(id))],
  });
  const drop = (m: MemoryItem): MemoryRecallPatch => ({ id: m.id, status: 'superseded', conflictGroupId: null, supersedes: [...m.supersedes] });
  switch (resolution) {
    case 'useNew':
      return [keep(newer, [older.id]), drop(older)];
    case 'useOld':
      return [drop(newer), keep(older)];
    case 'keepBoth':
      return [keep(newer), keep(older)];
  }
}
