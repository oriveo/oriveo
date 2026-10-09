/**
 * Outbound history for a send: resolves the attachment line of this send, then builds the history.
 *
 * All four send entry points (plain send, continue generating, the MCP tool loop, the library agent) go
 * through here, so line resolution and the handling of "this turn's attachments do not fit" live in one place.
 */
import type { AIModel, ChatMessage, Provider } from '@oriveo/shared';
import type { ContentPart, StreamOptions } from '../providers/types';
import { type AttachmentLine, nativeFileModeOf } from '@oriveo/core/providers/attachment-transport';
import { AttachmentOverLimitError, resolveFileAttachmentDelivery } from '../attachments/attachment-delivery';
import { type OutboundHistoryMessage, attachTextFallback } from '../attachments/native-file-fallback';
import type { SkippedAttachment } from '../attachments/attachment-injector';
import { resolveAttachmentLineForMessages } from '../attachments/attachment-transport-resolver';
import { buildChatHistory } from '../../utils/chat-stream-utils';

export interface OutboundHistoryCtx {
  /** Words the attachments that do not fit as one sentence for the user (provided by the UI layer, localized). */
  describeAttachmentOverLimit?: (skipped: SkippedAttachment[], model: AIModel) => string;
}

export async function buildOutboundChatHistory(
  ctx: OutboundHistoryCtx,
  input: {
    messages: ChatMessage[];
    provider: Provider;
    model: AIModel;
    /** Stream options derived from this turn's intent (the same ones used to decide image capability). */
    streamOptions?: StreamOptions;
    /** This request carries client tools (MCP / library agent leg). */
    toolLoop?: boolean;
  },
): Promise<{ role: 'user' | 'assistant' | 'system'; content: string | ContentPart[] }[]> {
  const line = await resolveAttachmentLineForMessages(input.messages, {
    provider: input.provider,
    model: input.model,
    streamOptions: input.streamOptions,
    toolLoop: input.toolLoop,
  });
  try {
    const history = await buildChatHistory(input.messages, input.model, line);
    if (line) await attachNativeFileTextFallback(history, line, input);
    return history;
  } catch (error) {
    if (error instanceof AttachmentOverLimitError && ctx.describeAttachmentOverLimit) {
      error.detail = ctx.describeAttachmentOverLimit(error.skipped, input.model);
    }
    throw error;
  }
}

/**
 * When the line level is `alwaysWithTextFallback` (relay / subscription) and the request carries native
 * file blocks, this builds a second history with the same `buildChatHistory` while treating the line as
 * `off`, and attaches it to the history as a spare: if the upstream rejects the file blocks, the send chain
 * resends with it once.
 *
 * No fallback is prepared when none of the files routed to native has extracted text (all scanned, so
 * turning them into text would read nothing), or when the fallback version itself fails the delivery
 * decision (the text total or the file count does not fit).
 */
async function attachNativeFileTextFallback(
  history: OutboundHistoryMessage[],
  line: AttachmentLine,
  input: { messages: ChatMessage[]; provider: Provider; model: AIModel },
): Promise<void> {
  if (nativeFileModeOf(line) !== 'alwaysWithTextFallback') return;
  if (!history.some((message) => typeof message.content !== 'string'
    && message.content.some((part) => part.type === 'file'))) return;
  const hasExtractedText = input.messages.some((message) => message.attachments?.some((attachment) =>
    attachment.kind === 'file'
    && !attachment.extractionErrorCode
    && Boolean(attachment.base64Data?.trim())
    && resolveFileAttachmentDelivery(attachment, input.model, line).route === 'native'));
  if (!hasExtractedText) return;
  let fallback: OutboundHistoryMessage[];
  try {
    fallback = await buildChatHistory(input.messages, input.model, { ...line, nativeFilesSuppressed: true });
  } catch {
    return;
  }
  attachTextFallback(history, fallback, {
    providerId: input.provider.id,
    providerKind: input.provider.kind,
    transport: line.transport,
  });
}
