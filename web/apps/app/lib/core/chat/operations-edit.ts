/**
 * editAndResend - edit a historical user message and send it again.
 *
 * Deletes that message and everything after it, then calls sendMessage with the new text.
 */
import type { ChatMessage, Conversation, AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { getSyncAdapter } from '../sync-port';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import { cleanupCloudAttachments } from './cleanup-attachments';
import { sendMessage } from './operations-send';
import type { ChatOpCtx, SendHandle } from './operations';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { recalculateConversationCost } from './usage-tracking';

export function editAndResend(
  ctx: ChatOpCtx,
  params: {
    messageId: string;
    newText: string;
    conversation: Conversation;
    messages: ChatMessage[];
    provider: Provider;
    model: AIModel;
    reasoningMode: ReasoningMode;
    webSearchEnabled?: boolean;
    onNewConversation?: (convId: string) => void;
    onFailed?: (text: string) => void;
    libraryContextCancelledText?: string;
  },
): SendHandle | null {
  const { messageId, newText, conversation, messages, provider, model, reasoningMode, webSearchEnabled, onNewConversation, onFailed, libraryContextCancelledText } = params;

  const msgIndex = messages.findIndex((m) => m.id === messageId);
  if (msgIndex === -1) return null;

  const removedMsgs = messages.slice(msgIndex);
  const editedMessageQuote = messages[msgIndex].role === 'user'
    ? messages[msgIndex].quoteContext
    : undefined;
  const removedDeliveredIDs = removedMsgs.filter((m) => m.state === 'delivered').map((m) => m.id);
  const remaining = messages.slice(0, msgIndex);
  const remainingLastDelivered = [...remaining].reverse().find((m) => m.state === 'delivered');

  if (removedDeliveredIDs.length > 0) {
    getSyncAdapter()?.didDeleteMessages(removedDeliveredIDs, conversation.id, remainingLastDelivered);
  }
  cleanupCloudAttachments(removedMsgs);
  ctx.store.getState().updateConversation(conversation.id, {
    messages: remaining,
    ...deriveConversationMetadata(conversation, remaining),
    estimatedCost: recalculateConversationCost(remaining),
    updatedAt: computeConversationActivityAt(remaining, conversation.createdAt),
  });

  trackEvent('message_regenerated', {
    conversation_id: conversation.id,
    provider_kind: telemetryProviderKind(provider.kind),
    model_id: telemetryModelID(provider.kind, model.id),
    trigger: 'after_edit',
    removed_count: removedDeliveredIDs.length,
  });

  // An edited resend inherits no library citations: the evidence behind the previous answer,
  // whether found by research mode or named by the user, was for the old question. Pinning it to
  // the new message would force the new question to be answered from old evidence, and it would
  // draw document chips the user never selected. Only the draft text carries over.
  return sendMessage(ctx, {
    text: newText, prevMessages: remaining, conversation,
    provider, model, reasoningMode, webSearchEnabled,
    quoteContext: editedMessageQuote,
    libraryContextDocuments: [],
    libraryContextCancelledText,
    onNewConversation, onFailed,
  });
}
