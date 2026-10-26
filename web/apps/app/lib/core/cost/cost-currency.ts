/**
 * Cost currency (contract "model catalog and capability truth" §5.7 "cost result currency";
 * fixture provider-pricing/cost-currency.v1.json).
 *
 * - Accounting: a message's estimatedCost holds only the USD part; the single non-USD part
 *   goes into the nullable nonUsdCost {currencyCode (ISO 4217, upper case), amount, costSource}
 *   without any currency conversion.
 * - Display: parts are joined with ' + ', USD first; USD keeps formatCost's '$' style and precision,
 *   other currencies use Intl currency formatting (UI language, standard symbol), and each
 *   part applies the same digit rules according to its own amount.
 */
import type { CostSource } from '../chat/cost';
import { COST_EPSILON, costFractionDigits, formatCost } from '../../utils/format-utils';

const ISO_4217 = /^[A-Z]{3}$/;

/**
 * Normalize a pricing currency: missing / empty / USD → `'USD'`; anything else is upper-cased and must be
 * three letters, otherwise null (currency unavailable, recorded as unknown).
 */
export function normalizeCostCurrency(code: string | null | undefined): string | null {
  if (code == null) return 'USD';
  const upper = code.trim().toUpperCase();
  if (upper === '') return 'USD';
  return ISO_4217.test(upper) ? upper : null;
}

/** A message's non-USD part (nullable). When costSource is 'unknown' the amount is unusable and shows "N/A" rather than 0. */
export interface NonUsdCost {
  currencyCode: string;
  amount: number;
  costSource: CostSource;
}

/** The two parts of a message's cost: estimatedCost holds only USD; nonUsdCost is the single non-USD part (optional). */
export interface MessageCostParts {
  estimatedCost: number;
  nonUsdCost?: NonUsdCost;
}

/**
 * Merge two non-USD parts: if one side is missing take the other; same currency with both amounts usable → add
 * (costSource taken from the first); different currencies or either amount unusable → {first currency, 0, 'unknown'},
 * no addition and no conversion.
 */
export function mergeNonUsdCost(
  first: NonUsdCost | undefined,
  second: NonUsdCost | undefined,
): NonUsdCost | undefined {
  if (!first) return second;
  if (!second) return first;
  if (
    first.currencyCode !== second.currencyCode
    || first.costSource === 'unknown'
    || second.costSource === 'unknown'
  ) {
    return { currencyCode: first.currencyCode, amount: 0, costSource: 'unknown' };
  }
  return { ...first, amount: first.amount + second.amount };
}

/**
 * Append another cost to the same message (continuation / follow-up answer / retrieval cost folded in):
 * the USD part is added into estimatedCost, and the non-USD part is merged via {@link mergeNonUsdCost}.
 * The result always carries a nonUsdCost key (undefined when there is no non-USD part), so spreading it
 * onto a message overwrites any stale value left on the message.
 */
export function addMessageCost(
  base: MessageCostParts | undefined,
  next: MessageCostParts,
): MessageCostParts {
  const estimatedCost = (base?.estimatedCost ?? 0) + next.estimatedCost;
  return { estimatedCost, nonUsdCost: mergeNonUsdCost(base?.nonUsdCost, next.nonUsdCost) };
}

/** Intl.NumberFormat is expensive to construct: cache by locale|currency|digits so every list row reuses one instance. */
const nonUsdFormatters = new Map<string, Intl.NumberFormat>();

function nonUsdFormatter(locale: string, currencyCode: string, digits: number): Intl.NumberFormat {
  const key = `${locale}|${currencyCode}|${digits}`;
  let formatter = nonUsdFormatters.get(key);
  if (!formatter) {
    formatter = new Intl.NumberFormat(locale, {
      style: 'currency',
      currency: currencyCode,
      currencyDisplay: 'symbol',
      minimumFractionDigits: digits,
      maximumFractionDigits: digits,
    });
    nonUsdFormatters.set(key, formatter);
  }
  return formatter;
}

/** One non-USD amount: Intl currency format (standard symbol), digits chosen by formatCost's rules on its own amount; empty string when hidden. */
function formatNonUsdAmount(amount: number, currencyCode: string, locale: string): string {
  const digits = costFractionDigits(amount);
  if (digits === null) return '';
  return nonUsdFormatter(locale, currencyCode, digits).format(amount);
}

/**
 * A message's cost text: the USD part first (identical to formatCost), then the non-USD part;
 * parts with a zero amount or an unavailable amount ({@link notAvailableCostParts}) are omitted.
 * Returns an empty string when everything is omitted, same as formatCost.
 */
export function formatCostParts(
  usd: number,
  nonUsdCost: NonUsdCost | null | undefined,
  locale: string,
): string {
  const totals = nonUsdCost && nonUsdCost.costSource !== 'unknown'
    ? { [nonUsdCost.currencyCode]: nonUsdCost.amount }
    : undefined;
  return formatCostTotals(usd, totals, locale);
}

/** An amount in a single currency (USD uses formatCost's '$' style, others use Intl currency format); empty string when hidden. */
export function formatCostAmount(amount: number, currencyCode: string, locale: string): string {
  return currencyCode === 'USD' ? formatCost(amount) : formatNonUsdAmount(amount, currencyCode, locale);
}

/**
 * The non-USD part of a total: currency code → total in the original currency (same shape as the
 * conversation's nonUsdCostTotals). No cross-currency addition, no conversion; zero-amount currencies
 * are not written; the whole value is omitted when there is no non-USD part.
 */
export type NonUsdCostTotals = Record<string, number>;

/**
 * Add a message's non-USD part to the totals at face value: only parts whose amount is unavailable ('unknown')
 * or non-finite are skipped, with no per-item epsilon check; the caller applies epsilon to the totals
 * ({@link settleNonUsdCostTotals}). Returns a new object and does not mutate the input.
 */
export function addNonUsdCostToTotals(
  totals: NonUsdCostTotals | undefined,
  part: NonUsdCost | null | undefined,
): NonUsdCostTotals | undefined {
  // Only finite parts > 0 are added (negative_parts_not_added).
  if (!part || part.costSource === 'unknown' || !Number.isFinite(part.amount) || part.amount <= 0) return totals;
  return { ...totals, [part.currencyCode]: (totals?.[part.currencyCode] ?? 0) + part.amount };
}

/** Apply epsilon to face-value totals (cost-currency.v1 tiny_parts_summed_before_epsilon): currencies <= COST_EPSILON are not written; omitted when none remain. */
export function settleNonUsdCostTotals(totals: NonUsdCostTotals | undefined): NonUsdCostTotals | undefined {
  let settled: NonUsdCostTotals | undefined;
  for (const [code, amount] of Object.entries(totals ?? {})) {
    if (amount > COST_EPSILON) settled = { ...settled, [code]: amount };
  }
  return settled;
}

/** Add two totals per currency (conversation totals merged into monthly / provider totals); omitted when both are empty. */
export function mergeNonUsdCostTotals(
  first: NonUsdCostTotals | undefined,
  second: NonUsdCostTotals | undefined,
): NonUsdCostTotals | undefined {
  if (!hasNonUsdCostTotals(second)) return hasNonUsdCostTotals(first) ? first : undefined;
  if (!hasNonUsdCostTotals(first)) return second;
  const merged: NonUsdCostTotals = { ...first };
  for (const [code, amount] of Object.entries(second)) {
    if (costFractionDigits(amount) === null) continue;
    merged[code] = (merged[code] ?? 0) + amount;
  }
  return merged;
}

/**
 * Whether two non-USD totals are the same (the single comparison point for conversation totals): compared
 * per currency, differences within COST_EPSILON count as equal; missing, an empty object and zero-amount
 * currencies (e.g. {CNY: 0}) are all equivalent.
 */
export function nonUsdCostTotalsEqual(
  a: NonUsdCostTotals | null | undefined,
  b: NonUsdCostTotals | null | undefined,
): boolean {
  const codes = new Set([...Object.keys(a ?? {}), ...Object.keys(b ?? {})]);
  for (const code of codes) {
    if (Math.abs((a?.[code] ?? 0) - (b?.[code] ?? 0)) > COST_EPSILON) return false;
  }
  return true;
}

/** Whether the totals contain a displayable non-USD amount. */
export function hasNonUsdCostTotals(totals: NonUsdCostTotals | null | undefined): totals is NonUsdCostTotals {
  return !!totals && Object.values(totals).some((amount) => costFractionDigits(amount) !== null);
}

/**
 * Cost text for a set of totals (cost-currency.v1 displayCases): USD first, the rest in ascending currency code
 * order, joined with ' + '; each part picks its digits from its own amount and zero-amount parts are omitted.
 * Returns an empty string when everything is omitted (callers keep their own '$0' fallback).
 */
export function formatCostTotals(
  usd: number,
  nonUsdTotals: NonUsdCostTotals | null | undefined,
  locale: string,
): string {
  const parts: string[] = [];
  const usdText = formatCost(usd);
  if (usdText) parts.push(usdText);
  if (nonUsdTotals) {
    for (const code of Object.keys(nonUsdTotals).sort()) {
      const text = formatNonUsdAmount(nonUsdTotals[code], code, locale);
      if (text) parts.push(text);
    }
  }
  return parts.join(' + ');
}

/** Non-USD parts whose amount is unavailable (currency codes): callers show the existing "N/A" text, never 0. */
export function notAvailableCostParts(nonUsdCost: NonUsdCost | null | undefined): string[] {
  return nonUsdCost && nonUsdCost.costSource === 'unknown' ? [nonUsdCost.currencyCode] : [];
}
