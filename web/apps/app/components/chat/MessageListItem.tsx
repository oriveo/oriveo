'use client';

import { memo, useCallback } from 'react';
import type { ChatMessage, Conversation, Provider } from '@oriveo/shared';
import { MessageBubble, type SavedNoteRef } from './MessageBubble';

/** Middle layer that stabilizes the callback references for each message so the memo on MessageBubble actually holds */
export const MessageListItem = memo(function MessageListItem({
  messageId, message, provider, streamingText, prevRole,
  interactionLocked, onRetry, onRetryWithoutCustom, onEditAndResend, onContinueAnswering, onSwitchModel, conversationId, conversation, sourcePrompt,
  savedNoteRefs, isLastMessage,
}: {
  messageId: string; message: ChatMessage; provider: Provider | undefined; streamingText?: string; prevRole?: string;
  interactionLocked?: boolean;
  onRetry?: (id: string) => void; onRetryWithoutCustom?: (id: string) => void; onEditAndResend?: (id: string, text: string) => void;
  onContinueAnswering?: (id: string) => void; onSwitchModel?: () => void;
  conversationId?: string | null;
  conversation?: Conversation;
  sourcePrompt?: string;
  savedNoteRefs?: SavedNoteRef[];
  isLastMessage?: boolean;
}) {
  const handleRetry = useCallback(() => onRetry?.(message.id), [onRetry, message.id]);
  const handleRetryWithoutCustom = useCallback(() => onRetryWithoutCustom?.(message.id), [onRetryWithoutCustom, message.id]);
  const handleEdit = useCallback((newText: string) => onEditAndResend?.(message.id, newText), [onEditAndResend, message.id]);
  const handleContinue = useCallback(() => onContinueAnswering?.(message.id), [onContinueAnswering, message.id]);

  return (
    <div data-message-id={messageId} data-message-role={message.role}>
      <MessageBubble
        message={message}
        provider={provider}
        streamingText={streamingText}
        interactionLocked={interactionLocked}
        sameSpeaker={prevRole === message.role}
        onRetry={onRetry ? handleRetry : undefined}
        onRetryWithoutCustom={onRetryWithoutCustom ? handleRetryWithoutCustom : undefined}
        onEditAndResend={onEditAndResend ? handleEdit : undefined}
        onContinue={onContinueAnswering ? handleContinue : undefined}
        onSwitchModel={onSwitchModel}
        conversationId={conversationId ?? undefined}
        conversation={conversation}
        sourcePrompt={sourcePrompt}
        savedNoteRefs={savedNoteRefs}
        isLastMessage={isLastMessage}
      />
    </div>
  );
});
