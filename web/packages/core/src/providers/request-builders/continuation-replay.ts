/** Typed continuation replay. Invalid/missing local state never leaks a guessed provider field. */
import {
  isMistralReasoningAssistantMessage,
  isMiniMaxAnthropicReplayBlocks,
  isOpenRouterReasoningAssistantMessage,
  validateContinuation,
  type ContinuationIntent,
} from '../request-preference/continuation';
import type { RuntimeRecipe } from './capability-execution';

/** Wire mapper: opaque continuation cannot be spread into an arbitrary provider root.
 * Non-root forms are replayed only by their owning response adapter as assistant/tool messages. */
export type RecipeContinuationMapping =
  | { accepted: true; target: 'body'; delta: Record<string, unknown> }
  | { accepted: true; target: 'message_append'; messages: Array<Record<string, unknown>> }
  | { accepted: true; target: 'contents_append'; contents: unknown[] }
  | { accepted: false; reason: 'invalid_continuation' | 'recipe_kind_mismatch' | 'unsupported_wire_mapping' };

export function mapContinuationForRecipe(recipe: RuntimeRecipe, intent: ContinuationIntent | null | undefined): RecipeContinuationMapping {
  if (!intent || !validateContinuation(intent).accepted) return { accepted: false, reason: 'invalid_continuation' };
  if (recipe.continuationKind !== intent.kind || (recipe.continuationVariant ?? undefined) !== (intent.variant ?? undefined)) {
    return { accepted: false, reason: 'recipe_kind_mismatch' };
  }
  if (intent.kind === 'none') return { accepted: true, target: 'body', delta: {} };
  if (intent.kind === 'previous_id' && typeof intent.state.previousResponseId === 'string') {
    if (recipe.transport?.protocol === 'openai_responses') return { accepted: true, target: 'body', delta: { previous_response_id: intent.state.previousResponseId } };
    if (recipe.transport?.protocol === 'gemini_interactions') return { accepted: true, target: 'body', delta: { previous_interaction_id: intent.state.previousResponseId } };
  }
  if (intent.kind === 'replay_blocks' && Array.isArray(intent.state.blocks)) {
    const route = recipe.route;
    const protocol = route && route.sourceProtocol === recipe.transport?.protocol
      ? route.protocol
      : recipe.transport?.protocol;
    if (protocol === 'anthropic_messages') {
      if (recipe.responseParserKind === 'minimax_anthropic_web_v1'
        && !isMiniMaxAnthropicReplayBlocks(intent.state.blocks)) {
        return { accepted: false, reason: 'invalid_continuation' };
      }
      return { accepted: true, target: 'message_append', messages: [{ role: 'assistant', content: intent.state.blocks }] };
    }
    if (protocol === 'gemini_generate_content') return { accepted: true, target: 'contents_append', contents: intent.state.blocks };
  }
  if (intent.kind === 'replay_reasoning' && Array.isArray(intent.state.assistantMessages) && recipe.transport?.protocol === 'openai_chat') {
    const messages = intent.state.assistantMessages;
    if (recipe.responseParserKind === 'openrouter_reasoning_v1' && messages.every(isOpenRouterReasoningAssistantMessage)) {
      return { accepted: true, target: 'message_append', messages };
    }
    if (recipe.responseParserKind === 'minimax_reasoning_v1' && messages.every(isMiniMaxReasoningMessage)) {
      return { accepted: true, target: 'message_append', messages };
    }
    if ((recipe.responseParserKind === 'moonshot_reasoning_v1' || recipe.responseParserKind === 'deepseek_reasoning_v1')
      && messages.every(isReasoningContentMessage)) {
      return { accepted: true, target: 'message_append', messages };
    }
    if (recipe.responseParserKind === 'mistral_reasoning_v1' && messages.every(isMistralReasoningAssistantMessage)) {
      return { accepted: true, target: 'message_append', messages };
    }
  }
  if (intent.kind === 'tool_loop' && (recipe.continuationVariant === 'fiber' || recipe.continuationVariant === 'default') && Array.isArray(intent.state.completedMessages)) {
    // validateContinuation above guarantees ordered assistant tool_calls + matching role=tool
    // blocks. Replay verbatim; never reconstruct a lossy orphan tool message.
    return { accepted: true, target: 'message_append', messages: intent.state.completedMessages as Array<Record<string, unknown>> };
  }
  return { accepted: false, reason: 'unsupported_wire_mapping' };
}
function isRecord(value: unknown): value is Record<string, unknown> { return typeof value === 'object' && value != null && !Array.isArray(value); }
export function isMiniMaxReasoningMessage(value: unknown): value is Record<string, unknown> {
  if (!isRecord(value) || value.role !== 'assistant'
    || !Object.hasOwn(value, 'content')
    || (value.content !== null && typeof value.content !== 'string')
    || !Array.isArray(value.reasoning_details) || value.reasoning_details.length === 0
    || !value.reasoning_details.every(isRecord)
    || !Object.keys(value).every((key) => ['role', 'content', 'reasoning_details', 'tool_calls'].includes(key))) return false;
  return value.tool_calls === undefined || isExactMiniMaxToolCalls(value.tool_calls);
}
function isExactMiniMaxToolCalls(value: unknown): boolean {
  return Array.isArray(value) && value.length > 0 && value.every((raw) => {
    if (!isRecord(raw) || !Object.keys(raw).every((key) => ['id', 'type', 'function'].includes(key))
      || typeof raw.id !== 'string' || !raw.id || raw.type !== 'function' || !isRecord(raw.function)
      || !Object.keys(raw.function).every((key) => key === 'name' || key === 'arguments')) return false;
    return typeof raw.function.name === 'string' && raw.function.name.length > 0
      && typeof raw.function.arguments === 'string';
  });
}
function isReasoningContentMessage(value: unknown): value is Record<string, unknown> {
  return isRecord(value) && value.role === 'assistant' && typeof value.reasoning_content === 'string'
    && value.reasoning_details === undefined;
}
