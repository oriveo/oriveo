/**
 * Generic, provider-agnostic parsing of the OpenAI Chat Completions content block array.
 *
 * Mistral's Magistral family (and any relay endpoint pointing at this protocol) does not use
 * reasoning_content; it turns delta.content / message.content into a block array:
 *   [{"type":"thinking","thinking":[{"type":"text","text":"..."}]},{"type":"text","text":"body"}]
 * While streaming, the end of the thinking section is marked by an empty thinking array
 * ([{"type":"thinking","thinking":[]}]), after which the body falls back to plain string deltas. This
 * is implemented as a general capability rather than an `if providerKind === "mistral"` branch, so a
 * relay pointed at Mistral's own endpoint also receives thinking deltas.
 */

import type { StreamEvent } from '../types';

/** Collapse a content block array into a StreamEvent sequence (thinking to reasoning, text to delta, image_url to image). */
export function parseContentBlockArray(parts: unknown[]): StreamEvent[] {
  const events: StreamEvent[] = [];
  for (const raw of parts) {
    if (!raw || typeof raw !== 'object') continue;
    const part = raw as Record<string, unknown>;
    if (part.type === 'thinking' && Array.isArray(part.thinking)) {
      // An empty thinking array is the streaming end marker and naturally produces zero events, so it needs no special case.
      for (const seg of part.thinking) {
        if (!seg || typeof seg !== 'object') continue;
        const text = (seg as Record<string, unknown>).text;
        if ((seg as Record<string, unknown>).type === 'text' && typeof text === 'string' && text) {
          events.push({ type: 'reasoning', content: text });
        }
      }
      continue;
    }
    if (part.type === 'text' && typeof part.text === 'string' && part.text) {
      events.push({ type: 'delta', content: part.text });
      continue;
    }
    // OpenRouter and others put generated images in the content block array; keep the original parsing behavior.
    const imageUrl = (part.image_url as Record<string, unknown> | undefined)?.url;
    if (part.type === 'image_url' && typeof imageUrl === 'string' && imageUrl) {
      events.push({ type: 'image', url: imageUrl });
    }
  }
  return events;
}
