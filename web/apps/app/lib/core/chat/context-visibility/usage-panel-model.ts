import type { BreakerMode } from '@oriveo/core/context/compactor';
import type { EstimateBasis } from '@oriveo/core/context/budget';
import type { ContextUsageSummary, UsageOmitted, UsageSegments } from './usage-summary';

/*
 * Pure value functions for the context panel and the settings usage row; no UI and no copy.
 */

/* ── Buttons ──────────────────────────────────────────────── */

export interface PanelButtonsInput {
  /** The session has a latest valid checkpoint. */
  hasCheckpoint: boolean;
  /** Condensing is in progress (manual or AI summary). */
  compacting: boolean;
  /** Sending / generating. */
  sending: boolean;
}

export interface PanelButtons {
  /** [Condense context] is always shown; disabled while condensing or sending. */
  compact: { disabled: boolean };
  /** [Start new chat with summary] only when a checkpoint exists. */
  newChatWithSummary: boolean;
  /** [Clear condensed summary] only when a checkpoint exists. */
  clear: boolean;
}

export function panelButtonsOf(input: PanelButtonsInput): PanelButtons {
  return {
    compact: { disabled: input.compacting || input.sending },
    newChatWithSummary: input.hasCheckpoint,
    clear: input.hasCheckpoint,
  };
}

/** Circuit-breaker downgrade (fallback only) shows breaker_paused + [Retry]. */
export function breakerRetryShown(mode: BreakerMode): boolean {
  return mode === 'fallbackOnly';
}

/* ── Ring body ────────────────────────────────────────────── */

export type PanelHintKey = 'hintWindowUnknown' | 'hintCompacted' | 'hintEmpty';

export type PanelBody =
  | { kind: 'ring'; percent: number; about: boolean; basis: EstimateBasis }
  | { kind: 'unavailable'; hint: PanelHintKey };

/** percent and never_observed draw the segmented ring (estimates show "about"); the rest show a dashed circle + hint. */
export function panelBodyOf(summary: ContextUsageSummary | null): PanelBody {
  if (summary?.display === 'percent' && summary.percent !== null && summary.basis) {
    return { kind: 'ring', percent: summary.percent, about: summary.basis === 'estimated', basis: summary.basis };
  }
  if (summary?.reason === 'never_observed' && summary.estimatedPercent !== null) {
    return { kind: 'ring', percent: summary.estimatedPercent, about: true, basis: summary.basis ?? 'estimated' };
  }
  if (summary?.reason === 'window_unknown') return { kind: 'unavailable', hint: 'hintWindowUnknown' };
  if (summary?.reason === 'compacted_since') return { kind: 'unavailable', hint: 'hintCompacted' };
  if (summary?.reason === 'cleared_since') return { kind: 'unavailable', hint: 'hintEmpty' };
  return { kind: 'unavailable', hint: 'hintEmpty' };
}

/* ── Legend and segments ──────────────────────────────────── */

export type UsageSegmentKind = keyof UsageSegments;

export interface LegendItem {
  kind: UsageSegmentKind;
  tokens: number;
}

const LEGEND_ORDER: readonly UsageSegmentKind[] = ['conversation', 'library', 'summary', 'instructions', 'memory', 'free'];
const ALWAYS_LISTED: ReadonlySet<UsageSegmentKind> = new Set(['conversation', 'free']);

/** The legend lists only segments > 0; conversation and free space are always listed. */
export function panelLegendOf(segments: UsageSegments | null): LegendItem[] {
  if (!segments) return [];
  return LEGEND_ORDER.filter((kind) => ALWAYS_LISTED.has(kind) || segments[kind] > 0).map((kind) => ({
    kind,
    tokens: segments[kind],
  }));
}

export interface RingArc {
  kind: Exclude<UsageSegmentKind, 'free'>;
  /** Start offset as a fraction of the full ring [0,1]. */
  start: number;
  /** Length as a fraction of the full ring [0,1]. */
  length: number;
}

/** Position of each used segment on the full ring; full ring = max(B, used total), free space is the base track. */
export function panelArcsOf(segments: UsageSegments | null, B: number | null): RingArc[] {
  if (!segments || !B || B <= 0) return [];
  const used = LEGEND_ORDER.filter((kind) => kind !== 'free').map((kind) => ({
    kind: kind as RingArc['kind'],
    tokens: segments[kind],
  }));
  const total = Math.max(B, used.reduce((sum, item) => sum + item.tokens, 0));
  const arcs: RingArc[] = [];
  let start = 0;
  for (const item of used) {
    if (item.tokens <= 0) continue;
    const length = item.tokens / total;
    arcs.push({ kind: item.kind, start, length });
    start += length;
  }
  return arcs;
}

export type OmittedKind = keyof UsageOmitted;

/** One row per category > 0. */
export function omittedRowsOf(omitted: UsageOmitted | null): { kind: OmittedKind; count: number }[] {
  if (!omitted) return [];
  return (['notes', 'knowledge', 'memory'] as const)
    .filter((kind) => omitted[kind] > 0)
    .map((kind) => ({ kind, count: omitted[kind] }));
}

/* ── Settings sheet usage row ─────────────────────────────── */

export type SettingsUsageValue =
  | { key: 'percent'; percent: number }
  | { key: 'aboutPercent'; percent: number }
  | { key: 'unavailable' };

/** Value "N%" / about_percent / unavailable, same basis as the panel center. */
export function settingsUsageValueOf(summary: ContextUsageSummary | null): SettingsUsageValue {
  const body = panelBodyOf(summary);
  if (body.kind === 'unavailable') return { key: 'unavailable' };
  return body.about ? { key: 'aboutPercent', percent: body.percent } : { key: 'percent', percent: body.percent };
}
