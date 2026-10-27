/**
 * Reader for the global context-cap preferences.
 * Stored in the local preference blob (oriveo.{uid}.preferences, alongside contextAISummaryEnabled, partitioned by account) and never enters the sync payload.
 */
import type { AppPreference } from '@oriveo/shared';
import { type BudgetCapOption, CONTEXT_BUDGET_CONSTANTS, parseBudgetCap } from '@oriveo/core/context/budget';

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

/** Indicator bar constants of the Settings > Context overview card (shared/ui-contracts/context-settings-hero.v1.json constants). */
export const CONTEXT_SETTINGS_HERO_CONSTANTS = {
  autoFill: 0.66,
  priceLineMarker: 0.7,
  minFill: 0.12,
  maxFill: 1,
} as const;

/** Caption keys of the overview card (namespace pages.settings.context). */
export type ContextSettingsHeroCaptionKey = 'heroCaptionAuto' | 'heroCaptionUnlimited' | 'heroCaptionCustom';

export type ContextSettingsHero = {
  /** count = the big text is the compact number valueTokens; fullWindow = the big text is the heroFullWindow string. */
  valueKind: 'count' | 'fullWindow';
  valueTokens: number | null;
  /** Whether to show the unit pages.chat.contextCap.inputUnit after the big text. */
  hasUnit: boolean;
  captionKey: ContextSettingsHeroCaptionKey;
  /** Indicator bar fill ratio 0..1; illustrative only, not any model's real price-line position. */
  fill: number;
};

/**
 * Overview card: derives the big number, caption key and indicator bar fill from the default cap option.
 * auto -> autoCapDefault / autoFill; unlimited -> full window / 1;
 * custom(n) -> n / clamp(n / autoCapDefault * autoFill, minFill, maxFill).
 */
export function contextSettingsHeroOf(cap: BudgetCapOption): ContextSettingsHero {
  const { autoFill, minFill, maxFill } = CONTEXT_SETTINGS_HERO_CONSTANTS;
  const autoCap = CONTEXT_BUDGET_CONSTANTS.autoCapDefault;
  if (cap === 'unlimited') {
    return { valueKind: 'fullWindow', valueTokens: null, hasUnit: false, captionKey: 'heroCaptionUnlimited', fill: maxFill };
  }
  if (cap === 'auto') {
    return { valueKind: 'count', valueTokens: autoCap, hasUnit: true, captionKey: 'heroCaptionAuto', fill: autoFill };
  }
  const fill = Math.min(maxFill, Math.max(minFill, (cap / autoCap) * autoFill));
  return { valueKind: 'count', valueTokens: cap, hasUnit: true, captionKey: 'heroCaptionCustom', fill };
}
