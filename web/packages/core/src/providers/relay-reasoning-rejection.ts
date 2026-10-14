/**
 * Error-body criteria for a relay rejecting reasoning parameters (fixture `relay/reasoning-tier.v1.json` rejectionTokens).
 * Computed from the raw response body: the error event's errorDetail keeps only the message, so hints like `"param":"reasoning.effort"` get lost; the verdict is therefore computed where the event is produced.
 */
export const RELAY_REASONING_REJECTION_TOKENS: readonly string[] = [
  'reasoning', 'thinking', 'effort', 'budget_tokens',
  'thinkingconfig', 'thinkingbudget', 'thinkinglevel', 'enable_thinking',
];

/** The error body (lowercased) names a reasoning parameter. */
export function relayErrorBodyNamesReasoning(body: string): boolean {
  const lowered = body.toLowerCase();
  return RELAY_REASONING_REJECTION_TOKENS.some((token) => lowered.includes(token));
}
