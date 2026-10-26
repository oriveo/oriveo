/**
 * Table of input protocol families (wire families) implemented by the Web client at compile time.
 * Kept aligned item by item with the families whose implementedBy contains web in shared/model-contracts/wire_families.v1.json,
 * and locked by the reconciliation in __tests__/input-capability-cases.contract.test.ts; change both sides together when implementations are added or removed.
 */
export const WEB_PROTOCOL_IMPLEMENTATIONS: ReadonlySet<string> = new Set([
  'openai_chat.image_url',
  'openai_chat.file',
  'openai_chat.video_url',
  'openai_responses.input_image',
  'openai_responses.input_file',
  'anthropic.image',
  'anthropic.document',
  'gemini.inline_data',
]);

/** Whether this client implements the wire family; a missing id or one absent from the table is treated as not implemented. */
export function endImplementsWireFamily(id?: string): boolean {
  return typeof id === 'string' && WEB_PROTOCOL_IMPLEMENTATIONS.has(id);
}

/**
 * Protocol default when the Anthropic Messages protocol requires max_tokens; aligned with
 * protocols.anthropic.defaultMaxOutputTokens in shared/model-contracts/wire_families.v1.json.
 * Resolution order: explicit value > model maxOutputTokens > this constant.
 */
export const ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS = 8192;

/** The promptCache.policyRef value in the model catalog meaning "Anthropic explicit cache_control breakpoint". */
export const ANTHROPIC_EXPLICIT_PROMPT_CACHE_POLICY = 'anthropic.explicit';

/** Official models only get a cache_control breakpoint when the catalog verdict is anthropic.explicit; a missing policyRef means no breakpoint. */
export function usesAnthropicExplicitPromptCache(policyRef?: string | null): boolean {
  return policyRef === ANTHROPIC_EXPLICIT_PROMPT_CACHE_POLICY;
}

/** Explicit value > model maxOutputTokens > protocol default; only positive finite numbers count. */
export function resolveAnthropicMaxTokens(...candidates: ReadonlyArray<number | undefined>): number {
  for (const value of candidates) {
    if (typeof value === 'number' && Number.isFinite(value) && value > 0) return value;
  }
  return ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS;
}
