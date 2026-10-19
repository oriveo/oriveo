/**
 * Conversation settings: inherit source and the normalization applied on close-to-save.
 * A created row goes through updateConversationInstructions; an uncreated row writes the store draft, which is written into the object on first send.
 */

import type { StoreApi } from 'zustand';
import type { Conversation } from '@oriveo/shared';
import { normalizeConversationInstructions } from '@oriveo/core/context/conversation-instructions';
import type { AppStore } from '../../store/app-store';
import { updateConversationInstructions } from '../../conversation-ops';
import { sameNormalizedID } from '../../../utils/id-utils';

function activityTime(conversation: Conversation): number {
  const t = Date.parse(conversation.updatedAt);
  return Number.isNaN(t) ? 0 : t;
}

/**
 * Inherit source: when the current instructions are empty, the instructions of the most recently updated non-deleted conversation other than the current one;
 * null if that conversation's instructions are empty or the current ones are non-empty (no shortcut shown). Conversations in the store are the non-deleted ones.
 */
export function carryOverSource(
  conversations: readonly Conversation[],
  currentId: string | null | undefined,
  currentInstructions: string,
): string | null {
  if (currentInstructions.trim() !== '') return null;
  let latest: Conversation | undefined;
  for (const c of conversations) {
    if (currentId && sameNormalizedID(c.id, currentId)) continue;
    if (!latest || activityTime(c) > activityTime(latest)) latest = c;
  }
  const source = latest?.instructions ?? '';
  return source.trim() === '' ? null : source;
}

/** Top-bar instruction pill: with a conversation show its instructions; in draft state show the pending store instructions (non-empty after normalization). */
export function instructionsBadgeVisible(conversation: Conversation | undefined, draft: string): boolean {
  const value = conversation ? (conversation.instructions ?? '') : draft;
  return normalizeConversationInstructions(value) !== '';
}

/** Value written on close-to-save: normalized; null if equal to the original (no write). */
export function settingsSaveValue(original: string, edited: string): string | null {
  const normalized = normalizeConversationInstructions(edited);
  return normalized === normalizeConversationInstructions(original) ? null : normalized;
}

/** Called when the Dialog closes: with a conversation write to it, without one write the store draft. */
export function commitConversationSettings(
  store: StoreApi<AppStore>,
  conversationId: string | null | undefined,
  original: string,
  edited: string,
): void {
  const value = settingsSaveValue(original, edited);
  if (value === null) return;
  if (conversationId) {
    updateConversationInstructions(store, conversationId, value);
  } else {
    store.getState().setDraftConversationInstructions(value);
  }
}
