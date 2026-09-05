/**
 * Shared response helpers, all pure: SSE headers, citation URL normalization, and extracting the
 * user's latest prompt.
 * downloadImageAsDataURL performs fetch IO and therefore stays out of this module.
 */

import type { ProxyMessage } from './runtime';

export function streamResponseHeaders(): Record<string, string> {
  return {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
  };
}

export function normalizeCitationURL(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return '';
  try {
    const parsed = new URL(trimmed);
    parsed.hash = '';
    parsed.search = '';
    return parsed.toString().replace(/\/+$/, '');
  } catch {
    return trimmed.replace(/\/+$/, '');
  }
}

export function extractLatestUserPrompt(messages: ProxyMessage[]): string | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message.role !== 'user') continue;

    const content =
      typeof message.content === 'string'
        ? message.content
        : message.content
            .flatMap((part) => (part.type === 'text' ? [part.text] : []))
            .join('\n\n');

    const prompt = content.trim();
    if (prompt) return prompt;
  }

  return null;
}
