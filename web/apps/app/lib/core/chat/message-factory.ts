/**
 * Message and conversation construction factories.
 * Pure functions with no React dependency.
 */

import type { ChatMessage, Conversation, AIModel, Provider, Attachment, QuoteContext } from '@oriveo/shared';
import { isValidQuoteContext } from '@oriveo/shared';
import { createCanonicalUUID, normalizePinnedNoteIDs } from '../../utils/id-utils';
import { makeAutoConversationTitle, makePreviewText } from '../conversation-metadata';
import { getProviderInstanceDisplayName } from '../providers/provider-display';

export function createUserMessage(params: {
  text: string;
  provider: Provider;
  model: AIModel;
  attachments?: Attachment[];
  quoteContext?: QuoteContext;
}): ChatMessage {
  const { text, provider, model, attachments, quoteContext } = params;
  return {
    id: createCanonicalUUID(),
    role: 'user',
    text,
    providerID: provider.id,
    providerKind: provider.kind,
    providerName: getProviderInstanceDisplayName(provider),
    modelID: model.id,
    modelName: model.name,
    estimatedCost: 0,
    state: 'delivered',
    attachments: attachments && attachments.length > 0 ? attachments : undefined,
    ...(quoteContext && isValidQuoteContext(quoteContext) ? { quoteContext } : {}),
    createdAt: new Date().toISOString(),
  };
}

export function createAssistantMessage(params: {
  provider: Provider;
  model: AIModel;
  /** createdAt (ISO) of the user message in the same send round. When provided, the assistant uses base + 1ms. */
  baseCreatedAt?: string;
}): ChatMessage {
  const { provider, model, baseCreatedAt } = params;
  // Separate the user and assistant createdAt by an explicit 1ms so that a millisecond collision
  // does not make cross-client ordering fall back to UUID lexicographic order, which is unstable
  const createdAt = baseCreatedAt
    ? new Date(new Date(baseCreatedAt).getTime() + 1).toISOString()
    : new Date().toISOString();
  return {
    id: createCanonicalUUID(),
    role: 'assistant',
    text: '',
    providerID: provider.id,
    providerKind: provider.kind,
    providerName: getProviderInstanceDisplayName(provider),
    modelID: model.id,
    modelName: model.name,
    estimatedCost: 0,
    state: 'generating',
    createdAt,
  };
}

export function createNewConversation(params: {
  provider: Provider;
  model: AIModel;
  userMessage: ChatMessage;
  messages: ChatMessage[];
  skillId?: string;
  useMemory?: boolean;
  pinnedNoteIds?: string[];
}): Conversation {
  const { provider, model, userMessage, messages, skillId, useMemory, pinnedNoteIds } = params;
  const normalizedPinnedNoteIds = normalizePinnedNoteIDs(pinnedNoteIds);
  // Activity sort time = createdAt of the first user message. updatedAt is the createdAt of the
  // last delivered message; a new conversation only holds the user message just sent.
  const activityAt = userMessage.createdAt ?? new Date().toISOString();
  return {
    id: createCanonicalUUID(),
    title: makeAutoConversationTitle(userMessage),
    hasCustomTitle: false,
    providerID: provider.id,
    providerKind: provider.kind,
    ...(provider.kind === 'relay' && provider.relayKind ? { relayKind: provider.relayKind } : {}),
    modelID: model.id,
    previewText: makePreviewText(userMessage),
    estimatedCost: 0,
    isDraft: false,
    messages,
    draftText: '',
    updatedAt: activityAt,
    createdAt: activityAt,
    ...(skillId ? { skillId } : {}),
    ...(useMemory !== undefined ? { useMemory } : {}),
    ...(normalizedPinnedNoteIds.length > 0 ? { pinnedNoteIds: normalizedPinnedNoteIds } : {}),
  };
}
