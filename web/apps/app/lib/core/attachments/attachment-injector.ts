/**
 * AttachmentInjector - wraps extracted file content in ATTACHMENT_FILE blocks
 *
 * Two formats are supported:
 * - xml-v1: default for Anthropic/OpenAI/Gemini/OpenRouter/Llama
 * - markdown-v1: default for DeepSeek/Qwen/Moonshot/Zhipu/MiniMax/SiliconFlow
 *
 * On failure a strict instruction is emitted so the model does not invent content.
 * Limits: 200KB in total and a hard cap of 3 files.
 */

import {
  type ExtractedText,
  type ExtractionErrorCode,
  type FileExtractionLimits,
  DEFAULT_LIMITS,
} from './file-text-extractor';

export type AttachmentWrapperVersion = 'xml-v1' | 'markdown-v1';

// markdown-v1 family: OpenAI-compatible models trained mainly on Chinese corpora prefer ChatML + Markdown
const MARKDOWN_V1_PROVIDERS = new Set([
  'deepseek', 'qwen', 'moonshot', 'zhipu', 'miniMax', 'siliconFlow',
]);

/** Picks the default wrapper by provider kind */
export function resolveWrapperVersion(providerKind: string): AttachmentWrapperVersion {
  if (MARKDOWN_V1_PROVIDERS.has(providerKind)) return 'markdown-v1';
  return 'xml-v1';
}

export interface AttachmentPayload {
  fileName: string;
  mimeType: string;
  sizeBytes: number;
  extracted: ExtractedText | null;
  errorCode?: ExtractionErrorCode;
}

export type SkipReason = 'too_many_files' | 'total_cap_exceeded';

export interface SkippedAttachment {
  fileName: string;
  reason: SkipReason;
}

// Strict instruction text, identical across clients
const ERROR_INSTRUCTIONS: Record<ExtractionErrorCode, string> = {
  encrypted_pdf:
    'This file is encrypted and cannot be read. DO NOT fabricate or guess content. Tell the user the file is encrypted and ask them to decrypt it before uploading.',
  scanned_pdf:
    'This is a scanned PDF without a text layer. The current model cannot OCR it. DO NOT fabricate content. Tell the user to switch to a vision-capable model (e.g., GPT-4o, Claude 3.5 Sonnet, Gemini 2.5 Pro) and re-upload.',
  password_protected_office:
    'This Office file is password-protected and cannot be read. DO NOT fabricate content. Tell the user to remove the password and re-upload.',
  corrupted_file:
    'This file is corrupted and cannot be parsed. DO NOT fabricate content. Tell the user the file may be damaged and ask them to re-upload a valid copy.',
  unsupported_format:
    'This file format is not supported by the local extractor. DO NOT fabricate content. Tell the user which formats are supported (PDF / DOCX / XLSX / PPTX / EPUB / HTML / plain text / code files).',
  file_too_large:
    'This file is past the size the local extractor will read, either as stored or once unpacked. DO NOT fabricate content. Tell the user the file is too large and ask them to split or shorten it.',
  extraction_timeout:
    'Extraction of this file timed out (over 30 seconds). DO NOT fabricate content. Tell the user the file is too complex; ask them to simplify or split it.',
  extraction_error:
    'Extraction failed due to an internal error. DO NOT fabricate content. Tell the user to try again or use a different file.',
};

/** MIME type to a short familiar suffix, which saves tokens */
function fileTypeShort(mime: string, fileName: string): string {
  const lower = mime.toLowerCase();
  const map: Record<string, string> = {
    'application/pdf': 'pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
    'application/vnd.oasis.opendocument.text': 'odt',
    'application/vnd.oasis.opendocument.spreadsheet': 'ods',
    'application/vnd.oasis.opendocument.presentation': 'odp',
    'application/epub+zip': 'epub',
    'text/html': 'html',
    'application/xhtml+xml': 'html',
    'text/markdown': 'md',
    'application/json': 'json',
    'application/xml': 'xml',
    'text/xml': 'xml',
    'application/rtf': 'rtf',
    'text/rtf': 'rtf',
    'image/svg+xml': 'svg',
  };
  return map[lower] ?? (fileName.split('.').pop()?.toLowerCase() || 'txt');
}

export const AttachmentInjector = {
// System prompt guidance: appended to the end of the system prompt when attachments are present
  SYSTEM_PROMPT_GUIDANCE:
    "When the user attaches files (see <ATTACHMENT_FILE> blocks or \"## Attachment N:\" sections in the message), refer to them by file name in your response. If a file's content is an [ERROR: ...] block, do not fabricate the content — explain the error to the user and follow the embedded instruction.",

// xml-v1, the default format
  formatAttachmentXml(index: number, p: AttachmentPayload): string {
    const lines: string[] = [];
    const sizeKB = Math.ceil(p.sizeBytes / 1024);
    const fileType = fileTypeShort(p.mimeType, p.fileName);
    lines.push('<ATTACHMENT_FILE>');
    lines.push(`<FILE_INDEX>${index}</FILE_INDEX>`);
    lines.push(`<FILE_NAME>${p.fileName}</FILE_NAME>`);
    lines.push(`<FILE_TYPE>${fileType}</FILE_TYPE>`);
    if (p.extracted) lines.push(`<FILE_LINES>${p.extracted.totalLines}</FILE_LINES>`);
    lines.push(`<FILE_SIZE_KB>${sizeKB}</FILE_SIZE_KB>`);
    lines.push('<FILE_CONTENT>');
    if (p.extracted) {
      lines.push(p.extracted.content);
    } else {
// Strict instruction
      const code = p.errorCode ?? 'extraction_error';
      lines.push(`[ERROR: extraction failed - ${code}]`);
      lines.push(`[INSTRUCTION: ${ERROR_INSTRUCTIONS[code]}]`);
    }
    lines.push('</FILE_CONTENT>');
    if (p.extracted?.truncated) {
      const n = p.extracted.content.split('\n').length;
      const total = p.extracted.totalLines;
      if (p.extracted.truncationReason === 'lines') {
        lines.push(`<TRUNCATED>showing first ${n} of ${total} lines (size cap 200KB)</TRUNCATED>`);
      } else if (p.extracted.truncationReason === 'bytes') {
        lines.push(`<TRUNCATED>showing first ${n} of ${total} lines (truncated to fit 200KB cap)</TRUNCATED>`);
      }
    }
    lines.push('</ATTACHMENT_FILE>');
    return lines.join('\n');
  },

// markdown-v1, the alternative format
  formatAttachmentMarkdown(index: number, p: AttachmentPayload): string {
    const lines: string[] = [];
    const sizeKB = Math.ceil(p.sizeBytes / 1024);
    const fileType = fileTypeShort(p.mimeType, p.fileName);
    lines.push('---');
    lines.push(`## Attachment ${index}: ${p.fileName}`);
    lines.push(`- Type: ${fileType}`);
    lines.push(`- Size: ${sizeKB} KB`);
    if (p.extracted) {
      if (p.extracted.truncated) {
        const n = p.extracted.content.split('\n').length;
        lines.push(`- Lines: ${p.extracted.totalLines} (showing first ${n}, size cap 200KB)`);
      } else {
        lines.push(`- Lines: ${p.extracted.totalLines}`);
      }
      lines.push('');
      lines.push('```');
      lines.push(p.extracted.content);
      lines.push('```');
    } else {
      const code = p.errorCode ?? 'extraction_error';
      lines.push(`- Status: **EXTRACTION FAILED** (error: ${code})`);
      lines.push('');
      lines.push(`> **Instruction to model:** ${ERROR_INSTRUCTIONS[code]}`);
    }
    lines.push('---');
    return lines.join('\n');
  },

  formatAttachment(
    wrapper: AttachmentWrapperVersion,
    index: number,
    p: AttachmentPayload,
  ): string {
    return wrapper === 'xml-v1'
      ? AttachmentInjector.formatAttachmentXml(index, p)
      : AttachmentInjector.formatAttachmentMarkdown(index, p);
  },

  /**
   * Appends every attachment to the end of userText.
   *
   * @param limits thresholds for the current model
   * @param wrapper wrapping format chosen by provider
   */
  injectAll(
    userText: string,
    payloads: AttachmentPayload[],
    limits: FileExtractionLimits = DEFAULT_LIMITS,
    wrapper: AttachmentWrapperVersion = 'xml-v1',
  ): { text: string; skipped: SkippedAttachment[] } {
    const parts: string[] = [];
    if (userText.trim().length > 0) parts.push(userText);

    let consumed = 0;
    const skipped: SkippedAttachment[] = [];
    let emittedIndex = 0;
    const encoder = new TextEncoder();

    for (const p of payloads) {
      // Hard cap on the number of files
      if (emittedIndex >= limits.maxFiles) {
        skipped.push({ fileName: p.fileName, reason: 'too_many_files' });
        continue;
      }
      const block = AttachmentInjector.formatAttachment(wrapper, emittedIndex + 1, p);
      const blockBytes = encoder.encode(block).byteLength;
      // Total size cap
      if (consumed + blockBytes > limits.totalCap) {
        skipped.push({ fileName: p.fileName, reason: 'total_cap_exceeded' });
        continue;
      }
      parts.push(block);
      consumed += blockBytes;
      emittedIndex += 1;
    }

    return { text: parts.join('\n\n'), skipped };
  },
};
