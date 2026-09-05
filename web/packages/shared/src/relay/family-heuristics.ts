/**
 * Relay model family heuristics, a contract shared by every client.
 *
 * Lets a user who imported `model = "gpt-5.4"` see the official OpenAI logo on the chat avatar.
 * The regex literals must be identical on every client; `family-heuristics.test.ts` locks them.
 */

export type RelayModelFamily =
  | 'openai'
  | 'anthropic'
  | 'google'
  | 'deepseek'
  | 'qwen'
  | 'xai'
  | 'meta'
  | 'mistral';

export type RelayKindSuggestion =
  | 'openai_compatible'
  | 'codex_style'
  | 'anthropic_compatible'
  | 'gemini_compatible'
  | 'custom';

// o[134](?:\b|-) matches the OpenAI reasoning family `o1/o3/o4` and its suffixed variants
// (`o3-mini`, a trailing `o4`, while not matching `o5-xxx`).
// Note: a character class such as `[\b\-]` does not work - inside a JS character class `\b` is a
// backspace rather than a word boundary, so it cannot match a trailing `o4`. `(?:\b|-)` keeps the
// intended meaning: letter plus digit plus a separator or word boundary.
const PATTERNS: ReadonlyArray<readonly [RelayModelFamily, RegExp]> = [
  ['openai', /^(?:gpt-|o[134](?:\b|-)|chatgpt|dall-e|whisper|tts-|gpt-image|text-embedding)/],
  ['anthropic', /^claude-/],
  ['google', /^(gemini|imagen|text-bison|palm)/],
  ['deepseek', /^(deepseek|ds-)/],
  ['qwen', /^(qwen|qwq)/],
  ['xai', /^grok/],
  ['meta', /^(llama|codellama)/],
  ['mistral', /^(mistral|mixtral|codestral)/],
];

/** Infer the family from a model ID prefix; returns the family on a match and null otherwise. No capability inference. */
export function inferModelFamily(modelId: string | null | undefined): RelayModelFamily | null {
  if (!modelId) return null;
  const id = modelId.toLowerCase().trim();
  if (!id) return null;
  for (const [family, regex] of PATTERNS) {
    if (regex.test(id)) return family;
  }
  return null;
}

export function compatibleRelayKinds(
  family: RelayModelFamily | null | undefined,
): RelayKindSuggestion[] {
  switch (family) {
    case 'openai':
      return ['openai_compatible', 'codex_style'];
    case 'anthropic':
      return ['anthropic_compatible'];
    case 'google':
      return ['gemini_compatible'];
    case 'deepseek':
    case 'qwen':
    case 'xai':
    case 'meta':
    case 'mistral':
    case null:
    case undefined:
      return [];
  }
}

export function suggestedRelayKind(
  family: RelayModelFamily | null | undefined,
): RelayKindSuggestion | null {
  switch (family) {
    case 'openai':
      return 'openai_compatible';
    case 'anthropic':
      return 'anthropic_compatible';
    case 'google':
      return 'gemini_compatible';
    case 'deepseek':
    case 'qwen':
    case 'xai':
    case 'meta':
    case 'mistral':
    case null:
    case undefined:
      return null;
  }
}
