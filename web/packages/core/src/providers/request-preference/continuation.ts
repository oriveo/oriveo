/**
 * request_preference_contract.v2, continuation section.
 *
 * Each continuationKind has a fixed maximum step count and a set of required fields. An unknown
 * kind or an unknown variant is always rejected fail-safe (reject_feature_patch); the semantics
 * are never guessed. fiber is a variant of tool_loop, not a kind of its own.
 */

import type { ContinuationKind } from './types';

interface ContinuationKindSpec {
  maxSteps: number;
  requiredStateFields: readonly string[];
  variants?: readonly string[];
}

export const CONTINUATION_KINDS: Readonly<Record<ContinuationKind, ContinuationKindSpec>> = {
  none: { maxSteps: 0, requiredStateFields: [] },
  previous_id: { maxSteps: 1, requiredStateFields: ['previousResponseId'] },
  replay_blocks: { maxSteps: 8, requiredStateFields: ['blocks'] },
  replay_reasoning: { maxSteps: 8, requiredStateFields: ['assistantMessages'] },
  tool_loop: { maxSteps: 8, requiredStateFields: ['completedMessages'], variants: ['default', 'fiber'] },
};

export interface ContinuationIntent {
  kind: string;
  variant?: string;
  step: number;
  state: Readonly<Record<string, unknown>>;
}

export type ContinuationRejectReason =
  | 'unknown_continuation_kind'
  | 'unknown_variant'
  | 'step_limit_exceeded'
  | 'missing_state_field'
  | 'invalid_tool_loop_state'
  | 'invalid_reasoning_replay_state';

export type ContinuationResult =
  | { accepted: true; reason: null }
  | { accepted: false; reason: ContinuationRejectReason };

export function validateContinuation({ kind, variant, step, state }: ContinuationIntent): ContinuationResult {
  const spec = (CONTINUATION_KINDS as Record<string, ContinuationKindSpec | undefined>)[kind];
  if (spec == null) return { accepted: false, reason: 'unknown_continuation_kind' };
  if (variant != null && !(spec.variants ?? []).includes(variant)) {
    return { accepted: false, reason: 'unknown_variant' };
  }
  if (!Number.isInteger(step) || step < 0 || step > spec.maxSteps) {
    return { accepted: false, reason: 'step_limit_exceeded' };
  }
  if (spec.requiredStateFields.some((field) => !Object.hasOwn(state, field))) {
    return { accepted: false, reason: 'missing_state_field' };
  }
  if (kind === 'tool_loop' && !hasCompleteToolBlocks(state.completedMessages)) {
    return { accepted: false, reason: 'invalid_tool_loop_state' };
  }
  if (kind === 'replay_reasoning' && !hasReasoningAssistantMessages(state.assistantMessages)) {
    return { accepted: false, reason: 'invalid_reasoning_replay_state' };
  }
  return { accepted: true, reason: null };
}

/** MiniMax Server-side Tools replays provider-owned Anthropic blocks verbatim. Only complete,
 * documented M3 block shapes cross the next-request boundary; unknown or partial blocks remain
 * display-only and fail closed for continuation. */
export function isMiniMaxAnthropicReplayBlocks(value: unknown): value is Array<Record<string, unknown>> {
  return Array.isArray(value) && value.length > 0 && value.every((block) => {
    if (!isRecord(block) || typeof block.type !== 'string') return false;
    if (block.type === 'thinking') {
      return exactKeys(block, ['type', 'thinking', 'signature'])
        && typeof block.thinking === 'string'
        && typeof block.signature === 'string'
        && block.signature.length > 0;
    }
    if (block.type === 'text') {
      return exactKeys(block, ['type', 'text']) && typeof block.text === 'string';
    }
    if (block.type === 'server_tool_use' || block.type === 'tool_use') {
      return exactKeys(block, ['type', 'id', 'name', 'input'])
        && typeof block.id === 'string' && block.id.length > 0
        && typeof block.name === 'string' && block.name.length > 0
        && isRecord(block.input);
    }
    if (block.type === 'web_search_tool_result') {
      return exactKeys(block, ['type', 'tool_use_id', 'content'])
        && typeof block.tool_use_id === 'string' && block.tool_use_id.length > 0
        && Array.isArray(block.content) && block.content.length > 0
        && block.content.every(isMiniMaxWebSearchResult);
    }
    return false;
  });
}

function isMiniMaxWebSearchResult(value: unknown): boolean {
  if (!isRecord(value) || !exactKeys(value, ['type', 'title', 'url', 'page_age', 'content'])) return false;
  return value.type === 'web_search_result'
    && typeof value.title === 'string'
    && typeof value.url === 'string' && value.url.length > 0
    && (value.page_age === undefined || typeof value.page_age === 'string')
    && (value.content === undefined || typeof value.content === 'string');
}

function exactKeys(value: Record<string, unknown>, allowed: readonly string[]): boolean {
  return Object.keys(value).every((key) => allowed.includes(key));
}

/** A tool result without the assistant tool_call that authorized it is invalid upstream state.
 * Keep only complete ordered blocks: assistant(tool_calls[, reasoning_content]) followed by its
 * matching role=tool messages. Empty is legal before the first completed leg. */
function hasCompleteToolBlocks(value: unknown): boolean {
  if (!Array.isArray(value)) return false;
  const ids = new Set<string>();
  for (let index = 0; index < value.length;) {
    const assistant = value[index++];
    if (!isRecord(assistant) || assistant.role !== 'assistant' || !Array.isArray(assistant.tool_calls) || assistant.tool_calls.length === 0) return false;
    if (assistant.content !== undefined && typeof assistant.content !== 'string') return false;
    if (assistant.reasoning_content !== undefined && typeof assistant.reasoning_content !== 'string') return false;
    for (const call of assistant.tool_calls) {
      if (!isRecord(call) || typeof call.id !== 'string' || !call.id || ids.has(call.id) || !['function', 'builtin_function'].includes(String(call.type)) || !isRecord(call.function)
        || typeof call.function.name !== 'string' || !call.function.name || typeof call.function.arguments !== 'string') return false;
      ids.add(call.id);
      const tool = value[index++];
      if (!isRecord(tool) || tool.role !== 'tool' || tool.tool_call_id !== call.id || typeof tool.content !== 'string') return false;
      if (tool.name !== undefined && tool.name !== call.function.name) return false;
    }
  }
  return true;
}

/** Opaque reasoning may only replay complete assistant messages. The wire mapper performs the
 * stricter responseParserKind-specific check before choosing reasoning_details/reasoning_content. */
function hasReasoningAssistantMessages(value: unknown): boolean {
  if (!Array.isArray(value) || value.length === 0) return false;
  return value.every((message) => {
    if (!isRecord(message) || message.role !== 'assistant') return false;
    if (isMistralReasoningAssistantMessage(message)) return true;
    if (message.reasoning_details !== undefined) {
      return isOpenRouterReasoningAssistantMessage(message)
        || isNullableContentReasoningDetailsMessage(message);
    }
    if (message.content !== undefined && message.content !== null && typeof message.content !== 'string') return false;
    const hasContent = typeof message.reasoning_content === 'string';
    if (!hasContent) return false;
    if (message.tool_calls !== undefined && !hasValidAssistantToolCalls(message.tool_calls)) return false;
    return Object.keys(message).every((key) => ['role', 'content', 'reasoning_content', 'tool_calls'].includes(key));
  });
}

/** MiniMax shares the opaque details envelope but permits explicit null content. The recipe-owned
 * mapper still performs its provider-specific exact check; this generic gate only keeps the local
 * continuation JSON structurally bounded. */
function isNullableContentReasoningDetailsMessage(value: unknown): boolean {
  if (!isRecord(value) || value.role !== 'assistant'
    || (value.content !== null && typeof value.content !== 'string')
    || !Array.isArray(value.reasoning_details) || value.reasoning_details.length === 0
    || !value.reasoning_details.every(isOpenRouterReasoningDetail)
    || !Object.keys(value).every((key) => ['role', 'content', 'reasoning_details', 'tool_calls'].includes(key))) return false;
  return value.tool_calls === undefined || hasExactOpenAIToolCalls(value.tool_calls);
}

/** OpenRouter reasoning details are opaque payloads inside a strict assistant envelope. Entries
 * without `index` stay distinct and ordered; an index, when present, must be a non-negative integer
 * so the stream producer can merge fragments without inventing an identity. */
export function isOpenRouterReasoningAssistantMessage(value: unknown): value is Record<string, unknown> {
  if (!isRecord(value) || value.role !== 'assistant' || typeof value.content !== 'string') return false;
  if (!Object.keys(value).every((key) => ['role', 'content', 'reasoning_details', 'tool_calls'].includes(key))) return false;
  if (!Array.isArray(value.reasoning_details) || value.reasoning_details.length === 0
    || !value.reasoning_details.every(isOpenRouterReasoningDetail)) return false;
  return value.tool_calls === undefined || hasExactOpenAIToolCalls(value.tool_calls);
}

function isOpenRouterReasoningDetail(value: unknown): boolean {
  if (!isRecord(value) || typeof value.type !== 'string' || value.type.length === 0) return false;
  if (value.index !== undefined
    && (!Number.isInteger(value.index) || (value.index as number) < 0)) return false;
  return ['text', 'summary', 'data'].every((key) => value[key] === undefined || typeof value[key] === 'string');
}

/** Mistral replays the complete assistant message: reasoning is embedded in ordered content
 * blocks, while a no-visible-thinking response remains a string. Keep this shape exact so a
 * generic OpenAI-compatible payload cannot smuggle provider-owned fields into replay. */
export function isMistralReasoningAssistantMessage(value: unknown): boolean {
  if (!isRecord(value) || value.role !== 'assistant') return false;
  if (!Object.keys(value).every((key) => ['role', 'content', 'tool_calls'].includes(key))) return false;
  if (!isMistralAssistantContent(value.content)) return false;
  return value.tool_calls === undefined || hasExactMistralToolCalls(value.tool_calls);
}

function isMistralAssistantContent(value: unknown): boolean {
  if (typeof value === 'string') return true;
  return Array.isArray(value) && value.length > 0 && value.every((block) => {
    if (!isRecord(block) || (block.type !== 'thinking' && block.type !== 'text')) return false;
    if (block.type === 'text') {
      return typeof block.text === 'string'
        && Object.keys(block).every((key) => key === 'type' || key === 'text');
    }
    return Array.isArray(block.thinking)
      && block.thinking.every((piece) => isRecord(piece)
        && piece.type === 'text'
        && typeof piece.text === 'string'
        && Object.keys(piece).every((key) => key === 'type' || key === 'text'))
      && (block.closed === undefined || typeof block.closed === 'boolean')
      && Object.keys(block).every((key) => ['type', 'thinking', 'closed'].includes(key));
  });
}

function hasExactMistralToolCalls(value: unknown): boolean {
  return Array.isArray(value) && value.length > 0 && value.every((call) => isRecord(call)
    && Object.keys(call).every((key) => ['id', 'type', 'function'].includes(key))
    && typeof call.id === 'string' && call.id.length > 0
    && call.type === 'function'
    && isRecord(call.function)
    && Object.keys(call.function).every((key) => key === 'name' || key === 'arguments')
    && typeof call.function.name === 'string' && call.function.name.length > 0
    && typeof call.function.arguments === 'string');
}

function hasExactOpenAIToolCalls(value: unknown): boolean {
  return Array.isArray(value) && value.length > 0 && value.every((call) => isRecord(call)
    && Object.keys(call).every((key) => ['id', 'type', 'function'].includes(key))
    && typeof call.id === 'string' && call.id.length > 0
    && call.type === 'function'
    && isRecord(call.function)
    && Object.keys(call.function).every((key) => key === 'name' || key === 'arguments')
    && typeof call.function.name === 'string' && call.function.name.length > 0
    && typeof call.function.arguments === 'string');
}

function hasValidAssistantToolCalls(value: unknown): boolean {
  return Array.isArray(value) && value.length > 0 && value.every((call) => isRecord(call)
    && typeof call.id === 'string' && call.id.length > 0
    && call.type === 'function'
    && isRecord(call.function)
    && typeof call.function.name === 'string' && call.function.name.length > 0
    && typeof call.function.arguments === 'string');
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value != null && !Array.isArray(value);
}
