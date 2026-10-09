/**
 * The single attachment import flow. The file picker, drag and drop, and paste all call
 * {@link importAttachmentFiles}; each entry point only supplies how to read the latest attachment
 * tray, how to merge the result into it, and what to show when a file is over the size limit.
 *
 * When each entry point had its own copy, they shared one defect: the `attachments` array
 * captured at render time was used for two things.
 *  - The count limit was checked against it. A second batch arriving while the first was still
 *    being read saw the same stale length, so the limit did not hold.
 *  - The write-back was built from it (`[...attachments, ...incoming]`). The batch that landed
 *    later replaced the one that landed first.
 *
 * Three guarantees now hold:
 *  1. Batches are queued. One batch runs from the gate to the write-back before the next starts,
 *     so the later batch's gate sees the earlier batch's result. Every file is read into memory
 *     in full, and queueing also keeps the peak at a single file.
 *  2. The write-back is based on the latest state. `commit` is implemented by the caller as a
 *     functional update that uses {@link appendAttachmentsWithinLimit} to cut to the limit using
 *     the real length at that moment. Even if the gate read a value that had not rendered yet,
 *     the result can only accept fewer files, never exceed the limit or overwrite.
 *  3. The gate runs before any bytes are read. Files over the size or count limit are not read.
 */
import type { AIModel, Attachment } from '@oriveo/shared';
import { loadAttachmentUtils } from '../../utils/attachment-utils-lazy';
import {
  FALLBACK_ATTACHMENT_BYTES,
  limitAttachmentCount,
  partitionFilesByAttachmentSize,
} from '../../utils/attachment-size-policy';
import { showToast } from '../../../components/Toast';
import { attachmentTextBudgetBytes } from './attachment-injector';
import { DEFAULT_LIMITS, type FileExtractionLimits, resolveFileExtractionLimits } from './file-text-extractor';

export interface AttachmentImportRequest {
  files: File[];
  source: 'file' | 'drag_drop' | 'paste';
  /** Normalized provider.kind, used for attachment_added reporting. */
  providerKind?: string;
  /** Reads the current attachment tray. Must read a ref or store, never an array captured at render time. */
  getAttachments: () => Attachment[];
  /**
   * Merges new attachments into the tray. The implementation must be a functional update that
   * uses {@link appendAttachmentsWithinLimit} to cut to `maxAttachments` using the length at the
   * moment of merging.
   */
  commit: (incoming: Attachment[], maxAttachments: number) => void;
  /**
   * The currently selected model: extracted text is truncated to the line and byte limits it declares,
   * and the total-budget gate uses its text budget. Defaults apply when omitted. Any mismatch from
   * switching models afterwards is caught by the pre-send check.
   */
  model?: AIModel | null;
  /** Whether the current model and provider can take this attachment (drag and drop and global paste have no picker type filter). */
  canAcceptAttachment?: (attachment: Attachment) => boolean;
  /** Some files were rejected for their size. */
  onRejectedBySize: (files: File[]) => void;
  /** Translation function for the `pages.chat.fileExtraction` namespace. */
  translate: (key: string, values?: Record<string, string | number>) => string;
}

/**
 * Hard limit applied when merging into the tray: accepts a prefix based on the real length of
 * `current` and drops the rest. Pure, so it can be used inside setState.
 */
export function appendAttachmentsWithinLimit(
  current: Attachment[],
  incoming: Attachment[],
  maxAttachments: number,
): Attachment[] {
  const { accepted } = limitAttachmentCount(current.length, incoming, maxAttachments);
  return accepted.length > 0 ? [...current, ...accepted] : current;
}

/**
 * Text limits used at import: the current model's line count, per-file bytes and total text budget; the
 * rest keep their defaults (the file count and input file size have their own gates in the import
 * pipeline and do not follow the model here).
 */
export function resolveImportTextLimits(
  model: AIModel | null | undefined,
): FileExtractionLimits {
  const resolved = resolveFileExtractionLimits(model);
  return {
    ...DEFAULT_LIMITS,
    maxLines: resolved.maxLines,
    maxBytes: resolved.maxBytes,
    totalCap: resolved.totalCap,
  };
}

/**
 * Notice shown at import time when text extraction failed (worded identically on iOS, Android and web).
 */
const EXTRACTION_FAILURE_COPY: Record<string, string> = {
  encrypted_pdf: 'errorPasswordProtected',
  password_protected_office: 'errorPasswordProtected',
  corrupted_file: 'errorCorrupted',
  scanned_pdf: 'errorNoText',
  unsupported_format: 'errorUnsupported',
  file_too_large: 'errorTooLarge',
};

export function extractionFailureCopyKey(errorCode: string | undefined): string | null {
  if (!errorCode) return null;
  return EXTRACTION_FAILURE_COPY[errorCode] ?? 'errorGeneric';
}

/**
 * Whether an attachment whose extraction failed still goes into the tray: only scanned PDFs do (they
 * can still fall back to native upload, or the user can switch to a model that reads PDFs directly).
 * Any other unreadable file would only make the model repeat an error, so it is not added, just explained.
 */
export function keepsFailedExtraction(errorCode: string | undefined): boolean {
  return !errorCode || errorCode === 'scanned_pdf';
}

/**
 * How much of the total text budget this attachment will take when it is injected as text on
 * send. Files that keep their original bytes (PDF / Office) may be uploaded natively instead of
 * injected, and the model used at send time is unknown here, so they count as 0: better to
 * block too little than to reject a file that could have been sent.
 */
function injectedTextBytes(attachment: Attachment): number {
  if (attachment.kind !== 'file' || attachment.extractionErrorCode || attachment.originalBase64Data) return 0;
  return attachmentTextBudgetBytes(attachment.base64Data);
}

/** Shows the notices of one import batch as a single toast, one per line; each extra line adds reading time. */
function showImportNotices(lines: string[]): void {
  if (lines.length === 1) {
    showToast(lines[0]);
    return;
  }
  showToast(lines.join('\n'), Math.min(8000, 3000 + 1500 * (lines.length - 1)));
}

let importQueue: Promise<void> = Promise.resolve();

/**
 * The tray the previous batch saw when it wrote back (by array identity) and the result expected
 * after merging.
 *
 * The write-back is a setState, and the caller's ref only updates after React renders. If the next
 * batch's gate still reads the same array object, that render has not happened yet, so the gate
 * counts against the expected result instead of reading files that have no slot. Once the array
 * identity changes (a render happened, or the user removed attachments or sent the message) only
 * the value that was read counts.
 */
let unrenderedCommit: { seen: Attachment[]; projected: Attachment[] } | null = null;

function currentAttachments(request: AttachmentImportRequest): Attachment[] {
  const read = request.getAttachments();
  return unrenderedCommit && unrenderedCommit.seen === read ? unrenderedCommit.projected : read;
}

/** Yields one macrotask so React renders the previous batch's write-back before the next gate reads. */
const yieldToRender = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

export function importAttachmentFiles(request: AttachmentImportRequest): Promise<void> {
  const run = importQueue.then(() => runImport(request));
  importQueue = run.then(yieldToRender, yieldToRender);
  return run;
}

async function runImport(request: AttachmentImportRequest): Promise<void> {
  const { translate } = request;
  const existing = currentAttachments(request);
  const maxAttachments = resolveFileExtractionLimits(request.model).maxFiles;
  const textLimits = resolveImportTextLimits(request.model);

  const sized = partitionFilesByAttachmentSize(request.files, FALLBACK_ATTACHMENT_BYTES);
  if (sized.oversized.length > 0) request.onRejectedBySize(sized.oversized);

  // Count limit: without a total cap, a few hundred images would push the message document past 1MiB.
  // It is resolved the same way as at send time: the model's maxAttachments, or 3 when absent.
  const counted = limitAttachmentCount(existing.length, sized.accepted, maxAttachments);
  // The toast has a single slot, so a later one replaces an earlier one. This batch's notices are
  // collected here and shown as one toast after the files have been read. "Too many files" is also
  // shown once before reading (large files take a while) and repeated in the summary when a file fails.
  const notices: string[] = [];
  if (counted.rejectedCount > 0) {
    notices.push(translate('tooManyFiles', { maxFiles: maxAttachments }));
    showToast(notices[0]);
  }
  if (counted.accepted.length === 0) return;

  const failures: string[] = [];
  const tooLarge: File[] = [];
  const { validateAndConvertFiles } = await loadAttachmentUtils();
  const converted = await validateAndConvertFiles(
    counted.accepted,
    request.source,
    request.providerKind,
    (file) => failures.push(translate('errorGeneric', { fileName: file.name })),
    (file) => tooLarge.push(file),
    textLimits,
  );
  // A file found to be over the limit only at conversion time still gets the "file too large" notice.
  if (tooLarge.length > 0) request.onRejectedBySize(tooLarge);
  const readable = converted.filter((attachment) => request.canAcceptAttachment?.(attachment) ?? true);
  // Files whose extraction failed (scanned PDFs aside) are not added, only explained.
  const maxInputMB = Math.max(1, Math.floor(resolveFileExtractionLimits(request.model).maxInputFileBytes / (1024 * 1024)));
  const acceptable: Attachment[] = [];
  for (const attachment of readable) {
    if (keepsFailedExtraction(attachment.extractionErrorCode)) {
      acceptable.push(attachment);
      continue;
    }
    const copyKey = extractionFailureCopyKey(attachment.extractionErrorCode) ?? 'errorGeneric';
    failures.push(translate(copyKey, {
      fileName: attachment.fileName ?? '',
      ...(copyKey === 'errorTooLarge' ? { maxMB: maxInputMB } : {}),
    }));
  }

  // Text budget: on send, the injector adds up content bytes in attachment order and skips a file
  // that does not fit, whole and without telling the user. Check here with the same measure and
  // the same budget, and leave out files that do not fit with an explanation.
  const incoming: Attachment[] = [];
  let textBytes = currentAttachments(request).reduce((sum, attachment) => sum + injectedTextBytes(attachment), 0);
  for (const attachment of acceptable) {
    const bytes = injectedTextBytes(attachment);
    if (bytes > 0 && textBytes + bytes > textLimits.totalCap) {
      failures.push(translate('textBudgetExceeded', { fileName: attachment.fileName ?? '' }));
      continue;
    }
    textBytes += bytes;
    incoming.push(attachment);
  }

  // Added but no text could be read (scanned PDFs): say so on the spot too, so the user does not find out after sending.
  for (const attachment of incoming) {
    const copyKey = extractionFailureCopyKey(attachment.extractionErrorCode);
    if (copyKey) failures.push(translate(copyKey, { fileName: attachment.fileName ?? '' }));
  }
  // Say it on the spot when a file was truncated: the ⚠︎ in the attachment bar only says "truncated"; this gives the kept and original line counts.
  const truncations = incoming
    .filter((attachment) => attachment.extractedTruncated && !attachment.extractionErrorCode)
    .map((attachment) => translate('truncatedNotice', {
      fileName: attachment.fileName ?? '',
      shown: (attachment.base64Data ?? '').split('\n').length,
      total: attachment.extractedTotalLines ?? 0,
    }));
  if (failures.length > 0 || truncations.length > 0) {
    showImportNotices([...notices, ...failures, ...truncations]);
  }

  if (incoming.length === 0) return;
  const seen = request.getAttachments();
  unrenderedCommit = {
    seen,
    projected: appendAttachmentsWithinLimit(currentAttachments(request), incoming, maxAttachments),
  };
  request.commit(incoming, maxAttachments);
}

/** Test-only: discards the queue state. */
export function __resetAttachmentImportQueueForTest(): void {
  importQueue = Promise.resolve();
  unrenderedCommit = null;
}
