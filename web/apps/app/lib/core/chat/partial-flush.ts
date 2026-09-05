import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';
import { computeConversationActivityAt } from '../conversation-metadata';
import { PARTIAL_FLUSH_THRESHOLD_CHARS, PARTIAL_FLUSH_THRESHOLD_MS } from './chat-tuning';

/**
 * Proactive persistence for long streams: when the chunks accumulated while streaming pass a
 * threshold, streamingText is synced into message.text. Finer grained than a lifecycle flush,
 * to cover a tab crashing without warning.
 *
 * A flush only updates message.text; state stays generating, since the stream may still be
 * running. Syncing into the conversation triggers the persistence subscriber (a 500ms debounced
 * write to IDB) and re-renders every component subscribed to conversations, so the threshold
 * cannot be too small. pagehide already has a sessionStorage fallback; this throttle is mainly
 * there for browser crashes.
 */

export interface PartialFlushScheduler {
  /** Call once per arriving chunk; passing the threshold triggers a flush. */
  onChunk: (chunk: string) => void;
  /** Clean up when the stream finishes normally or is aborted. */
  dispose: () => void;
}

export function createPartialFlushScheduler(
  store: StoreApi<AppStore>,
  convId: string,
  msgId: string,
): PartialFlushScheduler {
  let accumulated = 0;
  let lastFlushAt = Date.now();
  let disposed = false;

  const flushNow = () => {
    if (disposed) return;
    flushPartialToMessage(store, convId, msgId);
  };

  return {
    onChunk: (chunk: string) => {
      if (disposed) return;
      accumulated += chunk.length;
      const now = Date.now();
      if (accumulated >= PARTIAL_FLUSH_THRESHOLD_CHARS || now - lastFlushAt >= PARTIAL_FLUSH_THRESHOLD_MS) {
        accumulated = 0;
        lastFlushAt = now;
        flushNow();
      }
    },
    dispose: () => {
      disposed = true;
    },
  };
}

/**
 * Immediately sync streamingText / streamingReasoningText into the given message.text /
 * message.reasoningText, converting state according to the state parameter.
 * Used by:
 *   - the entry guard (state='interrupted')
 *   - the lifecycle flush (state left undefined, so state is unchanged and stays generating)
 *
 * Reasoning: the partial reasoning accumulated while streaming has to land in
 * message.reasoningText too, or the part just thought through is lost on stop, on a conversation
 * switch, or on an unexpected abort.
 *
 * options.prevReasoning is the previous round's reasoning snapshot for continuations, taken from
 * interruptedMsg.reasoningText. It is omitted on a first round. The partial holds only this
 * round's new chunks and has to be concatenated with prevReasoning. On re-entry (the lifecycle
 * flush firing more than once) the same prevReasoning keeps concatenation idempotent.
 */
export interface FlushPartialOptions {
  /** The entry guard passes 'interrupted'; the lifecycle flush omits it, keeping generating and leaving state unchanged. */
  state?: 'interrupted';
  /** Previous round's reasoning snapshot for continuations, concatenated with this round's partial. */
  prevReasoning?: string;
}

export function flushPartialToMessage(
  store: StoreApi<AppStore>,
  convId: string,
  msgId: string,
  options: FlushPartialOptions = {},
): void {
  const { state, prevReasoning } = options;
  const stateSnap = store.getState();
  const partial = stateSnap.streamingTexts[convId] ?? '';
  // streamingReasoningTexts may be undefined in a mock store, so guard for it.
  const reasoningPartial = stateSnap.streamingReasoningTexts?.[convId] ?? '';
  const conv = stateSnap.conversations.find((c) => c.id === convId);
  if (!conv) return;
  const targetMsg = conv.messages.find((m) => m.id === msgId);
  if (!targetMsg) return;

  // Only update when the content actually changed, to avoid a pointless re-render.
  const newText = partial || targetMsg.text;
  const newState = state ?? targetMsg.state;
  // reasoning: the partial holds only this round's new chunks (continueAnswering does not inject
  // prev).
  //   first round: prevReasoning is empty -> use partial as-is
  //   continuation: prevReasoning = interruptedMsg.reasoningText -> `prev + '\n\n' + partial`
  //   re-entry: reconcatenate from the same prevReasoning the caller passed, overwriting
  //             targetMsg idempotently. Never read targetMsg as prev, or the concatenation the
  //             previous flush wrote would be treated as prev and duplicated.
  const trimmedReasoning = reasoningPartial.trim();
  let newReasoningText: string | undefined;
  if (!trimmedReasoning) {
    // No new chunks: keep prev (continuation) or the original value (first round, where prev and targetMsg are both empty).
    newReasoningText = prevReasoning || targetMsg.reasoningText;
  } else if (prevReasoning) {
    // Continuation: always concatenate from the prev passed in, which keeps it idempotent.
    newReasoningText = [prevReasoning, trimmedReasoning].join('\n\n');
  } else {
    // First round: use partial directly.
    newReasoningText = trimmedReasoning;
  }

  if (
    targetMsg.text === newText &&
    targetMsg.state === newState &&
    targetMsg.reasoningText === newReasoningText
  ) {
    return;
  }

  const updatedMessages = conv.messages.map((m) =>
    m.id === msgId
      ? {
          ...m,
          text: newText,
          state: newState,
          ...(newReasoningText ? { reasoningText: newReasoningText } : {}),
        }
      : m,
  );
  store.getState().updateConversation(convId, {
    messages: updatedMessages,
    updatedAt: computeConversationActivityAt(updatedMessages, conv.createdAt),
  });
}
