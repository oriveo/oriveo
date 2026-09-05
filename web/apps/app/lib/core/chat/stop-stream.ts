import type { StoreApi } from 'zustand';
import type { ChatMessage, Conversation } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';

export interface StopStreamOptions {
  /** Stream start timestamp, used for the telemetry elapsed_ms; recorded as 0 when omitted. */
  streamStartedAt?: number | null;
  /**
   * Snapshot of the previous turn's reasoning when continuing an answer, taken from
   * interruptedMsg.reasoningText. The partial only holds this turn's new chunks, with no prev
   * injected, so it has to be concatenated with initialReasoning to be complete.
   * When omitted it is read from lastMsg.reasoningText, which is empty on a first turn and still
   * correct while continuing as long as partial-flush has not run. Once partial-flush has run,
   * lastMsg.reasoningText already contains the concatenation, so the entry prev must be passed
   * explicitly for this to stay idempotent.
   */
  initialReasoning?: string;
  /**
   * Id of the assistant message this stream is bound to, taken from the active-streams session.
   * Without it the code falls back to locating the last message, but a retry or a continuation does
   * not necessarily target the last one, so the wrong message would be stopped.
   */
  msgId?: string;
  /** Stopping a continuation or a Managed recovery stream; affects telemetry bucketing only, never persistence semantics. */
  isRecovery?: boolean;
}

export function stopStream(
  store: StoreApi<AppStore>,
  conversation: Conversation,
  messages: ChatMessage[],
  streamingText: string,
  abortFn: (() => void) | null,
  options: StopStreamOptions = {},
) {
  const { streamStartedAt = null, initialReasoning, msgId, isRecovery } = options;
  abortFn?.();
  const targetMsg = msgId ? messages.find((m) => m.id === msgId) : messages[messages.length - 1];
  if (targetMsg?.role === 'assistant' && targetMsg.state === 'generating') {
    const currentText = streamingText || '';
    // Write the streamed reasoning partial into message.reasoningText as well, so the thinking is not lost.
    // The partial only holds this turn's new chunks (continueAnswering injects no prev), so a
    // continuation must concatenate initialReasoning, the entry prev snapshot, rather than overwrite
    // it, or the reasoning already delivered in the previous turn is lost. This matches the
    // continueAnswering done path in operations.ts, which joins
    // `[interruptedMsg.reasoningText, reasoningText.trim()]` with a blank line. On a first turn
    // initialReasoning is empty, which is equivalent to using the partial directly.
    // streamingReasoningTexts may be undefined in a mock store, hence the fallback.
    const reasoningPartial = (store.getState().streamingReasoningTexts?.[conversation.id] ?? '').trim();
    const prevReasoning = initialReasoning ?? targetMsg.reasoningText ?? '';
    const mergedReasoningText = prevReasoning
      ? [prevReasoning, reasoningPartial].filter(Boolean).join('\n\n')
      : (reasoningPartial || undefined);
    const interruptedMessages = messages.map((message) =>
      message.id === targetMsg.id
        ? {
            ...message,
            text: currentText,
            state: 'interrupted' as const,
            ...(mergedReasoningText ? { reasoningText: mergedReasoningText } : {}),
          }
        : message,
    );
    store.getState().updateConversation(conversation.id, {
      messages: interruptedMessages,
      ...deriveConversationMetadata(conversation, interruptedMessages),
      updatedAt: computeConversationActivityAt(interruptedMessages, conversation.createdAt),
    });
    // partial  
    trackEvent('chat_message_stopped', {
      conversation_id: conversation.id,
      partial_length: currentText.length,
      provider_kind: telemetryProviderKind(conversation.providerKind),
      model_id: telemetryModelID(conversation.providerKind, conversation.modelID ?? 'unknown'),
      elapsed_ms: streamStartedAt ? Date.now() - streamStartedAt : 0,
      // Separates a stop the user asked for from one issued while recovering a stuck stream.
      is_recovery: Boolean(isRecovery),
    });
  }
}
