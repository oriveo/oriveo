/**
 * File text extraction, single entry point
 *
 * Supported formats: PDF / EPUB / HTML / Office (DOCX/XLSX/PPTX/ODF/RTF) / plain text / source code
 * Truncation rules: 500 lines / 200KB, adjusted by the current model.attachmentExtraction override
 * SSR guard: browser only
 */

// MARK: - Local AIModel interface (avoids a circular dependency)
interface AttachmentExtractionOverride {
  maxLines?: number;
  maxBytes?: number;
  totalCap?: number;
  maxInputFileBytes?: number;
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

// MARK: - Limits

export interface FileExtractionLimits {
  maxLines: number;
  maxBytes: number;
  totalCap: number;          // 200KB (CJK text stays around 33K tokens)
  maxInputFileBytes: number;
  maxFiles: number;          // Hard cap against Lost in the Middle across many files
}

export const DEFAULT_LIMITS: FileExtractionLimits = {
  maxLines: 500,
  maxBytes: 204_800,                   // 200KB UTF-8 per file (2026 mainstream models have context >= 200K; DeepSeek at 128K can be tightened by an override)
  totalCap: 204_800,                   // 200KB total (CJK worst case around 66K tokens, still 62K of headroom on DeepSeek 128K)
  maxInputFileBytes: 50 * 1024 * 1024, // 50MB hard input cap
  maxFiles: 3,                         // Hard cap
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
    maxFiles: DEFAULT_LIMITS.maxFiles, // Product constraint, no model override accepted
  };
}

// MARK: - Extractor

export const FileTextExtractor = {
  supportedMimes: new Set<string>([
    'text/plain', 'text/markdown', 'text/csv', 'text/tab-separated-values',
    'text/x-yaml', 'text/x-toml', 'text/x-ini', 'text/css',
    'text/javascript', 'text/x-python', 'text/x-go',
    'application/json', 'application/xml', 'application/x-yaml',
    'application/javascript', 'application/x-sh',
    'text/html', 'application/xhtml+xml', 'image/svg+xml',
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.oasis.opendocument.text',
    'application/vnd.oasis.opendocument.spreadsheet',
    'application/vnd.oasis.opendocument.presentation',
    'application/rtf', 'text/rtf',
    'application/epub+zip',
  ]),

  textExtensions: new Set<string>([
    'txt','md','markdown','json','jsonl','ndjson','csv','tsv','xml',
    'yaml','yml','toml','ini','cfg','conf','log','env','gitignore','editorconfig',
    'py','js','jsx','ts','tsx','mjs','cjs','go','rs','java','kt','kts','swift','m','mm',
    'c','h','cpp','hpp','cc','cs','rb','php','sh','bash','zsh','ps1','bat','cmd','sql',
    'r','lua','dart','vue','svelte','scss','sass','less','css','gradle','groovy',
    'proto','graphql','svg',
  ]),

  /**
   * Main entry point, wrapped with telemetry.
   * @param source telemetry source field (defaults to file; drag-drop / paste callers override it)
   */
  async extract(
    file: File,
    limits: FileExtractionLimits = DEFAULT_LIMITS,
    source: 'file' | 'drag_drop' | 'paste' = 'file',
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
      const result = await FileTextExtractor.extractInner(file, limits);
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

  /** The actual extraction logic, without the telemetry wrapper */
  async extractInner(file: File, limits: FileExtractionLimits): Promise<ExtractedText> {
    // SSR boundary guard (pdfjs and the GBK TextDecoder are browser only)
    if (typeof window === 'undefined') {
      throw new ExtractionError('extraction_error', 'FileTextExtractor.extract called in SSR context');
    }
    // Check the input hard cap, honoring the model override
    if (file.size > limits.maxInputFileBytes) {
      throw new ExtractionError('file_too_large');
    }

    const ext = (file.name.split('.').pop() || '').toLowerCase();
    const mime = (file.type || '').toLowerCase();

    let raw: string;

    if (mime === 'application/pdf' || ext === 'pdf') {
      const { extractPdfText } = await import('./extractors/pdf-text-extractor');
      raw = await extractPdfText(file);
    } else if (mime === 'application/epub+zip' || ext === 'epub') {
      const { extractEpubText } = await import('./extractors/epub-text-extractor');
      raw = await extractEpubText(file);
    } else if (
      mime === 'text/html' || mime === 'application/xhtml+xml' ||
      ['html', 'htm', 'xhtml'].includes(ext)
    ) {
      const { extractHtmlText } = await import('./extractors/html-text-extractor');
      raw = await extractHtmlText(file);
    } else if (
      mime.startsWith('application/vnd.openxmlformats-officedocument.') ||
      mime.startsWith('application/vnd.oasis.opendocument.') ||
      mime === 'application/rtf' || mime === 'text/rtf' ||
      ['docx', 'xlsx', 'pptx', 'odt', 'ods', 'odp', 'rtf'].includes(ext)
    ) {
      // office-parser failures are mapped to ExtractionError
      try {
        const { parseOfficeFile } = await import('../../utils/office-parser');
        raw = await parseOfficeFile(file);
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
    } else if (
      FileTextExtractor.supportedMimes.has(mime) ||
      FileTextExtractor.textExtensions.has(ext) ||
      mime.startsWith('text/')
    ) {
      raw = await file.text();
    } else {
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
      pickedLines = pickedLines.slice(0, lo);
      // Fall back to a logical separator (XLSX sheet / PPTX slide)
      pickedLines = alignToLogicalBoundary(pickedLines);
      joined = pickedLines.join('\n');
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

/**
 * If the truncation lands in the middle of a structural separator (===Sheet: / ===Slide / ## heading),
 * fall back to the nearest complete section boundary, so a multi-sheet XLSX is not cut mid-sheet.
 */
function alignToLogicalBoundary(lines: string[]): string[] {
  const patterns = ['===Sheet:', '===Slide ', '## '];
  const lookbackMax = 50;
  for (let i = lines.length - 1; i >= Math.max(0, lines.length - lookbackMax); i--) {
    const line = lines[i];
    if (patterns.some((p) => line.startsWith(p))) {
      return lines.slice(0, i);
    }
  }
  return lines;
}
