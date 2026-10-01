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
    ? anthropicDeltas(eventType, payload, state)
    : protocol === 'openai_responses'
      ? responsesDeltas(eventType, payload)
      : geminiDeltas(payload);
  const events: StreamEvent[] = deltas.length > 0 ? [{ type: 'tool_calls', toolCalls: deltas }] : [];
  if (observesWebSearchStart(protocol, eventType, payload, deltas)) {
    events.push({ type: 'activity', activity: 'web_search' });
  }
  return events;
}

/**
 * The wire signal for "a web search has started". Only the structured frame each protocol uses
 * to say a search was launched counts: an ordinary function / tool_use and an unknown server
 * tool name never do. Falling back to the neutral pause wording is better than reporting some
 * other tool as a search.
 */
function observesWebSearchStart(
  protocol: ToolCallProtocol,
  eventType: string | null,
  payload: Record<string, unknown>,
  deltas: StreamToolCallDelta[],
): boolean {
  const type = eventType ?? string(payload.type);
  if (protocol === 'anthropic_messages') {
    const block = record(payload.content_block);
    return type === 'content_block_start' && block?.type === 'server_tool_use' && block.name === 'web_search';
  }
  if (protocol === 'openai_responses') {
    return type === 'response.output_item.added' && record(payload.item)?.type === 'web_search_call';
  }
  // Moonshot's built-in search is a tool call named `$web_search`, which the tool loop echoes
  // back at the end of the leg.
  if (protocol === 'openai_chat') return deltas.some((delta) => delta.name === '$web_search');
  return false;
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

function anthropicDeltas(
  eventType: string | null,
  payload: Record<string, unknown>,
  state?: Record<string, unknown>,
): StreamToolCallDelta[] {
  const type = eventType ?? string(payload.type);
  const index = integer(payload.index) ?? 0;
  if (type === 'content_block_start') {
    const block = record(payload.content_block);
    if (block?.type !== 'tool_use') return [];
    toolUseIndexes(state)?.add(index);
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
    // A server_tool_use block (the built-in web_search, for one) streams its input as
    // input_json_delta too. The provider runs it itself, so it is not a tool call handed to the
    // client; without filtering by the owning block the stream would end with a nameless tool
    // call that nothing can execute.
    const owned = toolUseIndexes(state);
    if (owned && !owned.has(index)) return [];
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

/**
 * Indexes of the `tool_use` blocks this stream has opened. Returns undefined, and so filters
 * nothing, when the caller passes no per-stream state.
 */
function toolUseIndexes(state: Record<string, unknown> | undefined): Set<number> | undefined {
  if (!state) return undefined;
  if (!(state.anthropicToolUseIndexes instanceof Set)) state.anthropicToolUseIndexes = new Set<number>();
  return state.anthropicToolUseIndexes as Set<number>;
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
