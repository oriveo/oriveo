/**
 * "Set as instruction" suggestion bar (P4·U3 contract item 5).
 * The pending suggestion lives in memory only (one at a time); the ignore streak is a local preference
 * keyed by conversation id.
 * The same fresh-send branch also generates a memory candidate in the background (P6·U2 contract item 3).
 * P6·U3: classify(text).suggestion routes the send — conversationInstruction → this bar, memory → the
 * "save to memory?" bar (memory-suggestion.ts), none → no bar.
 * P10 contract item 2: the memory half follows the send's propose_memory mode — fallback keeps the v1 route,
 * tool skips it (the model proposes through the tool instead), none runs neither. The instruction bar is unchanged.
 */
import type { StoreApi } from 'zustand';
import type { ChatMessage } from '@oriveo/shared';
import { detectDirective } from '@oriveo/core/context/directive-detector';
import { classifyMemoryIntent } from '@oriveo/core/context/memory-intent';
import { CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS } from '@oriveo/core/context/conversation-instructions';
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

/**
 * Judge a freshly sent user message. Always replaces the previous pending suggestion
 * (a new message dismisses it without counting as an ignore).
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
  if (getDirectiveSuggestionIgnoreCount(conversationId) >= DIRECTIVE_SUGGESTION_MAX_IGNORES) return null;
  const detection = detectDirective(text);
  if (!detection.isDirective) return null;
  const sentence = detection.span.trim() || text.trim();
  if (!sentence || instructions.includes(sentence)) return null;
  if (codePointLength(appendSentence(instructions, sentence)) > CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS) return null;
  const suggestion: DirectiveSuggestion = { conversationId, messageId, sentence };
  setPending(suggestion);
  return suggestion;
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
  const conv = store.getState().conversations.find((c) => sameNormalizedID(c.id, conversationId));
  evaluateDirectiveSuggestion({
    conversationId,
    messageId: message.id,
    text: message.text ?? '',
    instructions: conv?.instructions ?? '',
  });
  // Every fresh send drops the previous "save to memory?" bar, whatever the mode.
  const ticket = beginMemorySuggestion(conversationId, message.id, assistantMessageId);
  if (mode === 'fallback') generateMemoryCandidate(store, ticket, message);
  return ticket;
}

/**
 * Background memory-candidate generation for a fresh user message: never blocks the send, failures only warn.
 * useMemory follows prompt injection (conversation ?? skill ?? true); guests generate into the local partition.
 * A memory-routed message with memory off only shows the hint, otherwise a newly generated candidate becomes the bar.
 */
export function generateMemoryCandidate(store: StoreApi<AppStore>, ticket: MemorySuggestionTicket, message: ChatMessage): void {
  const { conversationId } = ticket;
  const text = message.text ?? '';
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
