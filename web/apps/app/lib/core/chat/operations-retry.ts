/**
 * retryMessage - retry an assistant message.
 *
 * Failed messages: keep the original user message and revive the original assistant message,
 * without adding a duplicate user bubble.
 * Delivered or interrupted messages: truncate the original assistant message and everything after
 * it, then generate a new assistant message.
 */
import type { ChatMessage, Conversation, AIModel, Provider, ReasoningMode } from '@oriveo/shared';
import { getSyncAdapter } from '../sync-port';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import { cleanupCloudAttachments } from './cleanup-attachments';
import { sendMessage } from './operations-send';
import type { ChatOpCtx, SendHandle } from './operations';
import { getProviderInstanceDisplayName } from '../providers/provider-display';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { recalculateConversationCost } from './usage-tracking';
import { libraryDocumentRefsFromCitations } from './library-direct-context';
import type { LibraryFailurePresentation } from './library-failure';

export interface RetryMessageParams {
  messageId: string;
  conversation: Conversation;
  messages: ChatMessage[];
  provider: Provider;
  model: AIModel;
  reasoningMode: ReasoningMode;
  webSearchEnabled?: boolean;
  onNewConversation?: (convId: string) => void;
  onFailed?: (text: string) => void;
  libraryContextCancelledText?: string;
  /** Retrying a message that names documents re-reads them, so a library_* failure needs localized copy plus the recovery card CTA. */
  libraryFailurePresentation?: LibraryFailurePresentation;
  /** Explicit user-confirmed custom recovery; never the default retry path. */
  excludeCustomFragments?: boolean;
  excludeCustomFragmentOwners?: Array<'web' | 'reasoning' | 'generation'>;
  capabilityRecipeOmissions?: Array<{ recipeRef: string; locatedPointers: string[] }>;
  capabilityRecipeResendOwners?: Array<'web' | 'reasoning' | 'generation'>;
  excludeCapabilityOwners?: Array<'web' | 'reasoning' | 'generation'>;
}

export type RetrySendOperation = (
  ctx: ChatOpCtx,
  params: Parameters<typeof sendMessage>[1],
) => SendHandle;

export function retryMessage(
  ctx: ChatOpCtx,
  params: RetryMessageParams,
): SendHandle | null {
  return retryMessageWithSender(ctx, params, sendMessage);
}

export function retryMessageWithSender(
  ctx: ChatOpCtx,
  params: RetryMessageParams,
  send: RetrySendOperation,
): SendHandle | null {
  const { messageId, conversation, messages, provider, model, reasoningMode, webSearchEnabled, onNewConversation, onFailed, libraryContextCancelledText, libraryFailurePresentation, excludeCustomFragments = false, excludeCustomFragmentOwners = [], capabilityRecipeOmissions = [], capabilityRecipeResendOwners = [], excludeCapabilityOwners = [] } = params;
  const explicitModelControlResend = excludeCustomFragmentOwners.length > 0
    || capabilityRecipeOmissions.length > 0
    || capabilityRecipeResendOwners.length > 0;

  const msgIndex = messages.findIndex((m) => m.id === messageId);
  if (msgIndex === -1) return null;

  // Walk back to the user turn this answer belongs to; that turn is what gets resent.
  let userMsgIndex = -1;
  for (let i = msgIndex; i >= 0; i--) {
    if (messages[i].role === 'user') { userMsgIndex = i; break; }
  }
  if (userMsgIndex === -1) return null;

  const userMsg = messages[userMsgIndex];
  const retryingFailedAssistant = messages[msgIndex].role === 'assistant' && messages[msgIndex].state === 'failed';
  const removedMsgs = messages.slice(retryingFailedAssistant ? msgIndex : userMsgIndex);
  const removedDeliveredIDs = removedMsgs.filter((m) => m.state === 'delivered').map((m) => m.id);
  const remaining = messages.slice(0, retryingFailedAssistant ? msgIndex : userMsgIndex);
  const remainingLastDelivered = [...remaining].reverse().find((m) => m.state === 'delivered');
  const failedAssistant = messages[msgIndex];
  // Carry over the documents the failed answer had already cited, so the retry is grounded on
  // the same sources instead of paying for the research a second time.
  const libraryContextDocuments = !explicitModelControlResend && failedAssistant.role === 'assistant' &&
    !failedAssistant.libraryResearchEnabled
    ? libraryDocumentRefsFromCitations(failedAssistant.citations)
    : [];
  const shouldReuseFailedAssistant = retryingFailedAssistant;
  const preservePartialAssistant = explicitModelControlResend && shouldReuseFailedAssistant;

  if (removedDeliveredIDs.length > 0) {
    getSyncAdapter()?.didRegenerate(removedDeliveredIDs, conversation.id, remainingLastDelivered);
  }
  cleanupCloudAttachments(retryingFailedAssistant
    ? (preservePartialAssistant ? removedMsgs.slice(1) : removedMsgs)
    : removedMsgs.slice(1));
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
    trigger: 'user_retry',
    removed_count: removedDeliveredIDs.length,
  });

  const assistantOverride = shouldReuseFailedAssistant
    ? {
        ...clearReusableAssistantState(messages[msgIndex]),
        text: preservePartialAssistant ? messages[msgIndex].text : '',
        reasoningText: preservePartialAssistant ? messages[msgIndex].reasoningText : undefined,
        reasoningDurationMs: preservePartialAssistant ? messages[msgIndex].reasoningDurationMs : undefined,
        citations: preservePartialAssistant ? messages[msgIndex].citations : undefined,
        errorTitle: undefined,
        errorDetail: undefined,
        errorKind: undefined,
        errorSource: undefined,
        attachments: preservePartialAssistant ? messages[msgIndex].attachments : undefined,
        estimatedCost: preservePartialAssistant ? messages[msgIndex].estimatedCost : 0,
        providerID: provider.id,
        providerKind: provider.kind,
        providerName: getProviderInstanceDisplayName(provider),
        modelID: model.id,
        modelName: model.name,
        state: 'generating' as const,
      }
    : undefined;
  return send(ctx, {
    text: userMsg.text, prevMessages: remaining, conversation,
    provider, model, reasoningMode, webSearchEnabled,
    attachments: userMsg.attachments,
    quoteContext: userMsg.quoteContext,
    userMessageOverride: retryingFailedAssistant ? userMsg : undefined,
    assistantMessageOverride: assistantOverride,
    ...(preservePartialAssistant ? { appendToAssistant: true } : {}),
    persistUserMessage: !retryingFailedAssistant,
    userMessageAlreadyInHistory: retryingFailedAssistant,
    onNewConversation, onFailed,
    ...(libraryContextDocuments.length > 0 ? { libraryContextDocuments } : {}),
    libraryContextCancelledText,
    ...(libraryFailurePresentation ? { libraryFailurePresentation } : {}),
    ...(excludeCustomFragments ? { excludeCustomFragments: true } : {}),
    ...(excludeCustomFragmentOwners.length ? { excludeCustomFragmentOwners } : {}),
    ...(capabilityRecipeOmissions.length ? { capabilityRecipeOmissions } : {}),
    ...(capabilityRecipeResendOwners.length ? { capabilityRecipeResendOwners } : {}),
    ...(excludeCapabilityOwners.length ? { excludeCapabilityOwners } : {}),
  });
}

function clearReusableAssistantState(message: ChatMessage): ChatMessage {
  const clean = { ...message };
  delete clean.inputTokens;
  delete clean.outputTokens;
  delete clean.cachedInputTokens;
  delete clean.cacheCreationInputTokens;
  delete clean.cacheCreation5mTokens;
  delete clean.cacheCreation1hTokens;
  delete clean.costSource;
  delete clean.capabilityRecovery;
  return clean;
}
