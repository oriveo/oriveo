import type { StreamEvent, StreamToolCallDelta } from './types';

export type ToolCallProtocol =
  | 'openai_chat'
  | 'openai_responses'
  | 'anthropic_messages'
  | 'gemini_generate_content';

/**
 * Converts native provider tool proposals into the one cross-client delta shape. It deliberately
 * accepts only structured wire fields: prose, JSON fences and pseudo-tags remain ordinary text.
 */
export function nativeToolCallEvents(
  protocol: ToolCallProtocol,
  eventType: string | null,
  payload: Record<string, unknown>,
  state?: Record<string, unknown>,
): StreamEvent[] {
  const deltas = protocol === 'openai_chat'
    ? openAIChatDeltas(payload, state)
    : protocol === 'anthropic_messages'
    ? anthropicDeltas(eventType, payload)
    : protocol === 'openai_responses'
      ? responsesDeltas(eventType, payload)
      : geminiDeltas(payload);
  return deltas.length > 0 ? [{ type: 'tool_calls', toolCalls: deltas }] : [];
}

function openAIChatDeltas(
  payload: Record<string, unknown>,
  state?: Record<string, unknown>,
): StreamToolCallDelta[] {
  const choices = array(payload.choices);
  const choice = record(choices?.[0]);
  const delta = record(choice?.delta) ?? record(choice?.message);
  const calls = array(delta?.tool_calls);
  if (!calls) return [];

  return calls.flatMap((raw, fallbackIndex) => {
    const call = record(raw);
    if (!call) return [];
    const fn = record(call.function);
    const explicitIndex = integer(call.index);
    const previousIndex = integer(state?.openAIChatLastToolCallIndex);
    const index = explicitIndex ?? (calls.length === 1 ? previousIndex : undefined) ?? fallbackIndex;
    if (state) state.openAIChatLastToolCallIndex = index;
    const id = string(call.id);
    const type = string(call.type);
    const name = string(call.name) ?? string(fn?.name);
    const argumentsFragment = string(call.arguments) ?? string(fn?.arguments);
    if (id == null && type == null && name == null && argumentsFragment == null) return [];
    return [{
      index,
      ...(id != null ? { id } : {}),
      ...(type != null ? { type } : {}),
      ...(name != null ? { name } : {}),
      ...(argumentsFragment != null ? { arguments: argumentsFragment } : {}),
    }];
  });
}

function anthropicDeltas(eventType: string | null, payload: Record<string, unknown>): StreamToolCallDelta[] {
  const type = eventType ?? string(payload.type);
  const index = integer(payload.index) ?? 0;
  if (type === 'content_block_start') {
    const block = record(payload.content_block);
    if (block?.type !== 'tool_use') return [];
    const input = record(block.input);
    return [{
      index,
      ...(string(block.id) != null ? { id: string(block.id) } : {}),
      type: 'function',
      ...(string(block.name) != null ? { name: string(block.name) } : {}),
      ...(input && Object.keys(input).length > 0 ? { arguments: JSON.stringify(input) } : {}),
    }];
  }
  if (type === 'content_block_delta') {
    const delta = record(payload.delta);
    if (delta?.type !== 'input_json_delta' || string(delta.partial_json) == null) return [];
    return [{ index, arguments: string(delta.partial_json) }];
  }
  return [];
}

function responsesDeltas(eventType: string | null, payload: Record<string, unknown>): StreamToolCallDelta[] {
  const type = eventType ?? string(payload.type);
  const index = integer(payload.output_index) ?? integer(payload.index) ?? 0;
  if (type === 'response.output_item.added') {
    const item = record(payload.item);
    if (item?.type !== 'function_call') return [];
    return [{
      index,
      ...(string(item.call_id) != null ? { id: string(item.call_id) } : string(item.id) != null ? { id: string(item.id) } : {}),
      type: 'function',
      ...(string(item.name) != null ? { name: string(item.name) } : {}),
      ...(string(item.arguments) != null ? { arguments: string(item.arguments) } : {}),
    }];
  }
  if (type === 'response.function_call_arguments.delta' && string(payload.delta) != null) {
    return [{ index, arguments: string(payload.delta) }];
  }
  return [];
}

function geminiDeltas(payload: Record<string, unknown>): StreamToolCallDelta[] {
  const candidates = array(payload.candidates);
  const content = record(record(candidates?.[0])?.content);
  const parts = array(content?.parts);
  if (!parts) return [];
  return parts.flatMap((raw, index) => {
    const call = record(record(raw)?.functionCall);
    const name = string(call?.name);
    if (!call || !name) return [];
    return [{
      index,
      ...(string(call.id) != null ? { id: string(call.id) } : {}),
      type: 'function',
      name,
      arguments: JSON.stringify(record(call.args) ?? {}),
    }];
  });
}

function record(value: unknown): Record<string, unknown> | undefined {
  return value != null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function array(value: unknown): unknown[] | undefined {
  return Array.isArray(value) ? value : undefined;
}

function string(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function integer(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0 ? value : undefined;
}
