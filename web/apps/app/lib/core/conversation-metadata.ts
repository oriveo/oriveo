import type { ChatMessage, Conversation } from '@oriveo/shared';
import { stripMarkdownForPreview } from '../utils/markdown-preview';

const AUTO_CONVERSATION_TITLE_MAX = 50;
const CONVERSATION_PREVIEW_MAX = 200;

function normalizeAutoTitleText(text: string): string {
  return text.trim().replace(/\s+/g, ' ');
}

export function makePreviewText(msg: ChatMessage): string {
  let preview = stripMarkdownForPreview(msg.text);

  if (msg.attachments) {
    for (const att of msg.attachments) {
      const label = att.kind === 'image' ? '📷 Photo' : `📎 ${att.fileName}`;
      preview = preview ? `${label} ${preview}` : label;
    }
  }

  if (preview.length > CONVERSATION_PREVIEW_MAX) {
    preview = preview.slice(0, CONVERSATION_PREVIEW_MAX);
  }

  return preview;
}

export function makeAutoConversationTitle(msg: ChatMessage): string {
  let text = normalizeAutoTitleText(stripMarkdownForPreview(msg.text));

  // Emoji prefix for attachments
  if (msg.attachments?.length) {
    const hasImage = msg.attachments.some((a) => a.kind === 'image');
    const hasFile = msg.attachments.some((a) => a.kind === 'file');
    if (!text) {
      text = hasImage ? '📷 Photo' : `📎 ${msg.attachments[0].fileName || 'File'}`;
    } else {
      let prefix = '';
      if (hasImage) prefix += '📷 ';
      if (hasFile) prefix += '📎 ';
      text = prefix + text;
    }
  }

  return text.slice(0, AUTO_CONVERSATION_TITLE_MAX);
}

export function findLastDeliveredMessage(messages: ChatMessage[]): ChatMessage | undefined {
  return [...messages].reverse().find((m) => m.state === 'delivered');
}

export function findLastDeliveredUserMessage(messages: ChatMessage[]): ChatMessage | undefined {
  return [...messages].reverse().find((m) => m.role === 'user' && m.state === 'delivered');
}

/**
 * Compute the conversation sort time, which is the authoritative value of conv.updatedAt.
 *
 * Takes the createdAt of the last delivered message, falling back to conv.createdAt when
 * there is none. The same semantics everywhere keeps ordering consistent after cloud sync,
 * without depending on any one device's clock.
 */
export function computeConversationActivityAt(
  messages: ChatMessage[],
  conversationCreatedAt: string,
): string {
  const lastDelivered = findLastDeliveredMessage(messages);
  return lastDelivered?.createdAt ?? conversationCreatedAt;
}

export function deriveConversationMetadata(
  conversation: Pick<Conversation, 'title' | 'previewText' | 'hasCustomTitle'>,
  messages: ChatMessage[],
): Pick<Conversation, 'title' | 'previewText'> {
  const lastDelivered = findLastDeliveredMessage(messages);
  const lastDeliveredUser = findLastDeliveredUserMessage(messages);

  const title = (!conversation.hasCustomTitle && lastDeliveredUser)
    ? (makeAutoConversationTitle(lastDeliveredUser) || conversation.title)
    : conversation.title;

  const previewText = lastDelivered
    ? makePreviewText(lastDelivered)
    : conversation.previewText;

  return { title, previewText };
}
