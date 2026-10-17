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
import { hasUsableExtractedText } from '../attachments/file-text-extractor';
import { type OutboundHistoryMessage, attachTextFallback } from '../attachments/native-file-fallback';
import type { SkippedAttachment } from '../attachments/attachment-injector';
import { outboundHistoryHasVideo, relayNativeFileCacheKey, resolveAttachmentLineForMessages } from '../attachments/attachment-transport-resolver';
import { buildChatHistory, sanitizeOutboundMessages } from '../../utils/chat-stream-utils';
import { filterCurrentTurnAttachments, withoutUnreceivableImages } from './attachment-policy';

/**
 * The messages actually to be sent in this request (normalized + attachments filtered by the current model capabilities). Sending, pre-send preflight and the model panel
 * file card all use this one copy to judge video.
 */
export function buildOutboundMessages(input: {
  messages: ChatMessage[];
  currentTurnId: string;
  keepAssistantId?: string;
  provider: Provider;
  model: AIModel;
  streamOptions?: StreamOptions;
}): ChatMessage[] {
  return filterCurrentTurnAttachments(
    withoutUnreceivableImages(
      sanitizeOutboundMessages(input.messages, input.keepAssistantId),
      input.provider, input.model, input.streamOptions,
    ),
    input.currentTurnId, input.provider, input.model,
  );
}

const MODEL_PANEL_TURN_ID = '__model_panel_turn__';

/**
 * Model panel file card prediction: whether the outbound history has video. The panel has no input for this turn right now, so attach a non-empty placeholder
 * user message as this turn (same convention as the other clients; the placeholder is not sent), so normalization and the attachment budget treat the history as a real send would.
 * Video only affects Gemini route selection; other connections do not count.
 */
export async function modelPanelOutboundHasVideo(input: {
  messages: ChatMessage[];
  provider: Provider;
  model: AIModel;
  streamOptions?: StreamOptions;
}): Promise<boolean> {
  if (input.provider.kind !== 'gemini') return false;
  const turn = { id: MODEL_PANEL_TURN_ID, role: 'user', text: '_' } as ChatMessage;
  return outboundHistoryHasVideo(buildOutboundMessages({ ...input, messages: [...input.messages, turn], currentTurnId: turn.id }));
}

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
    && hasUsableExtractedText(attachment.base64Data, attachment.extractionErrorCode)
    && resolveFileAttachmentDelivery(attachment, input.model, line).route === 'native'));
  if (!hasExtractedText) return;
  let fallback: OutboundHistoryMessage[];
  try {
    fallback = await buildChatHistory(input.messages, input.model, { ...line, nativeFilesSuppressed: true });
  } catch {
    return;
  }
  const relayKey = relayNativeFileCacheKey(input.provider, input.model);
  attachTextFallback(history, fallback, {
    providerId: input.provider.id,
    providerKind: input.provider.kind,
    transport: line.transport,
    ...(relayKey ? { relayKey } : {}),
  });
}
