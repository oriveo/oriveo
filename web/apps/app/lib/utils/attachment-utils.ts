import * as Sentry from '@sentry/nextjs';
import type { Attachment, AttachmentKind } from '@oriveo/shared';
import { saveImage } from '../infra/storage/image-store';
import { compressImage, createImageThumbnail, readFileAsBase64, base64ToBlob } from './image-utils';
import { createCanonicalUUID } from './id-utils';
import { MAX_CHAT_ATTACHMENT_BYTES, isOversizedChatAttachment } from './attachment-size-policy';
import { DEFAULT_LIMITS, type ExtractedText, type FileExtractionLimits, FileTextExtractor } from '../core/attachments/file-text-extractor';
import { OFFICE_FILE_KINDS, classifyAttachmentFile } from '../core/attachments/attachment-file-types';
const ALLOWED_IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
const ALLOWED_VIDEO_TYPES = [
  'video/mp4',
  'video/mpeg',
  'video/quicktime',
  'video/x-msvideo',
  'video/x-flv',
  'video/webm',
  'video/x-ms-wmv',
  'video/3gpp',
];

export interface ValidationResult {
  valid: boolean;
  error?: string;
  /** Over the size limit: lets the caller show "file too large" rather than treat it as an unsupported type. */
  tooLarge?: boolean;
  /** Legacy formats (doc / xls / ppt / iWork): blocked at the entry; the caller shows a "save as new format" hint (spec section 2). */
  legacyFormat?: boolean;
}

export function validateFile(file: File): ValidationResult {
  if (isOversizedChatAttachment(file)) {
    return { valid: false, tooLarge: true, error: `File too large (max ${MAX_CHAT_ATTACHMENT_BYTES / 1024 / 1024}MB)` };
  }
  if (ALLOWED_IMAGE_TYPES.includes(file.type) || ALLOWED_VIDEO_TYPES.includes(file.type)) {
    return { valid: true };
  }
  // Other files are judged by the extractor's same type list (attachment extraction output spec section 2).
  const kind = classifyAttachmentFile(file.name, file.type);
  if (kind === 'legacy') {
    return { valid: false, legacyFormat: true, error: `Legacy file format: ${file.name}` };
  }
  if (kind === 'unsupported') {
    return { valid: false, error: `Unsupported file type: ${file.type || file.name}` };
  }
  return { valid: true };
}

/** Whether the file is a type that can be read as text */
export function isTextFile(file: File): boolean {
  return classifyAttachmentFile(file.name, file.type) === 'text';
}

/**
 * HTML is readable as text but must not be *sent* as text.
 *
 * A saved web page is mostly markup: scripts, inline styles and attributes swamp the prose, so
 * forwarding it verbatim spends the context window on tags and leaves the model guessing at the
 * article. It goes through the HTML extractor instead, the same as on the other clients.
 */
export function isHtmlFile(file: File): boolean {
  return classifyAttachmentFile(file.name, file.type) === 'html';
}

/** Whether the file is an Office format (OOXML / ODF / RTF, handled by the Office parser) */
export function isOfficeFile(file: File): boolean {
  return OFFICE_FILE_KINDS.has(classifyAttachmentFile(file.name, file.type));
}

function fileToKind(file: File): AttachmentKind {
  if (ALLOWED_VIDEO_TYPES.includes(file.type)) return 'video';
  return ALLOWED_IMAGE_TYPES.includes(file.type) ? 'image' : 'file';
}

/**
 * Plain text and Office go through the extractor (decoding and truncation follow the same rules as PDF / EPUB / HTML).
 *
 * If the whole file is a single line over the byte limit (minified JSON etc.), the extractor truncates within the line at a character boundary and keeps the beginning.
 * Exception: if the truncated result is still empty (it starts with a logical separator and backing off consumed everything), take the untruncated full text and do not flag truncation,
 * so the total-size gate at import rejects it as before and explains why, which beats adding an empty attachment.
 */
async function extractImportedText(
  file: File,
  limits: FileExtractionLimits,
  uiLanguage: string,
): Promise<ExtractedText> {
  const extracted = await FileTextExtractor.extract(file, limits, 'file', uiLanguage);
  if (extracted.truncated && extracted.content.length === 0 && file.size > 0) {
    const full = await FileTextExtractor.extract(
      file,
      { ...limits, maxLines: Number.POSITIVE_INFINITY, maxBytes: Number.POSITIVE_INFINITY },
      'file',
      uiLanguage,
    );
    if (full.content.length > 0) return { ...full, truncated: false, truncationReason: undefined };
  }
  return extracted;
}

/**
 * `limits`: truncation limits for extracted text; the import pipeline passes the current model's; defaults apply if omitted.
 * `uiLanguage`: the app's current UI language (next-intl locale), used for plain-text encoding detection; falls back to `en`.
 */
export async function fileToAttachment(
  file: File,
  limits: FileExtractionLimits = DEFAULT_LIMITS,
  uiLanguage: string = 'en',
): Promise<Attachment> {
  const rawBase64 = await readFileAsBase64(file);
  const kind = fileToKind(file);

  // Images are compressed to JPEG and stored in a separate ImageStore.
  if (kind === 'image') {
    const compressed = await compressImage(rawBase64, file.type);
    // A failed compression (the browser cannot decode the image, or no canvas context is
    // available) must not degrade the whole attachment: the original bytes are still a valid
    // image the user picked, so they go into the ImageStore and the send path as usual, just
    // uncompressed and without a thumbnail. mime and fileName then have to fall back to the
    // original file's -- labelling everything image/jpeg unconditionally would send PNG bytes
    // upstream as JPEG. When the thumbnail is null, thumbnailBase64 is not written at all, so
    // AttachmentPreview falls back to the file icon and sync never pushes the full-size base64
    // to the sync backend.
    const imageData = compressed?.data ?? rawBase64;
    const imageMime = compressed?.mime ?? file.type;
    const thumbnailBase64 = await createImageThumbnail(imageData, imageMime);

    // base64 -> Blob, stored in the ImageStore.
    const imageId = createCanonicalUUID();
    const imageBlob = await base64ToBlob(imageData, imageMime);
    const thumbBlob = thumbnailBase64 ? await base64ToBlob(thumbnailBase64, 'image/jpeg') : null;
    await saveImage(imageId, imageBlob, thumbBlob, imageMime);

    return {
      id: createCanonicalUUID(),
      kind,
      fileName: compressed ? 'image.jpg' : file.name,
      mimeType: imageMime,
      localImageID: imageId,
      ...(thumbnailBase64 ? { thumbnailBase64 } : {}),
      originalSizeBytes: file.size,
    };
  }

  if (kind === 'video') {
    return {
      id: createCanonicalUUID(),
      kind,
      fileName: file.name,
      mimeType: file.type,
      base64Data: rawBase64,
      originalSizeBytes: file.size,
    };
  }

  // Text files: decoded to plain text per spec section 4 and stored; sent as a text content part.
  // HTML is not handled here: type detection classifies it as html and it goes through the extractor below, rather than forwarding the raw markup.
  if (isTextFile(file)) {
    let extracted: ExtractedText;
    try {
      extracted = await extractImportedText(file, limits, uiLanguage);
    } catch (e: unknown) {
      const err = e as { name?: string; code?: string };
      // Non-extraction errors such as unreadable bytes are thrown to the batch's single-file failure boundary as before.
      if (err?.name !== 'ExtractionError' || !err.code) throw e;
      return {
        id: createCanonicalUUID(),
        kind,
        fileName: file.name,
        mimeType: file.type || 'text/plain',
        base64Data: '',
        originalSizeBytes: file.size,
        extractionErrorCode: err.code,
      };
    }
    return {
      id: createCanonicalUUID(),
      kind,
      fileName: file.name,
      mimeType: file.type || 'text/plain',
      base64Data: extracted.content,
      originalSizeBytes: file.size,
      extractedTotalLines: extracted.totalLines,
      extractedTruncated: extracted.truncated,
      extractedSizeBytes: extracted.sizeBytes,
    };
  }

  // Office formats (OOXML / ODF / RTF): go through the extractor
  if (isOfficeFile(file)) {
    try {
      const extracted = await extractImportedText(file, limits, uiLanguage);
      return {
        id: createCanonicalUUID(),
        kind,
        fileName: file.name,
        mimeType: file.type || 'application/octet-stream',
        base64Data: extracted.content,
        downloadBase64Data: rawBase64,
        // Office mime types keep originalBase64Data as well, so AttachmentRouter can choose the
        // native route (only OpenAI Responses accepts docx/xlsx/pptx as an input_file).
        originalBase64Data: rawBase64,
        originalSizeBytes: file.size,
        extractedTotalLines: extracted.totalLines,
        extractedTruncated: extracted.truncated,
        extractedSizeBytes: extracted.sizeBytes,
      };
    } catch (e: unknown) {
      const err = e as { name?: string; code?: string; message?: string };
      const msg = String(err?.message ?? '').toLowerCase();
      // A classified ExtractionError keeps its own code: an oversized archive must not be reported
      // to the model as a corrupted one.
      const errorCode = err?.name === 'ExtractionError' && err.code
        ? err.code
        : (msg.includes('encrypted') || msg.includes('password') || msg.includes('protected'))
          ? 'password_protected_office'
          : 'corrupted_file';
      return {
        id: createCanonicalUUID(),
        kind,
        fileName: file.name,
        mimeType: file.type || 'application/octet-stream',
        base64Data: '',
        downloadBase64Data: rawBase64,
        originalBase64Data: rawBase64,
        originalSizeBytes: file.size,
        extractionErrorCode: errorCode,
      };
    }
  }

  // PDF / EPUB / HTML: extracted locally via FileTextExtractor
  const fileKind = classifyAttachmentFile(file.name, file.type);
  const isPdf = fileKind === 'pdf';
  const isEpub = fileKind === 'epub';
  const isHtml = fileKind === 'html';

  if (isPdf || isEpub || isHtml) {
    try {
      const { FileTextExtractor, ExtractionError } = await import('../core/attachments/file-text-extractor');
      const extracted = await FileTextExtractor.extract(file, limits, 'file', uiLanguage);
      return {
        id: createCanonicalUUID(),
        kind,
        fileName: file.name,
        mimeType: file.type || 'text/plain',
        base64Data: extracted.content,
        downloadBase64Data: isPdf ? rawBase64 : undefined,  // PDF keeps the original binary
        originalBase64Data: isPdf ? rawBase64 : undefined,  // used by the fallback path
        originalSizeBytes: file.size,
        extractedTotalLines: extracted.totalLines,
        extractedTruncated: extracted.truncated,
        extractedSizeBytes: extracted.sizeBytes,
      };
    } catch (e: unknown) {
      const err = e as { name?: string; code?: string; message?: string };
      if (err?.name === 'ExtractionError') {
        const code = err.code as string;
        return {
          id: createCanonicalUUID(),
          kind,
          fileName: file.name,
          mimeType: file.type || 'application/octet-stream',
          base64Data: '',
          downloadBase64Data: isPdf ? rawBase64 : undefined,
          originalBase64Data: isPdf ? rawBase64 : undefined,
          originalSizeBytes: file.size,
          extractionErrorCode: code,
        };
      }
      // Any other unexpected error.
      return {
        id: createCanonicalUUID(),
        kind,
        fileName: file.name,
        mimeType: file.type || 'application/octet-stream',
        base64Data: '',
        originalSizeBytes: file.size,
        extractionErrorCode: 'extraction_error',
      };
    }
  }

  // Any other binary attachment: embedded as base64 as a last resort.
  return {
    id: createCanonicalUUID(),
    kind,
    fileName: file.name,
    mimeType: file.type,
    base64Data: rawBase64,
    originalSizeBytes: file.size,
  };
}

/**
 * Validate and convert a batch of files into Attachment values.
 * Shared by ChatView (drag and drop, paste) and InputComposer (file picker).
 *
 * `source` is used for telemetry drill-down and does not affect the conversion.
 * `providerKind` feeds the attachment-by-provider matrix; callers should pass the current
 * conversation's provider.kind normalized to snake_case through `telemetryProviderKind()`, and
 * `unknown` is reported when it is missing.
 */
export function validateAndConvertFiles(
  files: File[],
  source: 'file' | 'drag_drop' | 'paste' = 'file',
  providerKind?: string,
  onFileFailed?: (file: File) => void,
  onFileTooLarge?: (file: File) => void,
  limits: FileExtractionLimits = DEFAULT_LIMITS,
  options: ConvertFilesOptions = {},
): Promise<Attachment[]> {
  // Import queue: file picker, drag and drop, and paste are three entries, and the user can start another batch before the previous one is finished reading. Each file must
  // be read into memory whole (base64 string + the extractor reading the ArrayBuffer again). Within a batch files are already processed one by one; here
  // batches are queued as well, so the peak is always one file (same purpose as the Android import queue).
  const run = importQueue.then(() => convertFilesInOrder(files, source, providerKind, onFileFailed, onFileTooLarge, limits, options));
  importQueue = run.then(() => undefined, () => undefined);
  return run;
}

export interface ConvertFilesOptions {
  /** The app's current UI language (next-intl locale), used for plain-text encoding detection; falls back to `en`. */
  uiLanguage?: string;
  /** A legacy-format file was blocked at the entry: the caller shows a "save as new format" hint (spec section 2) and the file does not enter the input box. */
  onLegacyFormat?: (file: File) => void;
}

let importQueue: Promise<void> = Promise.resolve();

async function convertFilesInOrder(
  files: File[],
  source: 'file' | 'drag_drop' | 'paste',
  providerKind: string | undefined,
  onFileFailed: ((file: File) => void) | undefined,
  onFileTooLarge: ((file: File) => void) | undefined,
  limits: FileExtractionLimits,
  options: ConvertFilesOptions,
): Promise<Attachment[]> {
  const { trackEvent } = await import('../core/telemetry');
  const attachments: Attachment[] = [];
  for (const file of files) {
    const result = validateFile(file);
    if (!result.valid) {
      // A file over the limit is not read, but the caller is told so it can explain why the
      // attachment never reached the tray instead of the file vanishing without a word.
      if (result.tooLarge) onFileTooLarge?.(file);
      if (result.legacyFormat) options.onLegacyFormat?.(file);
      continue;
    }
    let attachment: Attachment;
    try {
      attachment = await fileToAttachment(file, limits, options.uiLanguage ?? 'en');
    } catch (err) {
      // Per-file fault boundary: any failure drops only this file and notifies the caller, while
      // files already converted in the batch and those still queued go through as usual.
      //
      // - A File is only a handle to a file on disk. Files dragged out of an archive or a
      //   cloud-drive placeholder on Windows, or moved after being picked, fail only when their
      //   bytes are read (NotFoundError / NotReadableError). That is an environment condition and
      //   is not reported.
      // - Everything else (an image that cannot be stored in IndexedDB, a huge file whose base64
      //   exceeds the string length limit, a decoder throwing) used to propagate. None of the
      //   three entry points catches it, so it became an unhandled rejection and the whole batch,
      //   including files already converted, vanished without any notice. These are still
      //   defects worth knowing about, so they are reported explicitly rather than by leaking.
      if (!isUnreadableFileError(err)) {
        Sentry.captureException(err, {
          level: 'warning',
          tags: { module: 'attachment.import', 'attachment.source': source },
          extra: { mimeType: file.type || 'unknown', sizeBytes: file.size },
        });
      }
      onFileFailed?.(file);
      continue;
    }
    attachments.push(attachment);
    trackEvent('attachment_added', {
      mime_type: file.type || 'unknown',
      size_bytes: file.size,
      kind: attachment.kind,
      source,
      provider_kind: providerKind ?? 'unknown',
    });
  }
  return attachments;
}

function isUnreadableFileError(err: unknown): boolean {
  const name = (err as { name?: unknown } | null)?.name;
  return name === 'NotFoundError' || name === 'NotReadableError';
}
