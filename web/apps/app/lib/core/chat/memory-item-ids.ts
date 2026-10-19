/**
 * memoryItemIds on an assistant message: once the request is actually sent, the final plan's memoryIds (the one after overflow recompute) are stored on the message.
 * A refused send / failed preflight has no plan sent, so nothing is stored. Local only: the message sync whitelist does not carry it, and backup export strips it.
 */
import type { ChatMessage } from '@oriveo/shared';

/**
 * The field is written only when there are ids (an empty array is not written). With no ids: continuing an existing answer (continue) keeps the old value;
 * otherwise (new answer, regenerate) the old value is dropped so the previous request's record is not carried over.
 */
export function withMemoryItemIds<T extends ChatMessage>(
  message: T,
  memoryIds: readonly string[],
  appendToExisting: boolean,
): T {
  if (memoryIds.length > 0) return { ...message, memoryItemIds: [...memoryIds] };
  if (appendToExisting || message.memoryItemIds === undefined) return message;
  const next = { ...message };
  delete next.memoryItemIds;
  return next;
}
