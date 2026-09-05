import type { StreamToolCallDelta } from './types';

export interface CompletedToolCall {
  id: string;
  name: string;
  arguments: string;
}

export type ToolCallAccumulator = Map<number, StreamToolCallDelta>;

export function mergeToolCallDeltas(
  target: ToolCallAccumulator,
  deltas: readonly StreamToolCallDelta[],
): void {
  for (const delta of deltas) {
    const previous = target.get(delta.index) ?? { index: delta.index };
    target.set(delta.index, {
      index: delta.index,
      id: nonEmpty(delta.id) ?? previous.id,
      type: nonEmpty(delta.type) ?? previous.type,
      name: nonEmpty(previous.name) ?? nonEmpty(delta.name),
      arguments: `${previous.arguments ?? ''}${delta.arguments ?? ''}`,
    });
  }
}

export function finalizeToolCalls(
  target: ReadonlyMap<number, StreamToolCallDelta>,
  fallbackNamespace: string,
): CompletedToolCall[] {
  return [...target.values()]
    .sort((left, right) => left.index - right.index)
    .map((call, index) => ({
      id: nonEmpty(call.id) ?? `${fallbackNamespace}_${index + 1}`,
      name: nonEmpty(call.name) ?? 'unknown_tool',
      arguments: call.arguments ?? '',
    }));
}

function nonEmpty(value: string | undefined): string | undefined {
  return value?.trim() ? value : undefined;
}
