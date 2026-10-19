/**
 * Synchronous phase of sendMessage: every store write and the start telemetry happen here,
 * before the stream begins.
 *
 * Used only by operations-send.ts. Concentrating the new-conversation versus
 * existing-conversation branch and the start telemetry here lets the main transaction
 * function care only about getting finalConvId, sendStartedAt and the snapshot.
 */
import type { StoreApi } from 'zustand';
import type { ChatMessage, Conversation, AIModel, Provider, Attachment, ReasoningMode } from '@oriveo/shared';
import type { AppStore } from '../store/app-store';
import { createNewConversation } from './message-factory';
import { deriveConversationMetadata, computeConversationActivityAt } from '../conversation-metadata';
import { getSkillById } from '../skills/query';
import { trackEvent, telemetryProviderKind, telemetryModelID } from '../telemetry';
import { relaySendTelemetryProperties } from '../telemetry/relay-properties';
import type { ChatAttemptKind } from '../telemetry/chat-failure';
import { recalculateConversationCost } from './usage-tracking';
import { upsertMessages } from './message-merge';
import { sameNormalizedID } from '../../utils/id-utils';
import { clearDirectiveSuggestion, getPendingDirectiveSuggestion } from './conversation-instructions/directive-suggestion';
import { clearMemorySuggestion, getPendingMemorySuggestion } from './conversation-instructions/memory-suggestion';
import { deleteLocalMessageContinuation } from './continuation-lifecycle';

export interface SendStartParams {
  store: StoreApi<AppStore>;
  userMsg: ChatMessage;
  assistantMsg: ChatMessage;
  prevMessages: ChatMessage[];
  persistUserMessage?: boolean;
  conversation: Conversation | undefined;
  provider: Provider;
  model: AIModel;
  reasoningMode: ReasoningMode;
  webSearchEnabled: boolean | undefined;
  attachments: Attachment[] | undefined;
  skillId: string | undefined;
  pinnedNoteIds?: string[];
  onNewConversation?: (convId: string) => void;
}

export interface SendStartResult {
  /** Conversation id finally bound to this send; for a new conversation, the newly created conversation.id */
  finalConvId: string;
  /** Whether this is a new conversation, which affects the chat_started telemetry and the didSendMessage arguments */
  isFirstMessage: boolean;
  /** Conversation snapshot at start: newConv for a first message, otherwise the snapshot read back after the store update */
  initialConversationSnapshot: Conversation | undefined;
  /** Date.now(), used by the caller to report latency */
  sendStartedAt: number;
}

/**
 * Send lifecycle telemetry is intentionally emitted only after the stream exposes its final
 * capability fact. This avoids racing provider/model-rich telemetry ahead of proxy dispatch.
 *
 * The privacy boundary here is per field, not per event: the full property set is sent
 * whether or not the request carried a capability recipe or a custom fragment. What is
 * excluded is the execution facts themselves - requested/observed/rejected, recipe identity
 * and content, a fragment's owner/path/value, search terms, response evidence and raw error
 * bodies - and none of the fields below contain any of those.
 */
export function reportSendStartedTelemetry(input: {
  finalConvId: string;
  isFirstMessage: boolean;
  provider: Provider;
  model: AIModel;
  reasoningMode: ReasoningMode;
  webSearchEnabled: boolean | undefined;
  attachments: Attachment[] | undefined;
  skillId: string | undefined;
  /** Entry point that started this attempt (send / edit / retry / regenerate / continue); defaults to send. */
  attemptKind?: ChatAttemptKind;
}): void {
  const {
    finalConvId, isFirstMessage, provider, model, reasoningMode, webSearchEnabled,
    attachments, skillId, attemptKind = 'send',
  } = input;
  const reportedModelID = telemetryModelID(provider.kind, model.id);
  if (isFirstMessage) {
    trackEvent('chat_started', {
      conversation_id: finalConvId,
      provider_kind: telemetryProviderKind(provider.kind),
      model_id: reportedModelID,
      has_skill: Boolean(skillId),
    });
  }
  trackEvent('chat_message_sent', {
    provider_kind: telemetryProviderKind(provider.kind),
    model_id: reportedModelID,
    is_new_conversation: isFirstMessage,
    attachment_count: attachments?.length ?? 0,
    attachment_kinds: attachments?.map((a) => a.kind) ?? [],
    has_skill: Boolean(skillId),
    reasoning_mode: reasoningMode,
    // User intent at click time; it is deliberately distinct from
    // `web_search_used`, which is emitted only after the final facade gate.
    web_search_enabled: Boolean(webSearchEnabled),
    attempt_kind: attemptKind,
    ...relaySendTelemetryProperties(provider, model),
  });
}

export function prepareSendStart(p: SendStartParams): SendStartResult {
  const {
    store,
    userMsg,
    assistantMsg,
    prevMessages,
    persistUserMessage = true,
    conversation,
    provider,
    model,
    reasoningMode,
    webSearchEnabled,
    attachments,
    skillId,
    pinnedNoteIds,
    onNewConversation,
  } = p;

  let convId: string;
  let isFirstMessage = false;
  let initialConversationSnapshot: Conversation | undefined;

  // A new conversation, or an append to an existing one
  if (!conversation) {
    isFirstMessage = true;
    const pendingSkill = skillId ? getSkillById(store, skillId) : undefined;
    const newConv = createNewConversation({
      provider, model, userMessage: userMsg,
      messages: [userMsg, assistantMsg],
      skillId,
      useMemory: pendingSkill?.useMemory,
      pinnedNoteIds,
      instructions: store.getState().draftConversationInstructions,
    });
    convId = newConv.id;
    store.getState().addConversation(newConv);
    store.getState().setActiveConversationId(convId);
    store.getState().setLastUsedModelRef({ providerID: provider.id, modelID: model.id });
    onNewConversation?.(convId);
    initialConversationSnapshot = newConv;
  } else {
    convId = conversation.id;
    // Upsert incrementally against the store's current messages rather than the
    // prevMessages snapshot, so that with concurrent sends a later stale snapshot cannot
    // overwrite an already finished message and scramble the order (see message-merge.ts).
    const currentMessages = store.getState().conversations.find((c) => c.id === convId)?.messages ?? prevMessages;
    const nextMessages = upsertMessages(
      currentMessages,
      persistUserMessage ? [userMsg, assistantMsg] : [assistantMsg],
    );
    // providerKind / relayKind are written back with the provider, so the list icon does
    // not depend on providers.find() after switching provider; switching away from Relay
    // writes an explicit undefined over the old value.
    store.getState().updateConversation(convId, {
      isDraft: false,
      messages: nextMessages,
      ...deriveConversationMetadata(conversation, nextMessages),
      estimatedCost: recalculateConversationCost(nextMessages),
      modelID: model.id, providerID: provider.id,
      providerKind: provider.kind,
      relayKind: provider.kind === 'relay' ? provider.relayKind : undefined,
      updatedAt: computeConversationActivityAt(nextMessages, conversation.createdAt),
    });
    initialConversationSnapshot = store.getState().conversations.find((c) => c.id === convId);
  }

  const finalConvId = convId;
  store.getState().beginStreamingForConversation(finalConvId, assistantMsg.id);
  // Half a failed round never reaches the cloud: the user message is no longer uploaded on
  // its own at send time, and the whole round is synced once the assistant message is
  // delivered successfully (the operations-send success path, didCompleteRound). Failed or
  // interrupted half-rounds are never uploaded, so other clients only see a clean history.

  const sendStartedAt = Date.now();
  return { finalConvId, isFirstMessage, initialConversationSnapshot, sendStartedAt };
}

/**
 * Cancelling at the pre-send confirmation: locally delete the messages this send put into the conversation (user + assistant placeholder)
 * and their local continuation sidecars (same rules for the main send, Library and MCP paths).
 * No remote delete or tombstone is sent, since a half turn never goes to the cloud; if the conversation has no messages left after the rollback (the first message), it returns to a draft: not synced and absent from the list.
 * The "set as instruction" and "save as memory?" suggestion bars raised by this send point at the deleted messages and are withdrawn together (not counted as ignored); suggestion bars of other messages are untouched.
 * A memory candidate still being generated in the background needs no separate withdrawal: before it lands it requires the message to still be the conversation's latest user message, so it is void once that message is deleted.
 */
export function rollbackSendStart(
  store: StoreApi<AppStore>,
  conversationId: string,
  messageIds: readonly string[],
): void {
  const conversation = store.getState().conversations.find((c) => c.id === conversationId);
  if (!conversation) return;
  const removed = new Set(messageIds);
  const suggestion = getPendingDirectiveSuggestion();
  if (suggestion && sameNormalizedID(suggestion.conversationId, conversationId) && removed.has(suggestion.messageId)) {
    clearDirectiveSuggestion();
  }
  const memorySuggestion = getPendingMemorySuggestion();
  if (memorySuggestion && sameNormalizedID(memorySuggestion.conversationId, conversationId) && removed.has(memorySuggestion.messageId)) {
    clearMemorySuggestion();
  }
  for (const messageId of messageIds) {
    void Promise.resolve(deleteLocalMessageContinuation(conversationId, messageId)).catch(() => undefined);
  }
  const messages = conversation.messages.filter((message) => !removed.has(message.id));
  store.getState().updateConversation(conversationId, {
    ...(messages.length === 0 ? { isDraft: true } : {}),
    messages,
    ...deriveConversationMetadata(conversation, messages),
    estimatedCost: recalculateConversationCost(messages),
    updatedAt: computeConversationActivityAt(messages, conversation.createdAt),
  });
}
