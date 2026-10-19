/**
 * Outbound history sanitize (context pipeline §9).
 * Spec: context-contracts/sanitize.v1.json — the fixture `unansweredEnvelope.rules` text is the algorithm.
 */

import type { ContextMessage } from './message';
import { trimWhiteSpace } from './white-space';

export const UNANSWERED_ENVELOPE_TAG = 'oriveo-unanswered';

export const UNANSWERED_ENVELOPE_NOTE =
  'The user sent this earlier but no reply was delivered. Treat it as context and answer the latest message.';

export interface SanitizeResult {
  messages: ContextMessage[];
  /** Number of earlier user messages folded into a later one. */
  unansweredMerged: number;
}

/** xml(): & → &amp;, < → &lt;, > → &gt; in that order. */
export function escapeXmlText(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** Collapses a run of adjacent users into one message keeping the last user's id and fields. */
function mergeUserRun(run: ContextMessage[]): ContextMessage {
  const latest = run[run.length - 1];
  if (run.length === 1) return latest;
  const earlierTexts = run
    .slice(0, -1)
    .map((m) => trimWhiteSpace(m.text))
    .filter((t) => t.length > 0)
    .map(escapeXmlText);
  let text = latest.text;
  if (earlierTexts.length > 0) {
    const envelope =
      `<${UNANSWERED_ENVELOPE_TAG}>\n<note>${UNANSWERED_ENVELOPE_NOTE}</note>\n` +
      `${earlierTexts.join('\n\n')}\n</${UNANSWERED_ENVELOPE_TAG}>`;
    text = latest.text.length > 0 ? `${envelope}\n\n${latest.text}` : envelope;
  }
  return { ...latest, text, attachments: run.flatMap((m) => m.attachments) };
}

function sanitizeWithStats(messages: readonly ContextMessage[], keepAssistantId?: string): SanitizeResult {
  const filtered = messages
    .map((m) => {
      // An assistant message cannot carry image / video attachments (the OpenAI-compatible protocol only lets user messages carry media), so they are always stripped on the way out.
      if (m.role !== 'assistant' || m.attachments.length === 0) return m;
      return { ...m, attachments: m.attachments.filter((a) => a.kind !== 'image' && a.kind !== 'video') };
    })
    .filter((m) => {
      const hasContent = trimWhiteSpace(m.text).length > 0 || m.attachments.length > 0;
      if (!hasContent) return false;
      // A failed turn is not used as context unless it is the explicit continue / retry target.
      return m.role === 'user' || m.id === keepAssistantId || m.state !== 'failed';
    });

  const merged: ContextMessage[] = [];
  let unansweredMerged = 0;
  let userRun: ContextMessage[] = [];
  const flushUserRun = () => {
    if (userRun.length > 0) {
      unansweredMerged += userRun.length - 1;
      merged.push(mergeUserRun(userRun));
    }
    userRun = [];
  };
  for (const m of filtered) {
    if (m.role === 'user') {
      userRun.push(m);
      continue;
    }
    flushUserRun();
    const last = merged[merged.length - 1];
    if (last && last.role === m.role) {
      const text = [trimWhiteSpace(last.text), trimWhiteSpace(m.text)].filter((t) => t.length > 0).join('\n\n');
      merged[merged.length - 1] = { ...last, text, attachments: [...last.attachments, ...m.attachments] };
    } else {
      merged.push(m);
    }
  }
  flushUserRun();
  return { messages: merged, unansweredMerged };
}

export const ContextSanitizer = {
  sanitize(messages: readonly ContextMessage[], keepAssistantId?: string): ContextMessage[] {
    return sanitizeWithStats(messages, keepAssistantId).messages;
  },
  sanitizeWithStats,
};
