/**
 * "Save to memory?" suggestion bar state.
 * Memory only, one at a time: a fresh send / conversation switch / restart drops it (not an ignore).
 * A background generate result only lands when no newer send happened and its message is still the
 * conversation's latest user message.
 * The bar hangs under the turn's assistant message (shown once it stops streaming);
 * messageId stays the user message the candidate came from. In tool mode the first created propose_memory
 * candidate of the turn becomes the bar.
 */
import type { StoreApi } from 'zustand';
import type { MemoryCandidateRecord } from '@oriveo/core/context/memory-intent';
import { sameNormalizedID } from '../../../utils/id-utils';
import type { AppStore } from '../../store/app-store';

export type MemorySuggestion =
  | {
      status: 'candidate';
      conversationId: string;
      messageId: string;
      assistantMessageId: string;
      candidate: MemoryCandidateRecord;
    }
  /** Memory is off for the conversation: the bar only shows the hint, no buttons and no candidate. */
  | { status: 'memoryOff'; conversationId: string; messageId: string; assistantMessageId: string };

/** Ticket of one fresh send; stale tickets cannot publish a suggestion. */
export interface MemorySuggestionTicket {
  readonly generation: number;
  readonly conversationId: string;
  readonly messageId: string;
  /** The turn's assistant message; the bar hangs under it. */
  readonly assistantMessageId: string;
}

let pending: MemorySuggestion | null = null;
let generation = 0;
let inFlight: MemorySuggestionTicket | null = null;
/** Generation whose first propose_memory candidate already became the bar. */
let proposedGeneration = -1;
const listeners = new Set<() => void>();

function setPending(next: MemorySuggestion | null): void {
  if (pending === next) return;
  pending = next;
  for (const listener of listeners) listener();
}

function isCurrent(ticket: MemorySuggestionTicket): boolean {
  return ticket.generation === generation;
}

function latestUserMessageId(store: StoreApi<AppStore>, conversationId: string): string | null {
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, conversationId));
  const messages = conv?.messages ?? [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (messages[i].role === 'user') return messages[i].id;
  }
  return null;
}

/** The ticket's send is still the latest one and its user message is still the conversation's latest. */
export function isMemorySuggestionTicketLatest(store: StoreApi<AppStore>, ticket: MemorySuggestionTicket): boolean {
  return isCurrent(ticket) && latestUserMessageId(store, ticket.conversationId) === ticket.messageId;
}

/** The ticket's send is still the latest one. */
export function isMemorySuggestionTicketCurrent(ticket: MemorySuggestionTicket): boolean {
  return isCurrent(ticket);
}

/** A fresh send: drop the current bar and invalidate any in-flight generate result. */
export function beginMemorySuggestion(
  conversationId: string,
  messageId: string,
  assistantMessageId: string,
): MemorySuggestionTicket {
  generation += 1;
  const ticket: MemorySuggestionTicket = { generation, conversationId, messageId, assistantMessageId };
  inFlight = ticket;
  setPending(null);
  return ticket;
}

/** suggestion=memory with useMemory=false: hint only. */
export function showMemoryOffHint(ticket: MemorySuggestionTicket): void {
  if (!isCurrent(ticket)) return;
  inFlight = null;
  setPending({
    status: 'memoryOff',
    conversationId: ticket.conversationId,
    messageId: ticket.messageId,
    assistantMessageId: ticket.assistantMessageId,
  });
}

/** Generate finished: publish the new candidate if the ticket is still current and the message is still the latest. */
export function resolveMemorySuggestion(
  store: StoreApi<AppStore>,
  ticket: MemorySuggestionTicket,
  candidate: MemoryCandidateRecord | null,
): void {
  if (!isCurrent(ticket)) return;
  inFlight = null;
  if (!candidate) return;
  if (latestUserMessageId(store, ticket.conversationId) !== ticket.messageId) return;
  publishCandidate(ticket, candidate);
}

/** Tool mode: the turn's first created propose_memory candidate becomes the bar; later ones only stay pending. */
export function resolveProposedMemorySuggestion(
  store: StoreApi<AppStore>,
  ticket: MemorySuggestionTicket,
  candidate: MemoryCandidateRecord | null,
): void {
  if (!isCurrent(ticket) || !candidate || proposedGeneration === ticket.generation) return;
  proposedGeneration = ticket.generation;
  if (latestUserMessageId(store, ticket.conversationId) !== ticket.messageId) return;
  publishCandidate(ticket, candidate);
}

function publishCandidate(ticket: MemorySuggestionTicket, candidate: MemoryCandidateRecord): void {
  setPending({
    status: 'candidate',
    conversationId: ticket.conversationId,
    messageId: ticket.messageId,
    assistantMessageId: ticket.assistantMessageId,
    candidate,
  });
}

export function getPendingMemorySuggestion(): MemorySuggestion | null {
  return pending;
}

export function subscribeMemorySuggestion(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Drop the bar and any in-flight result unless they belong to the given (shown) conversation. */
export function clearMemorySuggestionOutside(conversationId: string | null | undefined): void {
  const pendingElsewhere = pending !== null && pending.conversationId !== conversationId;
  const inFlightElsewhere = inFlight !== null && inFlight.conversationId !== conversationId;
  if (pendingElsewhere || inFlightElsewhere) clearMemorySuggestion();
}

/** Drop the bar and invalidate any in-flight result (not an ignore). */
export function clearMemorySuggestion(): void {
  generation += 1;
  inFlight = null;
  setPending(null);
}

export function __resetMemorySuggestionForTest(): void {
  generation += 1;
  inFlight = null;
  pending = null;
}
