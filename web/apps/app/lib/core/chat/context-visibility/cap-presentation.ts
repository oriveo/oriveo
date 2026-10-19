/**
 * Context cap UI presentation.
 * Spec: shared/context-contracts/context-cap-presentation.v1.json — the fixture `rules` text is the algorithm.
 * B / U / limitedBy come from ContextBudget.window, slider stops from ContextBudget.capTicks.
 */
import type { AIModel, AppPreference, Conversation, Provider } from '@oriveo/shared';
import {
  type BudgetCapOption,
  type BudgetLimitedBy,
  CONTEXT_BUDGET_CONSTANTS,
  ContextBudget,
  type MaxOutputSources,
  parseBudgetCap,
  type WindowKind,
} from '@oriveo/core/context/budget';
import { COMPACT_NUMBER_LOCALES, resolveCompactLocale } from '@oriveo/core/context/compact-number';
import { formatCompactCount } from '../context-compaction/context-compaction-presentation';
import { resolveContextDefaultCap } from '../../context-cap-preferences';
import { resolveCatalogModel } from '../../metadata/metadata-client';
import { windowOf } from '../context-pipeline/chat-context';

/** Starting point of the custom slider when nothing else is known. */
const CUSTOM_START_FALLBACK = 128000;
type Translate = (key: string, values?: Record<string, string>) => string;

const FSI = '\u2068';
const PDI = '\u2069';

export interface CapWindowInput {
  W: number | null;
  windowKind: WindowKind;
  maxOutput: MaxOutputSources;
  priceLineTokens: number | null;
  /** null = the conversation follows the global default. */
  conversationCap: BudgetCapOption | null;
  globalCap: BudgetCapOption;
}

export interface CapBound {
  B: number | null;
  limitedBy: BudgetLimitedBy | null;
}

export type CapPickerSelection = 'follow' | 'auto' | 'unlimited' | 'custom';

export type CustomCapHint =
  | { kind: 'none'; gap: null }
  | { kind: 'over'; gap: null }
  | { kind: 'at'; gap: null }
  | { kind: 'under'; gap: number };

export interface CapPickerModel {
  selected: CapPickerSelection;
  effective: CapBound;
  auto: CapBound;
  unlimited: CapBound;
  ticks: number[];
  customStart: number;
  sliderIndex: number;
  priceLineTickIndex: number | null;
  unlimitedCrossesPriceLine: boolean;
  customHint: CustomCapHint;
}

export interface CapCommitResult {
  value: number;
  adjusted: boolean;
  restored: boolean;
}

export interface CapPricingSide {
  prompt?: number | null;
  completion?: number | null;
}

export interface CapPanelInput extends CapWindowInput {
  used: number;
  /** Per-million prices below ({base}) and above ({long}) the price line. */
  pricing?: { base?: CapPricingSide | null; long?: CapPricingSide | null } | null;
}

export type CapWindowLine = 'unknown' | 'window' | 'windowPriceLine' | 'aboveLine';

export interface CapPanelModel {
  /** null = window unknown with auto / unlimited: show the option name instead. */
  capValue: number | null;
  limitedByModel: boolean;
  actual: number | null;
  windowLine: CapWindowLine;
  priceLineDistance: number | null;
  /** Long-context price multipliers in tenths (20 = ×2); only sides above ×1 are listed. */
  multiplier: { input: number | null; output: number | null } | null;
}

export type SettingsCapSelection = 'auto' | 'unlimited' | 'custom';

export interface SettingsCapModel {
  selected: SettingsCapSelection;
  customPrefill: number;
}

function budgetOf(input: CapWindowInput, cap: BudgetCapOption) {
  return ContextBudget.window({
    W: input.W,
    windowKind: input.windowKind,
    maxOutput: input.maxOutput,
    budgetCap: cap,
    priceLineTokens: input.priceLineTokens,
  });
}

function boundOf(input: CapWindowInput, cap: BudgetCapOption): CapBound {
  const budget = budgetOf(input, cap);
  return { B: budget.B, limitedBy: budget.limitedBy };
}

function priceLineOf(input: CapWindowInput): number | null {
  const T = input.priceLineTokens;
  return typeof T === 'number' && Number.isSafeInteger(T) ? T : null;
}

/** Index of the tick nearest to value; ties go to the lower tick. */
function nearestTickIndex(ticks: number[], value: number): number {
  let best = 0;
  for (let i = 1; i < ticks.length; i++) {
    if (Math.abs(ticks[i] - value) < Math.abs(ticks[best] - value)) best = i;
  }
  return best;
}

/** Per-conversation cap picker: options, slider and price-line hint. */
export function capPickerOf(input: CapWindowInput): CapPickerModel {
  const conversationCap = input.conversationCap;
  const selected: CapPickerSelection =
    conversationCap === null ? 'follow' : typeof conversationCap === 'number' ? 'custom' : conversationCap;
  const effectiveBudget = budgetOf(input, conversationCap ?? input.globalCap);
  const effective = { B: effectiveBudget.B, limitedBy: effectiveBudget.limitedBy };
  const U = effectiveBudget.U;
  const T = priceLineOf(input);
  const ticks = ContextBudget.capTicks(U, T);
  const customStart =
    typeof conversationCap === 'number'
      ? (boundOf(input, conversationCap).B ?? CUSTOM_START_FALLBACK)
      : (effective.B ?? CUSTOM_START_FALLBACK);
  const tickIndex = T === null ? -1 : ticks.indexOf(T);
  let customHint: CustomCapHint;
  if (T === null) customHint = { kind: 'none', gap: null };
  else if (customStart > T) customHint = { kind: 'over', gap: null };
  else if (customStart === T) customHint = { kind: 'at', gap: null };
  else customHint = { kind: 'under', gap: T - customStart };
  return {
    selected,
    effective,
    auto: boundOf(input, 'auto'),
    unlimited: boundOf(input, 'unlimited'),
    ticks,
    customStart,
    sliderIndex: nearestTickIndex(ticks, customStart),
    priceLineTickIndex: tickIndex < 0 ? null : tickIndex,
    unlimitedCrossesPriceLine: U !== null && T !== null && U > T,
    customHint,
  };
}

// Unicode White_Space plus the grouping separators , . ' \u2019 _
const COMMIT_STRIP = /[\t\n\v\f\r \u0085\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000,.'\u2019_]/g;
const MAX_COMMIT_DIGITS = 10;

/** Commits the typed custom number; unparseable text restores previous. */
export function commitCustomCap(text: string, U: number | null, previous: number): CapCommitResult {
  const digits = text.replace(COMMIT_STRIP, '');
  if (!/^[0-9]+$/.test(digits)) return { value: previous, adjusted: false, restored: true };
  const max = CONTEXT_BUDGET_CONSTANTS.customCapMax;
  // Digits are counted after dropping leading zeros ("00000000064000" is 64000).
  const saturated = digits.replace(/^0+/, '').length > MAX_COMMIT_DIGITS;
  const n = saturated ? max : Number(digits);
  const value = Math.min(Math.max(n, CONTEXT_BUDGET_CONSTANTS.customCapMin), U ?? max);
  return { value, adjusted: saturated || value !== n, restored: false };
}

function multiplierTenths(base: number | null | undefined, long: number | null | undefined): number | null {
  if (typeof base !== 'number' || !Number.isFinite(base) || base <= 0) return null;
  if (typeof long !== 'number' || !Number.isFinite(long)) return null;
  const tenths = Math.round((long / base) * 10);
  return tenths > 10 ? tenths : null;
}

/** Long-context multipliers in tenths (panel rule, shared with the U8 confirm); null when no side is above ×1. */
export function capMultiplierOf(pricing: CapPanelInput['pricing']): CapPanelModel['multiplier'] {
  if (!pricing) return null;
  const inputSide = multiplierTenths(pricing.base?.prompt, pricing.long?.prompt);
  const outputSide = multiplierTenths(pricing.base?.completion, pricing.long?.completion);
  return inputSide !== null || outputSide !== null ? { input: inputSide, output: outputSide } : null;
}

/** Effective B / limitedBy for the conversation cap (null = follow the global default). */
export function effectiveCapBoundOf(input: CapWindowInput): CapBound {
  return boundOf(input, input.conversationCap ?? input.globalCap);
}

/** Context panel cap row and window row. */
export function capPanelOf(input: CapPanelInput): CapPanelModel {
  const cap = input.conversationCap ?? input.globalCap;
  const budget = budgetOf(input, cap);
  const limitedByModel = typeof cap === 'number' && budget.U !== null && cap > budget.U;
  const T = priceLineOf(input);
  let windowLine: CapWindowLine;
  if (budget.U === null) windowLine = 'unknown';
  else if (T === null) windowLine = 'window';
  else if (budget.B === null || T >= budget.B) windowLine = 'windowPriceLine';
  else windowLine = 'aboveLine';
  const priceLineDistance = windowLine === 'aboveLine' && T !== null ? Math.max(T - input.used, 0) : null;
  const multiplier = capMultiplierOf(input.pricing);
  return {
    capValue: budget.B,
    limitedByModel,
    actual: limitedByModel ? budget.B : null,
    windowLine,
    priceLineDistance,
    multiplier,
  };
}

/**
 * Production assembly of the cap presentation input: the same window factory as the send path
 * (windowOf: W / O / T from the model, then the decoded catalog), conversation cap (null = follow)
 * and the global default. Pricing is the decoded catalog price, only where the price line applies.
 * userMaxOutput is the panel "max output" value when known (null otherwise).
 */
export function capPresentationInputOf(input: {
  conversation: Pick<Conversation, 'contextCap'> | null | undefined;
  preferences: Pick<AppPreference, 'contextDefaultCap'>;
  provider: Provider | null | undefined;
  model: AIModel | null | undefined;
  userMaxOutput?: number | null;
}): Omit<CapPanelInput, 'used'> | null {
  const { provider, model } = input;
  if (!provider || !model) return null;
  const globalCap = resolveContextDefaultCap(input.preferences);
  const window = windowOf(provider, model, input.userMaxOutput ?? null, globalCap);
  return {
    W: window.W,
    windowKind: window.windowKind,
    maxOutput: window.maxOutput,
    priceLineTokens: window.priceLineTokens ?? null,
    conversationCap: input.conversation?.contextCap ?? null,
    globalCap,
    pricing: capPricingOf(provider, model, window.priceLineTokens ?? null),
  };
}

/** Decoded catalog price ({base} / {long}), only where the price line applies (T known). */
export function capPricingOf(
  provider: Provider,
  model: AIModel,
  priceLineTokens: number | null,
): CapPanelInput['pricing'] {
  if (priceLineTokens == null) return null;
  const catalogPricing = resolveCatalogModel(model.id, provider.kind)?.pricing;
  const long = catalogPricing?.longContext;
  if (!catalogPricing || !long) return null;
  const perM = (perToken: number | null | undefined) => (typeof perToken === 'number' ? perToken * 1_000_000 : null);
  return {
    base: { prompt: perM(catalogPricing.promptPerToken), completion: perM(catalogPricing.completionPerToken) },
    long: { prompt: long.promptPerMToken, completion: long.completionPerMToken },
  };
}

/** Multiplier tenths as text with the locale's compact-table decimal separator (20 -> "2", 15 -> "1.5"). */
export function multiplierText(tenths: number, locale: string): string {
  const int = Math.floor(tenths / 10);
  const frac = tenths % 10;
  if (frac === 0) return String(int);
  return `${int}${COMPACT_NUMBER_LOCALES[resolveCompactLocale(locale)].decimal}${frac}`;
}

/** "{mult}" phrase for the window row; null when no side is above ×1. */
export function multiplierPhrase(
  multiplier: CapPanelModel['multiplier'],
  locale: string,
  tCap: Translate,
): string | null {
  if (!multiplier) return null;
  const { input, output } = multiplier;
  if (input !== null && output !== null) {
    if (input === output) return tCap('multBoth', { a: multiplierText(input, locale) });
    return tCap('multSplit', { a: multiplierText(input, locale), b: multiplierText(output, locale) });
  }
  if (input !== null) return tCap('multInput', { a: multiplierText(input, locale) });
  if (output !== null) return tCap('multOutput', { b: multiplierText(output, locale) });
  return null;
}

/** Settings › Context default cap, read from the raw stored value. */
export function settingsCapOf(stored: unknown): SettingsCapModel {
  const cap = parseBudgetCap(stored) ?? 'auto';
  if (typeof cap === 'number') return { selected: 'custom', customPrefill: cap };
  return { selected: cap, customPrefill: CONTEXT_BUDGET_CONSTANTS.autoCapDefault };
}

/** Compact token count isolated with FSI…PDI for mixed-direction text. */
export function isolatedCompactCount(value: number, locale: string): string {
  return `${FSI}${formatCompactCount(value, locale)}${PDI}`;
}

/** Option name for auto / unlimited, isolated compact number for a custom cap. */
export function capOptionText(
  cap: BudgetCapOption,
  locale: string,
  labels: { auto: string; unlimited: string },
): string {
  if (typeof cap === 'number') return isolatedCompactCount(cap, locale);
  return cap === 'unlimited' ? labels.unlimited : labels.auto;
}

/**
 * Settings root "Context" row value: "{cap} · {mode}".
 * tContext = pages.settings.context, tCap = pages.chat.contextCap.
 */
export function contextRowValueText(
  prefs: Pick<AppPreference, 'contextDefaultCap' | 'contextAISummaryEnabled'>,
  locale: string,
  tContext: Translate,
  tCap: Translate,
): string {
  const cap = capOptionText(resolveContextDefaultCap(prefs), locale, {
    auto: tCap('auto'),
    unlimited: tCap('unlimited'),
  });
  const mode = prefs.contextAISummaryEnabled === true ? tContext('modeAi') : tContext('rowValueFallback');
  return tContext('rowValue', { cap, mode });
}
