import type { Attachment, AttachmentKind } from '@oriveo/shared';
import { saveImage } from '../infra/storage/image-store';
import { compressImage, createImageThumbnail, readFileAsBase64, base64ToBlob } from './image-utils';
import { parseOfficeFile } from './office-parser';
import { createCanonicalUUID } from './id-utils';
import { MAX_CHAT_ATTACHMENT_BYTES, isOversizedChatAttachment } from './attachment-size-policy';
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

// MIME types that can be read as plain text
const TEXT_MIME_TYPES = [
  'text/plain',
  'text/csv',
  'text/markdown',
  'text/html',
  'text/css',
  'text/xml',
  'text/javascript',
  'application/json',
  'application/xml',
  'application/javascript',
  'application/x-yaml',
  'application/x-sh',
];

// File extensions readable as text, used when the browser MIME type is unreliable
const TEXT_EXTENSIONS = [
  '.txt', '.csv', '.md', '.json', '.xml', '.html', '.css',
  '.js', '.ts', '.jsx', '.tsx', '.py', '.rb', '.go', '.rs',
  '.java', '.kt', '.swift', '.c', '.cpp', '.h', '.hpp',
  '.sh', '.bash', '.zsh', '.yaml', '.yml', '.toml', '.ini',
  '.env', '.log', '.sql', '.graphql', '.proto',
];

// Office binary formats officeParser can parse
const OFFICE_MIME_TYPES = [
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',       // .docx
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',             // .xlsx
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',     // .pptx
  'application/vnd.oasis.opendocument.text',                                       // .odt
  'application/vnd.oasis.opendocument.spreadsheet',                                // .ods
  'application/vnd.oasis.opendocument.presentation',                               // .odp
  'application/rtf',                                                               // .rtf
  'text/rtf',                                                                      // .rtf (alternative)
];

const OFFICE_EXTENSIONS = [
  '.docx', '.xlsx', '.pptx', '.odt', '.ods', '.odp', '.rtf',
];

const EPUB_MIME_TYPE = 'application/epub+zip';

const ALLOWED_FILE_TYPES = [
  ...ALLOWED_IMAGE_TYPES,
  ...ALLOWED_VIDEO_TYPES,
  'application/pdf',
  EPUB_MIME_TYPE,
  ...TEXT_MIME_TYPES,
  ...OFFICE_MIME_TYPES,
];

export interface ValidationResult {
  valid: boolean;
  error?: string;
}

export function validateFile(file: File): ValidationResult {
  if (isOversizedChatAttachment(file)) {
    return { valid: false, error: `File too large (max ${MAX_CHAT_ATTACHMENT_BYTES / 1024 / 1024}MB)` };
  }
  if (
    !ALLOWED_FILE_TYPES.includes(file.type) &&
    !isTextFileByExtension(file.name) &&
    !isOfficeFileByExtension(file.name) &&
    !isEpubByExtension(file.name)
  ) {
    return { valid: false, error: `Unsupported file type: ${file.type || file.name}` };
  }
  return { valid: true };
}

function isEpubByExtension(name: string): boolean {
  return name.toLowerCase().endsWith('.epub');
}

/** Whether the file can be read as text. */
export function isTextFile(file: File): boolean {
  return TEXT_MIME_TYPES.includes(file.type) || isTextFileByExtension(file.name);
}

/** Whether the file is an Office binary format that needs officeParser. */
export function isOfficeFile(file: File): boolean {
  return OFFICE_MIME_TYPES.includes(file.type) || isOfficeFileByExtension(file.name);
}

function isTextFileByExtension(name: string): boolean {
  const lower = name.toLowerCase();
  return TEXT_EXTENSIONS.some((ext) => lower.endsWith(ext));
}

function isOfficeFileByExtension(name: string): boolean {
  const lower = name.toLowerCase();
  return OFFICE_EXTENSIONS.some((ext) => lower.endsWith(ext));
}

function fileToKind(file: File): AttachmentKind {
  if (ALLOWED_VIDEO_TYPES.includes(file.type)) return 'video';
  return ALLOWED_IMAGE_TYPES.includes(file.type) ? 'image' : 'file';
}

export async function fileToAttachment(file: File): Promise<Attachment> {
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

  // Text files: decoded to UTF-8 plain text and sent as a text content part.
  if (isTextFile(file)) {
    const textContent = await file.text();
    return {
      id: createCanonicalUUID(),
      kind,
      fileName: file.name,
      mimeType: file.type || 'text/plain',
      base64Data: textContent,
      originalSizeBytes: file.size,
    };
  }

  // Office binary formats: plain text is extracted with officeParser.
  if (isOfficeFile(file)) {
    try {
      const textContent = await parseOfficeFile(file);
      return {
        id: createCanonicalUUID(),
        kind,
        fileName: file.name,
        mimeType: file.type || 'application/octet-stream',
        base64Data: textContent,
        downloadBase64Data: rawBase64,
        // Office mime types keep originalBase64Data as well, so AttachmentRouter can choose the
        // native route (only OpenAI Responses accepts docx/xlsx/pptx as an input_file).
        originalBase64Data: rawBase64,
        originalSizeBytes: file.size,
        extractedTotalLines: textContent.split('\n').length,
        extractedTruncated: false,
        extractedSizeBytes: file.size,
      };
    } catch (e: unknown) {
      const err = e as { message?: string };
      const msg = String(err?.message ?? '').toLowerCase();
      const errorCode = (msg.includes('encrypted') || msg.includes('password') || msg.includes('protected'))
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

  // PDF / EPUB / HTML: extracted locally through FileTextExtractor.
  const isPdf = file.type === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf');
  const isEpub = file.type === 'application/epub+zip' || file.name.toLowerCase().endsWith('.epub');
  const isHtml = file.type === 'text/html' || ['html', 'htm', 'xhtml'].some((ext) => file.name.toLowerCase().endsWith(`.${ext}`));

  if (isPdf || isEpub || isHtml) {
    try {
      const { FileTextExtractor, ExtractionError } = await import('../core/attachments/file-text-extractor');
      const extracted = await FileTextExtractor.extract(file);
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
export async function validateAndConvertFiles(
  files: File[],
  source: 'file' | 'drag_drop' | 'paste' = 'file',
  providerKind?: string,
): Promise<Attachment[]> {
  const { trackEvent } = await import('../core/telemetry');
  const attachments: Attachment[] = [];
  for (const file of files) {
    const result = validateFile(file);
    if (!result.valid) continue;
    const attachment = await fileToAttachment(file);
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
