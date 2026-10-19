/**
 * Reader for the global context-cap preferences.
 * Stored in the local preference blob (oriveo.{uid}.preferences, alongside contextAISummaryEnabled, partitioned by account) and never enters the sync payload.
 */
import type { AppPreference } from '@oriveo/shared';
import { type BudgetCapOption, parseBudgetCap } from '@oriveo/core/context/budget';

/** Global default cap; a missing or unparseable value ("190000", 31999, true and the like) always reads as 'auto'. */
export function resolveContextDefaultCap(
  prefs: Pick<AppPreference, 'contextDefaultCap'> | null | undefined,
): BudgetCapOption {
  return parseBudgetCap(prefs?.contextDefaultCap) ?? 'auto';
}

/** Switch for the over-the-price-line reminder; only an explicit false turns it off, a missing or non-boolean value counts as true. */
export function resolvePriceLineReminderEnabled(
  prefs: Pick<AppPreference, 'contextPriceLineReminderEnabled'> | null | undefined,
): boolean {
  return prefs?.contextPriceLineReminderEnabled !== false;
}
