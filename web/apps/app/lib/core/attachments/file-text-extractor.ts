/**
 * File text extraction, single entry point
 *
 * Supported formats: PDF / EPUB / HTML / Office (DOCX/XLSX/PPTX/ODF/RTF) / plain text / source code
 * Truncation rules: 500 lines / 200KB, adjusted by the current model.attachmentExtraction override
 * SSR guard: browser only
 */

import {
  OFFICE_FILE_KINDS,
  OOXML_FILE_KINDS,
  SUPPORTED_ATTACHMENT_TYPES,
  classifyAttachmentFile,
} from './attachment-file-types';
import { ExtractionDeadline } from './extraction-deadline';

// MARK: - AIModel local interface (avoids a circular dependency)
interface AttachmentExtractionOverride {
  maxLines?: number;
  maxBytes?: number;
  totalCap?: number;
  maxInputFileBytes?: number;
  maxAttachments?: number;
}

interface ModelWithExtraction {
  attachmentExtraction?: AttachmentExtractionOverride;
  capabilities?: string[];
}

// MARK: - Models

export interface ExtractedText {
  content: string;
  totalLines: number;
  truncated: boolean;
  truncationReason?: 'lines' | 'bytes';
  sizeBytes: number;
  /** Spec section 12: a fully scanned file produced text via OCR. Web does no OCR, so extraction here never sets this; attachments synced from other platforms may. */
  scanned?: boolean;
}

export type ExtractionErrorCode =
  | 'encrypted_pdf'
  | 'scanned_pdf'
  | 'password_protected_office'
  | 'corrupted_file'
  | 'unsupported_format'
  | 'file_too_large'
  | 'extraction_timeout'
  | 'extraction_error';

export class ExtractionError extends Error {
  constructor(
    public readonly code: ExtractionErrorCode,
    underlying?: string,
  ) {
    super(`[${code}]${underlying ? ` ${underlying}` : ''}`);
    this.name = 'ExtractionError';
  }
}

/**
 * Attachment "has usable text": the text is non-empty and there is no error code or the code is `scanned_pdf` (spec section 13: a fully scanned file recognized successfully
 * still records `scanned_pdf` on the attachment so routes with native capability keep sending the original; injection, budget and fallback all treat it as a successful extraction).
 * Delivery, import, outbound fallback and the Relay first-send check share this one judgment.
 */
export function hasUsableExtractedText(text: string | null | undefined, errorCode: string | null | undefined): boolean {
  return Boolean(text?.trim()) && (!errorCode || errorCode === 'scanned_pdf');
}

// MARK: - Limits (Spec section 2.2, as revised)

export interface FileExtractionLimits {
  maxLines: number;
  maxBytes: number;
  totalCap: number;          // 200KB (CJK text stays around 33K tokens)
  maxInputFileBytes: number;
  maxFiles: number;          // Attachments allowed on one message (default 3, a model can override it)
}

export const DEFAULT_LIMITS: FileExtractionLimits = {
  maxLines: 500,
  maxBytes: 204_800,                   // 200KB UTF-8 per file (2026 mainstream models have context >= 200K; DeepSeek at 128K can be tightened by an override)
  totalCap: 204_800,                   // 200KB total (CJK worst case around 66K tokens, still 62K of headroom on DeepSeek 128K)
  maxInputFileBytes: 50 * 1024 * 1024, // 50MB hard input cap
  maxFiles: 3,                         // Default
};

/**
 * Merges the defaults with the current model's catalog override.
 */
export function resolveFileExtractionLimits(
  model: ModelWithExtraction | null | undefined,
): FileExtractionLimits {
  const o = model?.attachmentExtraction;
  if (!o) return DEFAULT_LIMITS;
  return {
    maxLines: o.maxLines ?? DEFAULT_LIMITS.maxLines,
    maxBytes: o.maxBytes ?? DEFAULT_LIMITS.maxBytes,
    totalCap: o.totalCap ?? DEFAULT_LIMITS.totalCap,
    maxInputFileBytes: o.maxInputFileBytes ?? DEFAULT_LIMITS.maxInputFileBytes,
    // The count cap accepts the model's maxAttachments; a missing or non-positive-integer value falls back to the default.
    maxFiles: typeof o.maxAttachments === 'number' && Number.isInteger(o.maxAttachments) && o.maxAttachments > 0
      ? o.maxAttachments
      : DEFAULT_LIMITS.maxFiles,
  };
}

// MARK: - Extractor

export const FileTextExtractor = {
  /** All mimes the extractor recognizes (legacy formats excluded), taken from the single type detection list. */
  supportedMimes: new Set<string>(
    Object.entries(SUPPORTED_ATTACHMENT_TYPES)
      .filter(([kind]) => kind !== 'legacy')
      .flatMap(([, entry]) => entry.mimes),
  ),

  /** Plain-text extensions, taken from the single type detection list. */
  textExtensions: new Set<string>(SUPPORTED_ATTACHMENT_TYPES.text.extensions),

  /** Type detection from spec section 2; shared by entry checks and the extractor. */
  classify: classifyAttachmentFile,

  /**
   * Main entry (wrapped with telemetry).
   * @param source telemetry source field (defaults to file; drag-drop / paste callers override it)
   * @param uiLanguage The app's current UI language (next-intl locale), used only to break ties in plain-text encoding detection; falls back to `en`
   */
  async extract(
    file: File,
    limits: FileExtractionLimits = DEFAULT_LIMITS,
    source: 'file' | 'drag_drop' | 'paste' = 'file',
    uiLanguage: string = 'en',
  ): Promise<ExtractedText> {
    const { trackEvent } = await import('../telemetry');
    const startedAt = Date.now();
    const mime = (file.type || '').toLowerCase();

    trackEvent('file_extraction_started', {
      mime,
      size_bytes: file.size,
      source,
    });

    try {
      const result = await FileTextExtractor.extractInner(file, limits, uiLanguage);
      trackEvent('file_extraction_completed', {
        mime,
        total_lines: result.totalLines,
        truncated: result.truncated,
        duration_ms: Date.now() - startedAt,
        fallback_to_native: false,
      });
      return result;
    } catch (e: unknown) {
      const err = e as ExtractionError;
      trackEvent('file_extraction_failed', {
        mime,
        error_code: err?.code ?? 'extraction_error',
        size_bytes: file.size,
      });
      throw e;
    }
  },

  /** Actual extraction logic (outside telemetry)*/
  async extractInner(file: File, limits: FileExtractionLimits, uiLanguage: string = 'en'): Promise<ExtractedText> {
    // SSR boundary guard (pdfjs / TextDecoder GBK are available in the browser only)
    if (typeof window === 'undefined') {
      throw new ExtractionError('extraction_error', 'FileTextExtractor.extract called in SSR context');
    }
    // Check the input hard cap, honoring the model override
    if (file.size > limits.maxInputFileBytes) {
      throw new ExtractionError('file_too_large');
    }

    const kind = classifyAttachmentFile(file.name, file.type);
    // Spec section 14: 30 seconds per extraction; each format checks at the start of its loop.
    const deadline = new ExtractionDeadline();

    let raw: string;

    if (kind === 'pdf') {
      const { extractPdfText } = await import('./extractors/pdf-text-extractor');
      raw = await extractPdfText(file, deadline);
    } else if (kind === 'epub') {
      const { extractEpubText } = await import('./extractors/epub-text-extractor');
      raw = await extractEpubText(file, deadline, uiLanguage);
    } else if (kind === 'html') {
      const { extractHtmlText } = await import('./extractors/html-text-extractor');
      raw = await extractHtmlText(file, uiLanguage);
    } else if (OFFICE_FILE_KINDS.has(kind)) {
      // Spec section 16: encrypted OOXML is an OLE compound document, not a zip; decided before opening the zip.
      if (OOXML_FILE_KINDS.has(kind) && await hasOleCompoundHeader(file)) {
        throw new ExtractionError('password_protected_office', 'OLE compound document');
      }
      // office-parser errors are uniformly mapped to ExtractionError
      try {
        const { parseOfficeFile } = await import('../../utils/office-parser');
        raw = await parseOfficeFile(file, deadline);
      } catch (e: unknown) {
        // The parser already classifies what it can, and relabelling that as corrupted would
        // report "the file is damaged" for a document that is merely oversized.
        if (e instanceof ExtractionError) throw e;
        const err = e as { message?: string };
        const msg = String(err?.message ?? '').toLowerCase();
        if (msg.includes('encrypted') || msg.includes('password') || msg.includes('protected')) {
          throw new ExtractionError('password_protected_office', err?.message);
        }
        throw new ExtractionError('corrupted_file', err?.message);
      }
    } else if (kind === 'text') {
      const { decodeTextBytes } = await import('./extractors/text-decoding');
      raw = decodeTextBytes(new Uint8Array(await file.arrayBuffer()), uiLanguage);
    } else {
      // Legacy formats are blocked at the entry (section 2); if one gets here it is reported as unsupported like any other unrecognized type.
      throw new ExtractionError('unsupported_format');
    }

    return FileTextExtractor.truncate(raw, file.size, limits);
  },

  truncate(raw: string, sizeBytes: number, limits: FileExtractionLimits = DEFAULT_LIMITS): ExtractedText {
    const lines = raw.split('\n');
    const totalLines = lines.length;

    let pickedLines = lines;
    let truncated = false;
    let reason: ExtractedText['truncationReason'] | undefined;

    if (pickedLines.length > limits.maxLines) {
      pickedLines = pickedLines.slice(0, limits.maxLines);
      truncated = true;
      reason = 'lines';
    }

    let joined = pickedLines.join('\n');
    const encoder = new TextEncoder();
    if (encoder.encode(joined).byteLength > limits.maxBytes) {
      // Binary search for the largest number of lines that fits
      let lo = 0, hi = pickedLines.length;
      while (lo < hi) {
        const mid = Math.floor((lo + hi + 1) / 2);
        const candidate = pickedLines.slice(0, mid).join('\n');
        if (encoder.encode(candidate).byteLength <= limits.maxBytes) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      if (lo === 0) {
        // Not even one line fits (minified JSON, a single-line log, PDF text without newlines): picking whole
        // lines would truncate to empty content. Cut inside that line at a UTF-8 character boundary and keep the start.
        joined = sliceUtf8Prefix(encoder.encode(pickedLines[0] ?? ''), limits.maxBytes);
      } else {
        pickedLines = pickedLines.slice(0, lo);
        // Spec section 3.4: lookback alignment to before a heading / page marker
        pickedLines = alignToLogicalBoundary(pickedLines);
        joined = pickedLines.join('\n');
      }
      truncated = true;
      if (!reason) reason = 'bytes';
    }

    return {
      content: joined,
      totalLines,
      truncated,
      truncationReason: reason,
      sizeBytes,
    };
  },
};

/** OLE compound document signature `D0 CF 11 E0 A1 B1 1A E1` (spec section 16). */
const OLE_COMPOUND_SIGNATURE = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];

async function hasOleCompoundHeader(file: File): Promise<boolean> {
  const head = new Uint8Array(await file.slice(0, OLE_COMPOUND_SIGNATURE.length).arrayBuffer());
  return head.length === OLE_COMPOUND_SIGNATURE.length
    && OLE_COMPOUND_SIGNATURE.every((byte, index) => head[index] === byte);
}

/** Take the first `maxBytes` bytes, backing off to a whole UTF-8 character boundary (never splitting a multi-byte character). */
function sliceUtf8Prefix(bytes: Uint8Array, maxBytes: number): string {
  if (bytes.byteLength <= maxBytes) return new TextDecoder().decode(bytes);
  let end = Math.max(0, maxBytes);
  // Continuation bytes are 10xxxxxx: when the cut lands inside a character, back off before that character's first byte.
  while (end > 0 && (bytes[end] & 0xc0) === 0x80) end -= 1;
  return new TextDecoder().decode(bytes.subarray(0, end));
}

/**
 * Spec section 3.4: after bisecting by whole lines to the most lines that fit, look back at most 50 lines; on hitting a heading (`^#{1,6} `) or page marker
 * (`^--- Page `), cut before that line (excluding it), so a section or page is not split in the middle.
 */
const LOGICAL_BOUNDARY = /^(#{1,6} |--- Page )/;
const LOGICAL_BOUNDARY_LOOKBACK = 50;

function alignToLogicalBoundary(lines: string[]): string[] {
  // No alignment when the hit is the first line of the kept part (the result would be empty), so only look down to index 1.
  for (let i = lines.length - 1; i >= Math.max(1, lines.length - LOGICAL_BOUNDARY_LOOKBACK); i--) {
    if (LOGICAL_BOUNDARY.test(lines[i])) {
      return lines.slice(0, i);
    }
  }
  return lines;
}
