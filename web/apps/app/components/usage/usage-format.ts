/**
 * Shared formatting helpers for Usage Insights v4.
 *
 * Amount / percent / date formatting pulled out of page.tsx so the v4 cards reuse one implementation.
 */

import { COST_EPSILON } from "../../lib/utils/format-utils";
import { formatUsd } from "../../lib/utils/currency-format";

const USAGE_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * USD display.
 * - below epsilon → "—"
 * - below 0.0001 → 5 fraction digits, no less-than sign
 * - 0.01..1 → 4 fraction digits
 * - ≥1 → 2 fraction digits
 */
export function formatUsageCost(value: number, locale: string): string {
  if (!Number.isFinite(value) || value <= COST_EPSILON) {
    return "—";
  }
  if (value < 0.0001) {
    return formatLocalizedUSDCost(value, locale, 5, 5);
  }
  if (value < 0.01) {
    return formatLocalizedUSDCost(value, locale, 4, 4);
  }
  return formatLocalizedUSDCost(value, locale, 2, 2);
}

/** Compact currency display (hero bar label): $5.23 / $58.4 / $120 */
// Fraction tiers unchanged; symbol position and separators follow the app locale via formatUsd.
export function formatCompactCost(value: number, locale: string): string {
  if (value < 0.005) return formatLocalizedUSDCost(value, locale, 4, 4);
  if (value < 10) return formatLocalizedUSDCost(value, locale, 2, 2);
  if (value < 100) return formatLocalizedUSDCost(value, locale, 1, 1);
  return formatLocalizedUSDCost(value, locale, 0, 0);
}

export function formatLocalizedUSDCost(
  value: number,
  locale: string,
  minimumFractionDigits: number,
  maximumFractionDigits: number,
): string {
  return formatUsd(value, locale, { minimumFractionDigits, maximumFractionDigits });
}

/** Hero delta pill percentage: 0.23 → "(+23%)" / -0.08 → "(-8%)" */
export function formatDeltaPercentText(value: number): string {
  const pct = Math.round(value * 100);
  const signed = pct >= 0 ? `+${pct}` : `${pct}`;
  return `(${signed}%)`;
}

/**
 * Integer percentage text: "67%".
 *
 * Deliberately not `Intl.NumberFormat({style:'percent'})`: locales such as zh-CN or fr-FR insert a
 * non-breaking space between the number and `%` ("67 %"), which diverges from the iOS/Android
 * `\(pct)%` output. Use `Math.round` plus a literal `%`, matching iOS CostStoryHeroCard.percentText
 * and Android formatRoundPercent.
 *
 * @param share ratio between 0 and 1 (values ≥1 or negative are clamped to [0, 1+] and still rendered ×100)
 */
export function formatPercent(share: number): string {
  return `${Math.round(Math.max(share, 0) * 100)}%`;
}

/** Integer 0-100 percentage text: "67%" (same behaviour as formatPercent; used by hero / budget bar) */
export function formatRoundPercent(share: number): string {
  return `${Math.round(share * 100)}%`;
}

export function parseUsageDate(rawValue: string | null | undefined): Date | null {
  if (!rawValue) return null;
  // Prefer yyyy-MM-dd (UTC midnight)
  const match = USAGE_DATE_PATTERN.exec(rawValue);
  if (match) {
    const [, y, m, d] = match;
    return new Date(Date.UTC(Number(y), Number(m) - 1, Number(d)));
  }
  // ISO8601 fallback
  const d = new Date(rawValue);
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * Hero header subtitle date text (aligned with iOS CostStoryHeroCard.periodDateSubtitle):
 * - day: "May 19"
 * - week: "May 13 – 19" / "Apr 28 – May 4"
 * - month: "May 2026"
 */
export function formatHeroPeriodSubtitle(
  granularity: "day" | "week" | "month",
  startISO: string | null | undefined,
  endISO: string | null | undefined,
  locale: string,
): string | null {
  const start = parseUsageDate(startISO);
  if (!start) return null;
  const end = parseUsageDate(endISO);

  if (granularity === "day") {
    return new Intl.DateTimeFormat(locale, {
      month: "short",
      day: "numeric",
      timeZone: "UTC",
    }).format(start);
  }
  if (granularity === "month") {
    return new Intl.DateTimeFormat(locale, {
      month: "short",
      year: "numeric",
      timeZone: "UTC",
    }).format(start);
  }
  // week
  const endDate = end ?? addDays(start, 6);
  const sameMonth = start.getUTCMonth() === endDate.getUTCMonth();
  const startTxt = new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(start);
  const endTxt = sameMonth
    ? new Intl.DateTimeFormat(locale, { day: "numeric", timeZone: "UTC" }).format(endDate)
    : new Intl.DateTimeFormat(locale, {
        month: "short",
        day: "numeric",
        timeZone: "UTC",
      }).format(endDate);
  return `${startTxt} – ${endTxt}`;
}

function addDays(d: Date, days: number): Date {
  const next = new Date(d);
  next.setUTCDate(next.getUTCDate() + days);
  return next;
}

/** Sparkline bar bottom date label (short form): day "May 19" / week "May 13" / month "May" */
export function formatBucketShortLabel(
  granularity: "day" | "week" | "month",
  startISO: string,
  locale: string,
): string {
  const d = parseUsageDate(startISO);
  if (!d) return startISO;
  if (granularity === "month") {
    return new Intl.DateTimeFormat(locale, {
      month: "short",
      timeZone: "UTC",
    }).format(d);
  }
  return new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
    timeZone: "UTC",
  }).format(d);
}

/** Short label for the current month in the given locale, e.g. "May" */
export function getCurrentMonthShortLabel(locale: string): string {
  const now = new Date();
  return new Intl.DateTimeFormat(locale, { month: "short" }).format(now);
}
