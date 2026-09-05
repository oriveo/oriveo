import type { ChatMessage } from '@oriveo/shared';

export interface SearchMatch {
  messageId: string;
  messageIndex: number;
  ranges: { start: number; end: number }[];
}

export function searchConversation(
  messages: ChatMessage[],
  query: string,
): SearchMatch[] {
  if (!query.trim()) return [];

  const q = query.toLowerCase();
  const matches: SearchMatch[] = [];

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    const text = msg.text.toLowerCase();
    const ranges: { start: number; end: number }[] = [];

    let searchStart = 0;
    while (searchStart < text.length) {
      const idx = text.indexOf(q, searchStart);
      if (idx === -1) break;
      ranges.push({ start: idx, end: idx + q.length });
      searchStart = idx + 1;
    }

    if (ranges.length > 0) {
      matches.push({
        messageId: msg.id,
        messageIndex: i,
        ranges,
      });
    }
  }

  return matches;
}

export function highlightText(
  text: string,
  ranges: { start: number; end: number }[],
): { text: string; highlighted: boolean }[] {
  if (ranges.length === 0) return [{ text, highlighted: false }];

  const parts: { text: string; highlighted: boolean }[] = [];
  let lastEnd = 0;

  for (const range of ranges) {
    if (range.start > lastEnd) {
      parts.push({ text: text.slice(lastEnd, range.start), highlighted: false });
    }
    parts.push({ text: text.slice(range.start, range.end), highlighted: true });
    lastEnd = range.end;
  }

  if (lastEnd < text.length) {
    parts.push({ text: text.slice(lastEnd), highlighted: false });
  }

  return parts;
}
