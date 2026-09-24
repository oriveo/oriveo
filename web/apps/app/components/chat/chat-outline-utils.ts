import type { ChatMessage } from '@oriveo/shared';

/** Display threshold: the navigation rail mounts only above 3 user turns. */
export const OUTLINE_MIN_USER_TURNS = 3;

export interface OutlineTick {
  id: string;
  preview: string;
}

/**
 * The preview only looks at this many leading characters. A tick shows at most 48 of them, but
 * splitting the whole text cuts a message of hundreds of thousands of characters into an array of
 * lines, and the "first line" of a long message with no line breaks is the whole text, so every
 * tick derivation grew with message length.
 */
export const OUTLINE_PREVIEW_SCAN_LIMIT = 512;

/**
 * Derives the preview: take the first line, collapse runs of whitespace, trim.
 * A user message with attachments but no text falls back to the localized `attachmentLabel`.
 */
export function derivePreview(message: ChatMessage, attachmentLabel: string): string {
  const text = message.text ?? '';
  let scanEnd = Math.min(text.length, OUTLINE_PREVIEW_SCAN_LIMIT);
  // Never cut a surrogate pair in half.
  const last = text.charCodeAt(scanEnd - 1);
  if (scanEnd < text.length && last >= 0xd800 && last <= 0xdbff) scanEnd -= 1;
  const firstLine = text.slice(0, scanEnd).split('\n', 1)[0] ?? '';
  const collapsed = firstLine.replace(/\s+/g, ' ').trim();
  if (collapsed) return collapsed;
  if (message.attachments && message.attachments.length > 0) return attachmentLabel;
  return attachmentLabel;
}

/** Character limit for the tooltip preview, in bands by viewport width. */
export function previewCharLimit(viewportWidth: number): number {
  if (viewportWidth >= 1024) return 48;
  if (viewportWidth >= 768) return 32;
  return 24;
}

/** Maximum tooltip width in px. */
export function tooltipMaxWidth(viewportWidth: number): number {
  if (viewportWidth >= 1024) return 320;
  if (viewportWidth >= 768) return 240;
  return Math.min(220, Math.max(120, viewportWidth - 48));
}

/** Truncates to the character limit and appends an ellipsis; the character half of the two-stage clamp. */
export function clampPreview(preview: string, maxChars: number): string {
  if (preview.length <= maxChars) return preview;
  return `${preview.slice(0, maxChars).trimEnd()}…`;
}

/** Derives the user turn ticks from a message list. */
export function deriveOutlineTicks(messages: ChatMessage[], attachmentLabel: string): OutlineTick[] {
  return messages
    .filter((m) => m.role === 'user')
    .map((m) => ({ id: m.id, preview: derivePreview(m, attachmentLabel) }));
}

/** Tick sliding window, half-open [start, end). */
export interface OutlineRange {
  start: number;
  end: number;
}

/**
 * Current tick selection: at the true bottom the last tick wins, so a short conversation whose
 * head and tail are both visible still shows the newest; at the true top the first tick wins;
 * in between the candidate derived from the reading focus line is used.
 */
export function resolveOutlineActiveIndex(
  tickCount: number,
  focusIndex: number,
  atConversationStart: boolean,
  atConversationEnd: boolean,
): number {
  if (tickCount <= 0) return -1;
  if (atConversationEnd) return tickCount - 1;
  if (atConversationStart) return 0;
  return Math.max(0, Math.min(tickCount - 1, focusIndex));
}

/**
 * Tick sliding window with tail-aligned paging. Hundreds of turns are not all shown at once:
 * above `capacity` the ticks are paged from the tail, and the window is the page holding the
 * currently highlighted turn. The dot pattern does not move while paging within a page; only
 * crossing a page boundary switches the whole page (continuous centered sliding reads as
 * restless drifting).
 * Tail alignment keeps the last page always full; head alignment would leave a remainder page,
 * so entering a conversation would show only a few stray dots. A partial page can therefore only
 * appear at the top of the oldest history. With no highlight (currentIndex < 0) the tail page is
 * used.
 */
export function outlineVisibleRange(totalCount: number, currentIndex: number, capacity: number): OutlineRange {
  if (totalCount <= 0) return { start: 0, end: 0 };
  if (capacity <= 0 || totalCount <= capacity) return { start: 0, end: totalCount };
  const cur = currentIndex >= 0 ? Math.min(currentIndex, totalCount - 1) : totalCount - 1;
  const pageFromEnd = Math.floor((totalCount - 1 - cur) / capacity);
  const end = totalCount - pageFromEnd * capacity;
  return { start: Math.max(0, end - capacity), end };
}
