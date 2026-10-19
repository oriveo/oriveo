/** Page names of the context page family samples (the same set as the shared manifest shared/test-fixtures/shots/context.v1.json, iOS and Android; original casing). */
export const CONTEXT_SHOT_PAGES = [
  'contextDividerSummary',
  'contextDividerVerbatim',
  'contextCheckpointDetail',
  'contextCompactHint',
  'contextRingNormal',
  'contextRingHigh',
  'contextRingOver',
  'contextRingHidden',
  'contextIncompleteFooter',
  'contextDirectiveSuggestion',
  'contextMemorySuggestion',
  'contextPanel',
  'contextPanelPriceLine',
  'contextPanelUnknown',
  'contextCapPicker',
  'contextCapPickerCustom',
  'contextCapPickerLarge',
  'contextSettings',
  'contextConfirmOverCap',
  'contextConfirmPriceLine',
  'contextConversationSettings',
] as const;

export type ContextShotPage = (typeof CONTEXT_SHOT_PAGES)[number];

export function isContextShotPage(value: string): value is ContextShotPage {
  return (CONTEXT_SHOT_PAGES as readonly string[]).includes(value);
}
