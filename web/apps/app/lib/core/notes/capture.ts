import type { ChatMessage, Conversation, Note, Provider } from '@oriveo/shared';
import type { StoreApi } from 'zustand';
import type { AppStore } from '../store/app-store';
import { createNote as defaultCreateNote, type CreateNoteInput } from '../note-ops';
import { getProviderInstanceDisplayName } from '../providers/provider-display';
import { createModelDisplayLookup } from '../providers/model-display-lookup';
import { stripMarkdownForClipboard } from '../../utils/markdown-preview';

interface MessageCaptureContext {
  conversation: Conversation;
  message: ChatMessage;
  provider?: Provider;
}

function previousUserPrompt(conversation: Conversation, messageId: string): string | undefined {
  const index = conversation.messages.findIndex((message) => message.id === messageId);
  if (index < 0) return undefined;
  for (let i = index; i >= 0; i -= 1) {
    const message = conversation.messages[i];
    if (message.role === 'user' && message.text.trim()) return message.text;
  }
  return undefined;
}

function resolveModelName(message: ChatMessage, provider?: Provider): string | undefined {
  if (provider) {
    const model = createModelDisplayLookup(provider).resolve(message.modelID);
    if (model?.displayName) return model.displayName;
  }
  return message.modelName || message.modelID;
}

function resolveProviderName(message: ChatMessage, provider?: Provider): string | undefined {
  if (provider) return getProviderInstanceDisplayName(provider);
  return message.providerName || message.providerKind;
}

function buildSourceFields({ conversation, message, provider }: MessageCaptureContext): Partial<CreateNoteInput> {
  return {
    sourceConversationId: conversation.id,
    sourceMessageId: message.id,
    sourceModelID: message.modelID,
    sourceModelName: resolveModelName(message, provider),
    sourceProviderKind: provider?.kind ?? message.providerKind,
    sourceProviderName: resolveProviderName(message, provider),
    sourcePrompt: message.role === 'user' ? message.text : previousUserPrompt(conversation, message.id),
  };
}

export function buildMessageNoteInput(context: MessageCaptureContext): CreateNoteInput {
  const captureKind: Note['captureKind'] = context.message.role === 'user' ? 'userMessage' : 'fullAnswer';
  return {
    body: context.message.text,
    bodySnapshot: context.message.text,
    captureKind,
    ...buildSourceFields(context),
  };
}

export function buildMessageNoteInputFromSnapshot({
  conversationId,
  message,
  provider,
  sourcePrompt,
}: {
  conversationId: string;
  message: ChatMessage;
  provider?: Provider;
  sourcePrompt?: string;
}): CreateNoteInput {
  const captureKind: Note['captureKind'] = message.role === 'user' ? 'userMessage' : 'fullAnswer';
  return {
    body: message.text,
    bodySnapshot: message.text,
    captureKind,
    sourceConversationId: conversationId,
    sourceMessageId: message.id,
    sourceModelID: message.modelID,
    sourceModelName: resolveModelName(message, provider),
    sourceProviderKind: provider?.kind ?? message.providerKind,
    sourceProviderName: resolveProviderName(message, provider),
    sourcePrompt: message.role === 'user' ? message.text : sourcePrompt,
  };
}

export function buildSelectionNoteInput(
  context: MessageCaptureContext & { selectedText: string },
): CreateNoteInput {
  return {
    body: context.selectedText,
    bodySnapshot: context.message.text,
    captureKind: 'selection',
    ...buildSourceFields(context),
  };
}

export function buildSelectionNoteInputFromSnapshot({
  conversationId,
  message,
  provider,
  selectedText,
  sourcePrompt,
}: {
  conversationId: string;
  message: ChatMessage;
  provider?: Provider;
  selectedText: string;
  sourcePrompt?: string;
}): CreateNoteInput {
  return {
    body: selectedText,
    bodySnapshot: message.text,
    captureKind: 'selection',
    sourceConversationId: conversationId,
    sourceMessageId: message.id,
    sourceModelID: message.modelID,
    sourceModelName: resolveModelName(message, provider),
    sourceProviderKind: provider?.kind ?? message.providerKind,
    sourceProviderName: resolveProviderName(message, provider),
    sourcePrompt: message.role === 'user' ? message.text : sourcePrompt,
  };
}

export function buildBlankNoteInput(noteFolderID?: string): CreateNoteInput {
  const folderID = noteFolderID === '__uncategorized__' ? undefined : noteFolderID;
  return { body: '', captureKind: 'blank', ...(folderID ? { noteFolderID: folderID } : {}) };
}

export function normalizeSelectedText(value: string): string {
  return stripMarkdownForClipboard(value).trim();
}

export function captureMessageAsNote({
  store,
  conversation,
  message,
  provider,
  createNote = defaultCreateNote,
}: MessageCaptureContext & {
  store: StoreApi<AppStore>;
  createNote?: (store: StoreApi<AppStore>, input: CreateNoteInput) => unknown;
}) {
  return createNote(store, buildMessageNoteInput({ conversation, message, provider }));
}
