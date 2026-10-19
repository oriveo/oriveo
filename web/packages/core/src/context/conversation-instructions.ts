/**
 * Conversation instructions normalization (contract: context-contracts/conversation-instructions.v1.json, pipeline §7.1).
 * Every value passes through here before it is stored locally: user edit, remote sync ingest, backup import.
 */

import { trimWhiteSpace } from './white-space';

/** Maximum stored length, in Unicode code points. */
export const CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS = 8000;

/** Whitespace-only → ""; otherwise the original text (not trimmed) cut to the first max code points. */
export function normalizeConversationInstructions(text: string): string {
  if (trimWhiteSpace(text) === '') return '';
  // UTF-16 length bounds the code-point count from above, so short text needs no split.
  if (text.length <= CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS) return text;
  return [...text].slice(0, CONVERSATION_INSTRUCTIONS_MAX_CODE_POINTS).join('');
}
