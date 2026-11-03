import type { ChatMessage } from '@oriveo/shared';
import { ProviderErrorObject } from '@oriveo/core/providers/errors';
import { ContextOverflowClassifier } from '@oriveo/core/context/overflow';
import { StopReasonResolver } from '@oriveo/core/context/stop-reason';
import type { StreamFinish } from '@oriveo/core/context/stream-finish';
import type { ProviderError } from '../providers/errors';

/** The parts of an assistant reply the user can see in the bubble. */
export type VisibleReplyParts = Partial<Pick<ChatMessage,
  'text' | 'attachments' | 'unhandledToolCalls' | 'toolSteps' | 'toolFallbackNotice' | 'searchErrorCard'
>> & {
  /** The turn raised a memory suggestion bar; that bar is what the user sees even with an empty tail. */
  memoryProposed?: boolean;
};

/**
 * Whether a finished reply shows anything. Reasoning alone does not count: a reply with
 * only a thinking block (or only a skill marker, which is stripped before it reaches `text`) is an empty reply.
 */
export function hasVisibleReplyContent(reply: VisibleReplyParts): boolean {
  return (reply.text ?? '').trim() !== ''
    || (reply.attachments?.length ?? 0) > 0
    || (reply.unhandledToolCalls?.length ?? 0) > 0
    || (reply.toolSteps?.length ?? 0) > 0
    || Boolean(reply.toolFallbackNotice)
    || Boolean(reply.searchErrorCard)
    || Boolean(reply.memoryProposed);
}

/**
 * The failure a reply with nothing visible ends with. The verdict is made on the client, so the source is not
 * `provider`: the error card then renders the localized `emptyResponse` copy instead of a raw upstream text.
 */
export function emptyReplyError(): ProviderErrorObject {
  return new ProviderErrorObject({
    kind: 'emptyResponse',
    title: 'Empty Response',
    message: 'The model finished without returning any content.',
    source: 'oriveo',
  });
}

/**
 * In-stream overflow failure: the stream ended cleanly (HTTP 200, no error body) but its stop reason says the context
 * window ran out, so `isContextOverflowFailure` cannot see it; the marker lets the failed turn record
 * context_window_exceeded. The message carries only the upstream finishRaw (technical text, not authored copy).
 */
const IN_STREAM_OVERFLOW = Symbol('inStreamContextOverflow');

export function inStreamOverflowFailure(finishRaw: string | null | undefined): ProviderError {
  const raw = finishRaw?.trim() || 'context_window_exceeded';
  return Object.assign({ kind: 'badRequest', title: raw, message: raw, source: 'provider' } as ProviderError, {
    [IN_STREAM_OVERFLOW]: true,
  });
}

export function isInStreamOverflowFailure(err: unknown): boolean {
  return Boolean(err && typeof err === 'object' && (err as { [IN_STREAM_OVERFLOW]?: unknown })[IN_STREAM_OVERFLOW] === true);
}

/**
 * The failure for a finished reply with nothing visible. An upstream context-window overflow is the more specific
 * failure and wins (e.g. reasoning streamed, then the window ran out); empty_response is only the fallback.
 */
export function noVisibleReplyError(finish: StreamFinish | undefined): ProviderError | ProviderErrorObject {
  const overflow = finish
    && ContextOverflowClassifier.isOverflow(StopReasonResolver.resolve(finish.family, finish.ended, finish.finishRaw, false));
  return overflow ? inStreamOverflowFailure(finish.finishRaw) : emptyReplyError();
}

/** The text a round added on top of `initialText` (a continuation streams the earlier text back first). */
export function newReplyText(fullText: string, initialText: string): string {
  return initialText && fullText.startsWith(initialText) ? fullText.slice(initialText.length) : fullText;
}
