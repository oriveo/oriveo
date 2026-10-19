import { ContextBudget, type EstimateBasis, type RingTone } from '@oriveo/core/context/budget';

/*
 * Usage summary pure functions (spec shared/context-contracts/usage.v1.json rules).
 * Input: this session's ledger manifests (createdAt ascending, latest last) + latest valid checkpoint; output: one answer shared by the ring and the panel.
 */

export interface UsageManifestSegmentInput {
  kind: string;
  tokens: number;
  omitted?: number;
}

export interface UsageManifestInput {
  createdAt: number;
  B: number | null;
  W: number | null;
  estimatedInput: number;
  observedInput?: number | null;
  stopReason?: string | null;
  /** The checkpoint applied by that request; if set while no valid checkpoint exists now, the condensed summary was cleared afterwards. */
  checkpointId?: string | null;
  segments: readonly UsageManifestSegmentInput[];
}

export interface UsageCheckpointInput {
  count: number;
  latestCreatedAt: number;
  /** The checkpoint text is estimated the same way as the separator line (estimateMessage). */
  latestSummaryTokens: number;
}

export type UsageDisplay = 'percent' | 'unavailable' | 'none';
export type UsageUnavailableReason = 'never_observed' | 'window_unknown' | 'compacted_since' | 'cleared_since';

export interface UsageSegments {
  conversation: number;
  library: number;
  summary: number;
  instructions: number;
  memory: number;
  free: number;
}

export interface UsageOmitted {
  notes: number;
  knowledge: number;
  memory: number;
}

export interface UsageRing {
  label: string;
  tone: RingTone;
}

export interface ContextUsageSummary {
  display: UsageDisplay;
  reason: UsageUnavailableReason | null;
  percent: number | null;
  estimatedPercent: number | null;
  tone: RingTone | null;
  ring: UsageRing | null;
  basis: EstimateBasis | null;
  used: number | null;
  B: number | null;
  W: number | null;
  segments: UsageSegments | null;
  omitted: UsageOmitted | null;
}

const SEGMENT_GROUPS = {
  instructions: ['skill', 'instructions', 'standingInstructions', 'purposeSystem', 'toolSafety'],
  memory: ['memory'],
  library: ['notes', 'knowledge'],
} as const;

const OVERFLOW_STOP_REASON = 'context_window_exceeded';

const EMPTY: ContextUsageSummary = {
  display: 'none',
  reason: null,
  percent: null,
  estimatedPercent: null,
  tone: null,
  ring: null,
  basis: null,
  used: null,
  B: null,
  W: null,
  segments: null,
  omitted: null,
};

function hasObserved(manifest: UsageManifestInput): manifest is UsageManifestInput & { observedInput: number } {
  return typeof manifest.observedInput === 'number';
}

function sumGroup(segments: readonly UsageManifestSegmentInput[], kinds: readonly string[]): number {
  return segments.reduce((sum, segment) => (kinds.includes(segment.kind) ? sum + segment.tokens : sum), 0);
}

function omittedOf(segments: readonly UsageManifestSegmentInput[], kind: string): number {
  return segments.reduce((sum, segment) => (segment.kind === kind ? sum + (segment.omitted ?? 0) : sum), 0);
}

/**
 * current.B: the cap computed for the session's current tier and window (same source as the send path); when omitted the latest manifest's B is used.
 * After a tier change, measured usage is kept and the denominator becomes the computed B; a computed B of null (unknown window) still maps to window_unknown.
 */
export function summarizeContextUsage(
  manifests: readonly UsageManifestInput[],
  checkpoint: UsageCheckpointInput | null,
  current?: { B: number | null },
): ContextUsageSummary {
  const newest = manifests[manifests.length - 1];
  if (!newest) return { ...EMPTY };
  const latest: UsageManifestInput = current ? { ...newest, B: current.B } : newest;
  if (checkpoint && checkpoint.latestCreatedAt > latest.createdAt) {
    return { ...EMPTY, display: 'unavailable', reason: 'compacted_since', B: latest.B, W: latest.W };
  }
  // After clearing the condensed summary, before the next send: the latest measured value carried the deleted checkpoint's size, so it is invalidated.
  if (!checkpoint && latest.checkpointId) {
    return { ...EMPTY, display: 'unavailable', reason: 'cleared_since', B: latest.B, W: latest.W };
  }

  const basis: EstimateBasis = hasObserved(latest) ? 'observed' : 'estimated';
  const used = hasObserved(latest) ? latest.observedInput : latest.estimatedInput;
  const omitted: UsageOmitted = {
    notes: omittedOf(latest.segments, 'notes'),
    knowledge: omittedOf(latest.segments, 'knowledge'),
    memory: omittedOf(latest.segments, 'memory'),
  };
  const base = { basis, used, B: latest.B, W: latest.W, omitted };

  const B = latest.B;
  if (B === null) {
    return { ...EMPTY, ...base, display: 'unavailable', reason: 'window_unknown' };
  }

  const instructions = sumGroup(latest.segments, SEGMENT_GROUPS.instructions);
  const memory = sumGroup(latest.segments, SEGMENT_GROUPS.memory);
  const library = sumGroup(latest.segments, SEGMENT_GROUPS.library);
  const summary = checkpoint ? checkpoint.latestSummaryTokens : 0;
  const segments: UsageSegments = {
    conversation: Math.max(0, used - instructions - memory - library - summary),
    library,
    summary,
    instructions,
    memory,
    free: Math.max(0, B - used),
  };

  const shown = ContextBudget.display({
    windowKnown: true,
    pHat: used,
    B,
    basis,
    observedEver: manifests.some(hasObserved),
    overflowed: latest.stopReason === OVERFLOW_STOP_REASON,
  });
  if (shown.display === 'unavailable') {
    return {
      ...EMPTY,
      ...base,
      display: 'unavailable',
      reason: shown.estimatedPercent === undefined ? 'window_unknown' : 'never_observed',
      estimatedPercent: shown.estimatedPercent ?? null,
      segments: shown.estimatedPercent === undefined ? null : segments,
    };
  }
  const ring: UsageRing =
    shown.tone === 'error' || shown.percent >= 100
      ? { label: '!', tone: 'error' }
      : { label: String(shown.percent), tone: shown.tone };
  return {
    ...base,
    display: 'percent',
    reason: null,
    percent: shown.percent,
    estimatedPercent: null,
    tone: shown.tone,
    ring,
    segments,
  };
}

export type UsageRingA11y = { key: 'ringOverA11y' } | { key: 'ringA11y'; percent: number; limit: number };

export interface UsageRingModel extends UsageRing {
  a11y: UsageRingA11y;
}

/** Ring display model: display≠percent returns null (not shown); "!" announces the over-limit copy, otherwise announces the percentage and cap B. */
export function usageRingOf(summary: ContextUsageSummary): UsageRingModel | null {
  if (summary.display !== 'percent' || !summary.ring || summary.percent === null || summary.B === null) return null;
  const a11y: UsageRingA11y =
    summary.ring.label === '!'
      ? { key: 'ringOverA11y' }
      : { key: 'ringA11y', percent: summary.percent, limit: summary.B };
  return { ...summary.ring, a11y };
}
