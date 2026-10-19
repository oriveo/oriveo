/**
 * Context budget pure functions (context pipeline §5).
 * Spec: shared/context-contracts/budget.v1.json — the fixture `rules` text is the algorithm.
 */

/** Budget cap: "auto" (default), "unlimited", or a custom integer token count. */
export type BudgetCapOption = 'auto' | 'unlimited' | number;

/** Wire / storage form of a cap; parseBudgetCap(budgetCapWire(cap)) === cap. */
export type BudgetCapWire = 'auto' | 'unlimited' | number;

export type BudgetLimitedBy = 'custom' | 'priceLine' | 'autoDefault' | 'window';

export const CONTEXT_BUDGET_CONSTANTS = {
  rho0: 0.5,
  ewmaAlpha: 0.3,
  rhoClamp: [0.15, 0.7] as const,
  safetyFactor: 1.15,
  minSamples: 3,
  overflowMissFactor: 1.25,
  messageOverheadTokens: 4,
  minKnownWindow: 1024,
  defaultMaxOutput: 8192,
  budgetCapOptions: ['auto', 'unlimited'] as const,
  budgetCapDefault: 'auto' as BudgetCapOption,
  customCapMin: 32000,
  // 2^31 - 1: consistent with Kotlin Int / Swift Int.
  customCapMax: 2147483647,
  autoCapDefault: 256000,
  priceLineCapMin: 64000,
  capTickLadder: [32000, 64000, 128000, 256000, 384000, 512000, 768000, 1000000, 1500000, 2000000] as const,
};

/**
 * Parses a stored / wire cap value. Only the exact strings "auto" / "unlimited" and integers in
 * [customCapMin, customCapMax] are accepted; anything else (legacy "64k" keys, numeric strings,
 * fractions, booleans, null) returns null and the caller treats the value as absent.
 */
export function parseBudgetCap(raw: unknown): BudgetCapOption | null {
  if (raw === 'auto' || raw === 'unlimited') return raw;
  if (
    typeof raw === 'number' &&
    Number.isInteger(raw) &&
    raw >= CONTEXT_BUDGET_CONSTANTS.customCapMin &&
    raw <= CONTEXT_BUDGET_CONSTANTS.customCapMax
  ) {
    return raw;
  }
  return null;
}

export function budgetCapWire(cap: BudgetCapOption): BudgetCapWire {
  return cap;
}

export type WindowKind = 'total' | 'inputOnly';

export interface MaxOutputSources {
  user?: number | null;
  recipe?: number | null;
  model?: number | null;
}

export interface WindowBudgetInput {
  W: number | null;
  windowKind: WindowKind;
  maxOutput: MaxOutputSources;
  budgetCap: BudgetCapOption;
  /** Provider price line (tokens); only caps auto when >= priceLineCapMin. */
  priceLineTokens?: number | null;
}

export interface DerivedBudget {
  preCompactAt: number;
  sendCompactAt: number;
  compactTargetMax: number;
  reminderAt: number;
  tail: number;
  userMessagesMax: number;
  summaryMax: number;
  systemMax: number;
  recallMax: number;
}

export interface ContextWindowBudget {
  known: boolean;
  W: number | null;
  O: number;
  R: number | null;
  U: number | null;
  B: number | null;
  /** The bound that set B; null when B is null. */
  limitedBy: BudgetLimitedBy | null;
  oWire: number;
  derived: DerivedBudget | null;
  proactiveCompaction: boolean;
}

export type EstimateBasis = 'observed' | 'estimated';

export interface PHatInput {
  observedPrevious: number | null;
  estDynamicPrevious: number;
  estAnswerPrevious: number;
  estNewMessages: number[];
  estDynamicNow: number;
  compactedSincePrevious: boolean;
  estimatedFull: number;
}

export interface PHatResult {
  pHat: number;
  basis: EstimateBasis;
}

export interface DisplayInput {
  windowKnown: boolean;
  pHat: number;
  B: number | null;
  basis: EstimateBasis;
  observedEver: boolean;
  overflowed: boolean;
}

export type RingTone = 'neutral' | 'warm' | 'error';

export type RingDisplay =
  | { display: 'percent'; percent: number; tone: RingTone }
  | { display: 'unavailable'; percent: null; tone: null; estimatedPercent?: number };

const WARM_PERCENT = 70;

function isPositive(value: number | null | undefined): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

/** Integer floor division (b > 0): remainder is subtracted first so the quotient is exact. */
function floorDiv(a: number, b: number): number {
  const remainder = a % b;
  const quotient = (a - remainder) / b;
  return remainder < 0 ? quotient - 1 : quotient;
}

/** Integer ceil division (b > 0). */
function ceilDiv(a: number, b: number): number {
  return -floorDiv(-a, b);
}

/** floor(B * percent / 100) in integer arithmetic so thresholds never drift by float error. */
function percentOf(value: number, percent: number): number {
  return floorDiv(value * percent, 100);
}

function resolveOutput(maxOutput: MaxOutputSources): number {
  const candidates = [maxOutput.user, maxOutput.recipe, maxOutput.model];
  return candidates.find(isPositive) ?? CONTEXT_BUDGET_CONSTANTS.defaultMaxOutput;
}

function derive(B: number): DerivedBudget {
  return {
    preCompactAt: percentOf(B, 75),
    sendCompactAt: percentOf(B, 90),
    compactTargetMax: percentOf(B, 50),
    reminderAt: percentOf(B, 30),
    tail: Math.min(48000, Math.max(4000, percentOf(B, 25))),
    userMessagesMax: Math.min(16000, percentOf(B, 10)),
    summaryMax: Math.min(4000, Math.max(1000, percentOf(B, 5))),
    systemMax: Math.min(percentOf(B, 25), 32000),
    recallMax: percentOf(B, 7),
  };
}

/** Custom cap clamped into [customCapMin, customCapMax]; non-safe-integer numbers fall back to auto (null). */
function customCapOf(cap: BudgetCapOption): number | null {
  if (typeof cap !== 'number' || !Number.isSafeInteger(cap)) return null;
  return Math.min(Math.max(cap, CONTEXT_BUDGET_CONSTANTS.customCapMin), CONTEXT_BUDGET_CONSTANTS.customCapMax);
}

/** Non-integer price lines are treated as absent. */
function priceLineOf(priceLineTokens: number | null | undefined): number | null {
  return typeof priceLineTokens === 'number' && Number.isSafeInteger(priceLineTokens) ? priceLineTokens : null;
}

/** auto: min(U, autoCapDefault, T'); ties prefer priceLine over autoDefault over window. */
function autoBound(U: number, rawPriceLine: number | null | undefined): { B: number; limitedBy: BudgetLimitedBy } {
  const priceLineTokens = priceLineOf(rawPriceLine);
  let B = U;
  let limitedBy: BudgetLimitedBy = 'window';
  if (CONTEXT_BUDGET_CONSTANTS.autoCapDefault <= B) {
    B = CONTEXT_BUDGET_CONSTANTS.autoCapDefault;
    limitedBy = 'autoDefault';
  }
  if (
    priceLineTokens !== null &&
    priceLineTokens >= CONTEXT_BUDGET_CONSTANTS.priceLineCapMin &&
    priceLineTokens <= B
  ) {
    B = priceLineTokens;
    limitedBy = 'priceLine';
  }
  return { B, limitedBy };
}

function window(input: WindowBudgetInput): ContextWindowBudget {
  const O = resolveOutput(input.maxOutput);
  const W = input.W;
  // A tier that is neither 'unlimited' nor a safe integer is always treated as auto.
  const custom = customCapOf(input.budgetCap);
  const unlimited = input.budgetCap === 'unlimited';
  if (W === null || !Number.isFinite(W) || W < CONTEXT_BUDGET_CONSTANTS.minKnownWindow) {
    if (custom !== null) {
      const B = custom;
      return {
        known: false,
        W: null,
        O,
        R: null,
        U: null,
        B,
        limitedBy: 'custom',
        oWire: O,
        derived: derive(B),
        proactiveCompaction: true,
      };
    }
    return {
      known: false,
      W: null,
      O,
      R: null,
      U: null,
      B: null,
      limitedBy: null,
      oWire: O,
      derived: null,
      proactiveCompaction: false,
    };
  }
  let R: number;
  let oWire: number;
  if (input.windowKind === 'inputOnly') {
    R = 0;
    oWire = O;
  } else {
    R = Math.min(Math.max(O, ceilDiv(W, 10)), floorDiv(W, 2));
    oWire = Math.min(O, R);
  }
  const U = W - R;
  let B: number;
  let limitedBy: BudgetLimitedBy;
  if (custom !== null) {
    B = Math.min(custom, U);
    limitedBy = custom <= U ? 'custom' : 'window';
  } else if (unlimited) {
    B = U;
    limitedBy = 'window';
  } else {
    ({ B, limitedBy } = autoBound(U, input.priceLineTokens));
  }
  return { known: true, W, O, R, U, B, limitedBy, oWire, derived: derive(B), proactiveCompaction: true };
}

/**
 * Slider stops: sorted unique (capTickLadder ∪ {priceLineTokens when >= customCapMin}) ∩ [customCapMin, U],
 * plus U; U unknown → no upper bound and U is not added; U < customCapMin → [U].
 */
function capTicks(U: number | null, rawPriceLine: number | null): number[] {
  const priceLineTokens = priceLineOf(rawPriceLine);
  const min = CONTEXT_BUDGET_CONSTANTS.customCapMin;
  if (U !== null && U < min) return [U];
  const stops = new Set<number>(CONTEXT_BUDGET_CONSTANTS.capTickLadder);
  if (priceLineTokens !== null && priceLineTokens >= min) stops.add(priceLineTokens);
  if (U !== null) stops.add(U);
  return [...stops].filter((tick) => tick >= min && (U === null || tick <= U)).sort((a, b) => a - b);
}

// Counts UTF-8 bytes without allocating; lone surrogates count as U+FFFD (3 bytes), same as TextEncoder.
function utf8Bytes(text: string): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 0x80) bytes += 1;
    else if (code < 0x800) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4;
        i++;
      } else bytes += 3;
    } else bytes += 3;
  }
  return bytes;
}

function estimateText(text: string, rhoHi: number): number {
  return Math.ceil(utf8Bytes(text) * rhoHi);
}

function estimateMessage(text: string, rhoHi: number): number {
  return estimateText(text, rhoHi) + CONTEXT_BUDGET_CONSTANTS.messageOverheadTokens;
}

function pHat(input: PHatInput): PHatResult {
  if (input.observedPrevious !== null && !input.compactedSincePrevious) {
    const newMessages = input.estNewMessages.reduce((sum, tokens) => sum + tokens, 0);
    return {
      pHat:
        input.observedPrevious -
        input.estDynamicPrevious +
        input.estAnswerPrevious +
        newMessages +
        input.estDynamicNow,
      basis: 'observed',
    };
  }
  return { pHat: input.estimatedFull, basis: 'estimated' };
}

function display(input: DisplayInput): RingDisplay {
  if (!input.windowKnown || input.B === null || input.B <= 0) {
    return { display: 'unavailable', percent: null, tone: null };
  }
  const percent = ceilDiv(100 * input.pHat, input.B);
  if (!input.observedEver) {
    return { display: 'unavailable', percent: null, tone: null, estimatedPercent: percent };
  }
  const tone: RingTone = input.overflowed ? 'error' : percent >= WARM_PERCENT ? 'warm' : 'neutral';
  return { display: 'percent', percent, tone };
}

export const ContextBudget = {
  constants: CONTEXT_BUDGET_CONSTANTS,
  window,
  capTicks,
  derive,
  utf8Bytes,
  estimateText,
  estimateMessage,
  pHat,
  display,
};
