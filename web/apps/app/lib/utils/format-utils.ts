/**
 * Cost formatting helpers.
 */

const numberFormatterCache = new Map<string, Intl.NumberFormat>();
const dateTimeFormatterCache = new Map<string, Intl.DateTimeFormat>();
const relativeTimeFormatterCache = new Map<string, Intl.RelativeTimeFormat>();

function buildIntlCacheKey(
  locale: string | undefined,
  options: object | undefined,
): string {
  if (!options) {
    return locale ?? '';
  }

  const entries = Object.entries(options as Record<string, unknown>)
    .filter(([, value]) => value !== undefined)
    .sort(([left], [right]) => left.localeCompare(right));

  return `${locale ?? ''}:${JSON.stringify(entries)}`;
}

/** Costs at or below this are treated as zero and render as an empty string, not as "$0.00". */
export const COST_EPSILON = 0.00001;

/**
 * Construct an Intl formatter defensively: an invalid BCP-47 tag (such as the stale value
 * 'chineseSimplified') makes Intl throw `RangeError: Invalid language tag`. Catch it and fall back to
 * undefined (the system default locale) so a single bad preference value cannot take down the whole UI.
 */
function safeConstructIntl<T, O>(
  ctor: new (locale: string | undefined, options?: O) => T,
  locale: string | undefined,
  options: O | undefined,
): T {
  try {
    return new ctor(locale, options);
  } catch {
    return new ctor(undefined, options);
  }
}

export function getNumberFormatter(
  locale: string | undefined,
  options?: Intl.NumberFormatOptions,
): Intl.NumberFormat {
  const key = buildIntlCacheKey(locale, options);
  const cached = numberFormatterCache.get(key);
  if (cached) {
    return cached;
  }

  const formatter = safeConstructIntl(Intl.NumberFormat, locale, options);
  numberFormatterCache.set(key, formatter);
  return formatter;
}

export function getDateTimeFormatter(
  locale: string | undefined,
  options?: Intl.DateTimeFormatOptions,
): Intl.DateTimeFormat {
  const key = buildIntlCacheKey(locale, options);
  const cached = dateTimeFormatterCache.get(key);
  if (cached) {
    return cached;
  }

  const formatter = safeConstructIntl(Intl.DateTimeFormat, locale, options);
  dateTimeFormatterCache.set(key, formatter);
  return formatter;
}

export function getRelativeTimeFormatter(
  locale: string | undefined,
  options?: Intl.RelativeTimeFormatOptions,
): Intl.RelativeTimeFormat {
  const key = buildIntlCacheKey(locale, options);
  const cached = relativeTimeFormatterCache.get(key);
  if (cached) {
    return cached;
  }

  const formatter = safeConstructIntl(Intl.RelativeTimeFormat, locale, options);
  relativeTimeFormatterCache.set(key, formatter);
  return formatter;
}

/**
 * Format a numeric cost value as a display string.
 * - value ≤ COST_EPSILON → ""
 * - COST_EPSILON < value < 0.0001 → "$0.000XX" (5 decimals)
 * - 0.0001 ≤ value < 0.01 → "$X.XXXX" (4 decimals)
 * - value ≥ 0.01 → "$X.XX" (2 decimals)
 */
export function formatCost(value: number): string {
  if (!value || !Number.isFinite(value) || value <= COST_EPSILON) return '';
  if (value < 0.0001) return `$${value.toFixed(5)}`;
  if (value < 0.01) return `$${value.toFixed(4)}`;
  return `$${value.toFixed(2)}`;
}

/**
 * Convert a per-token USD price into a readable per-million-token label.
 * - 0 becomes an empty string
 * - very small unit prices keep 3 significant digits rather than using a less-than sign
 * - otherwise "$X.XX/M" with 3 significant digits
 */
export function formatPerMillionPrice(perTokenPrice: number): string {
  if (!Number.isFinite(perTokenPrice) || perTokenPrice <= 0) return '';
  const perMillion = perTokenPrice * 1_000_000;
  return `$${Number(perMillion.toPrecision(3))}/M`;
}

/**
 * Derive a model's price label from its prompt and completion unit prices.
 * - the input price is shown when available
 * - when it is missing or 0, fall back to the output price
 */
export function formatModelPriceTier(
  promptPerToken: number | null | undefined,
  completionPerToken: number | null | undefined,
): string {
  const prompt = Number.isFinite(promptPerToken) ? promptPerToken : undefined;
  const completion = Number.isFinite(completionPerToken) ? completionPerToken : undefined;
  const effectivePrice = prompt && prompt > 0
    ? prompt
    : completion && completion > 0
      ? completion
      : undefined;

  return effectivePrice != null ? formatPerMillionPrice(effectivePrice) : '';
}

/**
 * Format an ISO timestamp as a localized relative time.
 * Uses Intl.RelativeTimeFormat.
 */
export function formatRelativeTime(iso: string, locale?: string): string {
  const date = new Date(iso);
  const now = Date.now();
  const diffMs = now - date.getTime();
  if (diffMs < 0 || !Number.isFinite(diffMs)) return '';

  const rtf = getRelativeTimeFormatter(locale, { numeric: 'auto', style: 'short' });

  const diffSec = Math.floor(diffMs / 1000);
  if (diffSec < 60) return rtf.format(-diffSec, 'second');

  const diffMin = Math.floor(diffSec / 60);
  if (diffMin < 60) return rtf.format(-diffMin, 'minute');

  const diffHour = Math.floor(diffMin / 60);
  if (diffHour < 24) return rtf.format(-diffHour, 'hour');

  const diffDay = Math.floor(diffHour / 24);
  if (diffDay < 30) return rtf.format(-diffDay, 'day');

  const diffMonth = Math.floor(diffDay / 30);
  if (diffMonth < 12) return rtf.format(-diffMonth, 'month');

  return rtf.format(-Math.floor(diffMonth / 12), 'year');
}

/** Whether to show the expensive-model hint; returns the integer multiplier, or null. */
export function evaluateExpensiveModelMultiplier(
  oldPromptPrice: number | undefined,
  newPromptPrice: number | undefined,
  threshold = 5,
): number | null {
  if (!oldPromptPrice || !newPromptPrice || oldPromptPrice <= 0) return null;
  const ratio = newPromptPrice / oldPromptPrice;
  return ratio > threshold ? Math.floor(ratio) : null;
}
