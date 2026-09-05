import type { Conversation, Provider, ProviderKind } from '@oriveo/shared';
import { exportAsMarkdown, downloadAsFile, sanitizeFilename } from './export-utils';
import { createModelDisplayLookup } from '../core/providers/model-display-lookup';

export function exportConversationMarkdown(conversation: Conversation, fallbackTitle: string) {
  const md = exportAsMarkdown(conversation);
  const filename = sanitizeFilename(conversation.title || fallbackTitle);
  downloadAsFile(md, `${filename}.md`, 'text/markdown');
}

export function resolveConversationItemModelName(
  conversation: Conversation,
  provider: Provider | undefined,
): string | null {
  let requestedModelId: string | null = conversation.modelID || null;
  let fallbackName: string | null = conversation.modelID || null;

  for (let index = conversation.messages.length - 1; index >= 0; index -= 1) {
    const message = conversation.messages[index];
    if (message.role !== 'assistant') continue;
    requestedModelId = message.modelID || requestedModelId;
    fallbackName = message.modelName || fallbackName;
    break;
  }

  if (!requestedModelId) return fallbackName;

  return createModelDisplayLookup(provider).resolve(requestedModelId)?.displayName
    ?? fallbackName;
}

export function resolveConversationItemProviderKind(
  conversation: Conversation,
): ProviderKind {
  // Conversation.providerKind is required by the type and guaranteed by the strict write path, so there is no fallback.
  return conversation.providerKind;
}
