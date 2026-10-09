/**
 * How a file attachment is handed to the model at send time: native upload, or injected as a text block.
 *
 * Building the outbound history (`buildChatHistory`) and the pre-send check use this same logic: the check
 * answers "will the injector skip it when it is really sent", and two copies would drift apart sooner or later.
 */
import type { AIModel, Attachment } from '@oriveo/shared';
import {
  type AttachmentLine,
  attachmentTransportProfile,
} from '@oriveo/core/providers/attachment-transport';
import {
  type AttachmentPayload,
  type SkippedAttachment,
  AttachmentInjector,
} from './attachment-injector';
import { decideAttachmentRoute } from './attachment-router';
import { type ExtractionErrorCode, resolveFileExtractionLimits } from './file-text-extractor';

export type FileAttachmentDelivery =
  | { route: 'native'; originalBase64Data: string }
  | { route: 'client_extract'; payload: AttachmentPayload };

export function resolveFileAttachmentDelivery(
  attachment: Attachment,
  model: AIModel | null | undefined,
  line: AttachmentLine | undefined,
): FileAttachmentDelivery {
  // AttachmentRouter is the single place that decides native vs client_extract; without a line, always inject text.
  const route = model && line ? decideAttachmentRoute(attachment, line, model) : 'client_extract';
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
  line: AttachmentLine | undefined,
): SkippedAttachment[] {
  if (!attachments || attachments.length === 0) return [];
  const payloads: AttachmentPayload[] = [];
  for (const attachment of attachments) {
    if (attachment.kind !== 'file') continue;
    const delivery = resolveFileAttachmentDelivery(attachment, model, line);
    if (delivery.route === 'client_extract') payloads.push(delivery.payload);
  }
  if (payloads.length === 0) return [];
  return AttachmentInjector.injectAll(
    '',
    payloads,
    resolveFileExtractionLimits(model),
    line ? attachmentTransportProfile(line.transport).wrapper : 'xml-v1',
  ).skipped;
}

/** Stable codes shared across clients: telemetry and error reports carry only these two, never file names. */
export const ATTACHMENT_TEXT_OVER_LIMIT = 'attachment_text_over_limit';
export const ATTACHMENT_COUNT_OVER_LIMIT = 'attachment_count_over_limit';
export type AttachmentOverLimitCode =
  | typeof ATTACHMENT_TEXT_OVER_LIMIT
  | typeof ATTACHMENT_COUNT_OVER_LIMIT;

/** Every skipped file is over the count cap -> count code; any file that does not fit the text budget -> text code. */
export function attachmentOverLimitCode(skipped: readonly SkippedAttachment[]): AttachmentOverLimitCode {
  return skipped.every((item) => item.reason === 'too_many_files')
    ? ATTACHMENT_COUNT_OVER_LIMIT
    : ATTACHMENT_TEXT_OVER_LIMIT;
}

export function isAttachmentOverLimitCode(value: unknown): value is AttachmentOverLimitCode {
  return value === ATTACHMENT_TEXT_OVER_LIMIT || value === ATTACHMENT_COUNT_OVER_LIMIT;
}

/**
 * The attachments of this turn do not fit: the request is not sent.
 *
 * `message` and `kind` carry only the stable code; the user-facing sentence (with file names) goes in `detail`,
 * localized and filled in by the caller.
 * `skipReport`: this is an input problem the user can fix, so it is not sent to error reporting.
 */
export class AttachmentOverLimitError extends Error {
  readonly kind: AttachmentOverLimitCode;
  readonly source = 'oriveo' as const;
  readonly skipReport = true;
  detail?: string;
  constructor(readonly skipped: SkippedAttachment[]) {
    const code = attachmentOverLimitCode(skipped);
    super(code);
    this.name = 'AttachmentOverLimitError';
    this.kind = code;
  }
}
