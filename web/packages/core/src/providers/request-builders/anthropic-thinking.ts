import type { ReasoningMode } from '@oriveo/shared/pure-types';

import type { DroppedGenerationParameter } from './generation-parameters';
import type { GenerationParameterProfile } from './types';

export interface AnthropicThinkingDecision {
  budgetTokens: number;
  maxTokens: number;
}

/** Default max_tokens of the builder (a Relay exception: a user-defined endpoint has no official profile to rely on). */
const RELAY_ANTHROPIC_DEFAULT_MAX_TOKENS = 8192;
/** Shared contract outboundRules.anthropicThinking.maxTokensFloorHeadroom. */
const THINKING_MAX_TOKENS_HEADROOM = 4096;
/** Shared contract outboundRules.anthropicThinking.topPMin. */
const THINKING_TOP_P_MIN = 0.95;
const THINKING_ACTIVE_TYPES = new Set(['enabled', 'adaptive']);

/**
 * The Relay Anthropic thinking decision (on or off, the budget, and how large a max_tokens the builder writes) has this one source:
 * both build paths (orchestration and transport strategy) and the UI preview share it. It looks at the connection protocol only, never the model name.
 */
export function resolveRelayAnthropicThinking(reasoning: ReasoningMode | undefined): AnthropicThinkingDecision | null {
  if (!reasoning || reasoning === 'automatic') return null;
  const budgetTokens = relayAnthropicBudgetTokens(reasoning);
  return {
    budgetTokens,
    maxTokens: Math.max(RELAY_ANTHROPIC_DEFAULT_MAX_TOKENS, budgetTokens + THINKING_MAX_TOKENS_HEADROOM),
  };
}

function relayAnthropicBudgetTokens(mode: ReasoningMode): number {
  switch (mode) {
    case 'fast':
      return 2048;
    case 'deep':
      return 16384;
    case 'max':
      // 24576 + 4096 = 28672, which stays within the 32000 max_output limit of claude-opus-4-1.
      return 24576;
    case 'balanced':
    default:
      return 8192;
  }
}

/**
 * Linked protection when Anthropic thinking is on (shared contract outboundRules.anthropicThinking). It must be called after the thinking field and
 * the generation parameters have both been written; the decision looks at the fields in the final body regardless of where they came from, because upstream rejects the field itself.
 * Parameters written by the panel (parameter IDs in `written`) go into the dropped-items list, while ones the builder wrote itself are handled silently.
 * No field is changed when thinking is off.
 */
export function guardAnthropicThinking(
  body: Record<string, unknown>,
  input: { profile?: GenerationParameterProfile; written: readonly string[]; builderDefaultMaxTokens: unknown },
): DroppedGenerationParameter[] {
  const thinking = body.thinking;
  if (!thinking || typeof thinking !== 'object' || Array.isArray(thinking)) return [];
  const { type, budget_tokens: budget } = thinking as { type?: unknown; budget_tokens?: unknown };
  if (typeof type !== 'string' || !THINKING_ACTIVE_TYPES.has(type)) return [];

  const dropped: DroppedGenerationParameter[] = [];
  const written = new Set(input.written);
  const wireOf = (id: string, fallback: string) => {
    const wire = input.profile?.wire[id];
    return wire && !wire.includes('.') ? wire : fallback;
  };
  const drop = (id: string, wire: string, reason: DroppedGenerationParameter['reason']) => {
    delete body[wire];
    if (written.has(id)) dropped.push({ parameterId: id, reason });
  };

  for (const id of ['temperature', 'top_k']) {
    const wire = wireOf(id, id);
    if (body[wire] !== undefined) drop(id, wire, 'thinking_incompatible');
  }
  const topPWire = wireOf('top_p', 'top_p');
  const topP = body[topPWire];
  if (typeof topP === 'number' && topP < THINKING_TOP_P_MIN) drop('top_p', topPWire, 'thinking_incompatible');

  if (typeof budget === 'number') {
    const maxWire = wireOf('max_output_tokens', 'max_tokens');
    const current = body[maxWire];
    if (typeof current !== 'number' || current <= budget) {
      if (typeof current === 'number' && written.has('max_output_tokens')) {
        dropped.push({ parameterId: 'max_output_tokens', reason: 'thinking_budget' });
      }
      const fallback = input.builderDefaultMaxTokens;
      body[maxWire] = typeof fallback === 'number' && fallback > budget
        ? fallback
        : budget + THINKING_MAX_TOKENS_HEADROOM;
    }
  }
  return dropped;
}
