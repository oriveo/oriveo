/**
 * How a file attachment is handed to the model at send time: native upload, or injected as a text block.
 *
 * Building the outbound history (`buildChatHistory`) and the pre-send check use this same logic: the check
 * answers "will the injector skip it when it is really sent", and two copies would drift apart sooner or later.
 */
import type { AIModel, Attachment } from '@oriveo/shared';
import {
  type AttachmentPayload,
  type SkippedAttachment,
  AttachmentInjector,
  resolveWrapperVersion,
} from './attachment-injector';
import { decideAttachmentRoute } from './attachment-router';
import { type ExtractionErrorCode, resolveFileExtractionLimits } from './file-text-extractor';

export type FileAttachmentDelivery =
  | { route: 'native'; originalBase64Data: string }
  | { route: 'client_extract'; payload: AttachmentPayload };

export function resolveFileAttachmentDelivery(
  attachment: Attachment,
  model: AIModel | null | undefined,
  providerKind: string | undefined,
): FileAttachmentDelivery {
  // AttachmentRouter is the single place that decides native vs client_extract
  const route = model ? decideAttachmentRoute(attachment, providerKind ?? '', model) : 'client_extract';
  if (route === 'native' && attachment.originalBase64Data) {
    return { route: 'native', originalBase64Data: attachment.originalBase64Data };
  }
  const extracted = attachment.base64Data
    ? {
        content: attachment.base64Data,
        totalLines: attachment.extractedTotalLines ?? attachment.base64Data.split('\n').length,
        truncated: attachment.extractedTruncated ?? false,
        // The truncation reason is not persisted and is unavailable when rebuilding; the injector has generic wording for a missing reason.
        truncationReason: undefined,
        sizeBytes: attachment.extractedSizeBytes ?? attachment.base64Data.length,
      }
    : null;
  return {
    route: 'client_extract',
    payload: {
      fileName: attachment.fileName,
      mimeType: attachment.mimeType,
      sizeBytes: attachment.extractedSizeBytes ?? attachment.base64Data?.length ?? 0,
      extracted,
      errorCode: attachment.extractionErrorCode as ExtractionErrorCode | undefined,
    },
  };
}

/**
 * Pre-send check: which of this user message's attachments the injector would skip at send time (they do not fit
 * the current model's text budget). Attachments sent by native upload are not injected as text and are not counted.
 */
export function findUnsendableTextAttachments(
  attachments: Attachment[] | undefined,
  model: AIModel | null | undefined,
  providerKind: string | undefined,
): SkippedAttachment[] {
  if (!attachments || attachments.length === 0) return [];
  const payloads: AttachmentPayload[] = [];
  for (const attachment of attachments) {
    if (attachment.kind !== 'file') continue;
    const delivery = resolveFileAttachmentDelivery(attachment, model, providerKind);
    if (delivery.route === 'client_extract') payloads.push(delivery.payload);
  }
  if (payloads.length === 0) return [];
  return AttachmentInjector.injectAll(
    '',
    payloads,
    resolveFileExtractionLimits(model),
    providerKind ? resolveWrapperVersion(providerKind) : 'xml-v1',
  ).skipped;
}
