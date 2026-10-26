/**
 * "Set as instruction" suggestion bar.
 * The pending suggestion lives in memory only (one at a time); the ignore streak is a local preference
 * keyed by conversation id.
 * The same fresh-send branch also generates a memory candidate in the background.
 * classify(text).suggestion routes the send — conversationInstruction → this bar, memory → the
 * "save to memory?" bar (memory-suggestion.ts), none → no bar.
 * The memory half follows the send's propose_memory mode — fallback keeps the v1 route,
 * tool skips it (the model proposes through the tool instead), none runs neither.
 * Propose v3 (memory-propose.v3 rules 2 / 5, context pipeline contract §10.1): in mode tool the lexical bar does not run; the bar
 * comes only from the model's instruct outcome (offerInstructSuggestion). The lexical bar (fallback / none, and the
 * fallback route a degraded tool send falls back to) only shows for detector languages in suggestionLanguages.
 */
import type { StoreApi } from 'zustand';
import type { ChatMessage } from '@oriveo/shared';
import { detectDirective } from '@oriveo/core/context/directive-detector';
import { DIRECTIVE_SUGGESTION_LANGUAGES } from '@oriveo/core/context/directive-lexicon';
import { classifyMemoryIntent } from '@oriveo/core/context/memory-intent';
import { CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS } from '@oriveo/core/context/conversation-instructions';
import { trimWhiteSpace } from '@oriveo/core/context/white-space';
import { sameNormalizedID } from '../../../utils/id-utils';
import type { AppStore } from '../../store/app-store';
import { updateConversationInstructions } from '../../conversation-ops';
import { getPreference, setPreference } from '../../../infra/storage/preferences';
import { getActiveUIDSync } from '../../../infra/storage/partition';
import { getSkillById } from '../../skills/query';
import { resolvePromptUseMemory } from '../prompt-injection';
import { createMemoryCandidateRepository } from '../../memory/memory-candidate-repository';
import { createMemoryItemRepository } from '../../memory/memory-item-repository';
import type { ProposeMemoryMode } from '@oriveo/core/context/memory-propose';
import {
  beginMemorySuggestion,
  resolveMemorySuggestion,
  showMemoryOffHint,
  isMemorySuggestionTicketCurrent,
  isMemorySuggestionTicketLatest,
  type MemorySuggestionTicket,
} from './memory-suggestion';

export interface DirectiveSuggestion {
  conversationId: string;
  messageId: string;
  /** Sentence to append: the detector span, or the trimmed full text when the span is empty. */
  sentence: string;
}

export const DIRECTIVE_SUGGESTION_MAX_IGNORES = 3;

const ignoreKey = (conversationId: string) => `directive_suggestion_ignores:${conversationId}`;

let pending: DirectiveSuggestion | null = null;
const listeners = new Set<() => void>();

function setPending(next: DirectiveSuggestion | null): void {
  if (pending === next) return;
  pending = next;
  for (const listener of listeners) listener();
}

function codePointLength(value: string): number {
  let n = 0;
  for (const _ of value) n += 1;
  return n;
}

function appendSentence(instructions: string, sentence: string): string {
  return instructions ? `${instructions}\n${sentence}` : sentence;
}

export function getDirectiveSuggestionIgnoreCount(conversationId: string): number {
  const value = getPreference<number>(ignoreKey(conversationId), 0);
  return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/** §10.1 display conditions shared by both sources: ignore streak, substring of the instructions, length cap. */
function offerSentence(conversationId: string, messageId: string, sentence: string, instructions: string): DirectiveSuggestion | null {
  if (getDirectiveSuggestionIgnoreCount(conversationId) >= DIRECTIVE_SUGGESTION_MAX_IGNORES) return null;
  if (!sentence || instructions.includes(sentence)) return null;
  if (codePointLength(appendSentence(instructions, sentence)) > CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS) return null;
  const suggestion: DirectiveSuggestion = { conversationId, messageId, sentence };
  setPending(suggestion);
  return suggestion;
}

/**
 * Lexical route: judge a freshly sent user message. Always replaces the previous pending suggestion
 * (a new message dismisses it without counting as an ignore). Only detector languages in suggestionLanguages offer.
 */
export function evaluateDirectiveSuggestion(input: {
  conversationId: string;
  messageId: string;
  text: string;
  instructions: string;
}): DirectiveSuggestion | null {
  setPending(null);
  const { conversationId, messageId, text, instructions } = input;
  if (classifyMemoryIntent(text).suggestion !== 'conversationInstruction') return null;
  const detection = detectDirective(text);
  if (!detection.isDirective || !DIRECTIVE_SUGGESTION_LANGUAGES.includes(detection.lang)) return null;
  return offerSentence(conversationId, messageId, trimWhiteSpace(detection.span) || trimWhiteSpace(text), instructions);
}

/**
 * Model route (mode tool): the turn's propose_memory instruct outcome. Dropped when a newer send started or the user
 * message is no longer the conversation's latest; otherwise the same display conditions as the lexical route.
 */
export function offerInstructSuggestion(
  store: StoreApi<AppStore>,
  ticket: MemorySuggestionTicket,
  sentence: string,
): DirectiveSuggestion | null {
  if (!isMemorySuggestionTicketLatest(store, ticket)) return null;
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, ticket.conversationId));
  return offerSentence(ticket.conversationId, ticket.messageId, sentence, conv?.instructions ?? '');
}

function evaluateLexicalForMessage(store: StoreApi<AppStore>, conversationId: string, message: ChatMessage): void {
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, conversationId));
  evaluateDirectiveSuggestion({
    conversationId,
    messageId: message.id,
    text: message.text ?? '',
    instructions: conv?.instructions ?? '',
  });
}

/**
 * Send-path entry: judge a new user message against the conversation's current instructions, and start the
 * turn's memory suggestion under assistantMessageId. Returns the ticket a tool-mode turn publishes through.
 */
export function offerDirectiveSuggestion(
  store: StoreApi<AppStore>,
  conversationId: string,
  message: ChatMessage,
  assistantMessageId: string,
  mode: ProposeMemoryMode,
): MemorySuggestionTicket {
  // Every fresh send drops the previous bars, whatever the mode.
  setPending(null);
  const ticket = beginMemorySuggestion(conversationId, message.id, assistantMessageId);
  if (mode === 'fallback') generateMemoryCandidate(store, ticket, message);
  else if (mode === 'none') evaluateLexicalForMessage(store, conversationId, message);
  return ticket;
}

/**
 * The fallback route of a fresh user message (mode fallback, or a tool send that fell back / degraded): the gated
 * lexical instruction bar, then background memory-candidate generation (never blocks the send, failures only warn).
 * useMemory follows prompt injection (conversation ?? skill ?? true); guests generate into the local partition.
 * A memory-routed message with memory off only shows the hint, otherwise a newly generated candidate becomes the bar.
 */
export function generateMemoryCandidate(store: StoreApi<AppStore>, ticket: MemorySuggestionTicket, message: ChatMessage): void {
  const { conversationId } = ticket;
  const text = message.text ?? '';
  if (isMemorySuggestionTicketCurrent(ticket)) evaluateLexicalForMessage(store, conversationId, message);
  if (classifyMemoryIntent(text).suggestion !== 'memory') return;
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, conversationId));
  const skill = conv?.skillId ? getSkillById(store, conv.skillId) : undefined;
  const useMemory = resolvePromptUseMemory(conv?.useMemory, skill?.useMemory);
  if (!useMemory) {
    showMemoryOffHint(ticket);
    return;
  }
  const uid = getActiveUIDSync();
  const folderId = conv?.folderID ?? null;
  void (async () => {
    // Lazy import: bootstrap pulls in the chat modules, a static import would form a cycle.
    const { getOrCreateStableWebDeviceId } = await import('../../bootstrap');
    const items = createMemoryItemRepository({ store, uid, deviceId: getOrCreateStableWebDeviceId() });
    const candidate = await createMemoryCandidateRepository({ uid, items }).generate({
      text, messageId: message.id, conversationId, folderId, useMemory,
    });
    resolveMemorySuggestion(store, ticket, candidate);
  })().catch((error: unknown) => {
    console.warn('[memory-candidate] generate failed', error);
  });
}

export function getPendingDirectiveSuggestion(): DirectiveSuggestion | null {
  return pending;
}

export function subscribeDirectiveSuggestion(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Accept: append to the conversation instructions and reset the ignore streak. Returns the undo action. */
export function acceptDirectiveSuggestion(store: StoreApi<AppStore>): (() => void) | null {
  const current = pending;
  if (!current) return null;
  setPending(null);
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, current.conversationId));
  if (!conv) return null;
  const previous = conv.instructions ?? '';
  updateConversationInstructions(store, current.conversationId, appendSentence(previous, current.sentence));
  setPreference(ignoreKey(current.conversationId), 0);
  return () => updateConversationInstructions(store, current.conversationId, previous);
}

export function ignoreDirectiveSuggestion(): void {
  const current = pending;
  if (!current) return;
  setPending(null);
  setPreference(ignoreKey(current.conversationId), getDirectiveSuggestionIgnoreCount(current.conversationId) + 1);
}

/** Drop the pending suggestion without counting an ignore (conversation switch). */
export function clearDirectiveSuggestion(): void {
  setPending(null);
}

export function __resetDirectiveSuggestionForTest(): void {
  pending = null;
}
