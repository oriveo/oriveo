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
import type { Attachment } from '@oriveo/shared';
import { loadAttachmentUtils } from '../../utils/attachment-utils-lazy';
import {
  FALLBACK_ATTACHMENT_BYTES,
  limitAttachmentCount,
  partitionFilesByAttachmentSize,
} from '../../utils/attachment-size-policy';
import { showToast } from '../../../components/Toast';
import { DEFAULT_LIMITS } from './file-text-extractor';

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
 * Notice shown at import time when text extraction failed. The attachment keeps its error code as
 * before (on send the injector has the model explain the reason, and a scanned PDF can fall back
 * to native upload); this only spares the user from finding out after sending that the file could
 * not be read.
 */
const EXTRACTION_FAILURE_COPY: Record<string, string> = {
  encrypted_pdf: 'errorPasswordProtected',
  password_protected_office: 'errorPasswordProtected',
  corrupted_file: 'errorCorrupted',
  scanned_pdf: 'errorNoText',
};

export function extractionFailureCopyKey(errorCode: string | undefined): string | null {
  if (!errorCode) return null;
  return EXTRACTION_FAILURE_COPY[errorCode] ?? 'errorGeneric';
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
  const maxAttachments = DEFAULT_LIMITS.maxFiles;

  const sized = partitionFilesByAttachmentSize(request.files, FALLBACK_ATTACHMENT_BYTES);
  if (sized.oversized.length > 0) request.onRejectedBySize(sized.oversized);

  // Hard count limit: without a total cap, a few hundred images would push the message document
  // past 1MiB.
  const counted = limitAttachmentCount(existing.length, sized.accepted, maxAttachments);
  if (counted.rejectedCount > 0) showToast(translate('tooManyFiles', { maxFiles: maxAttachments }));
  if (counted.accepted.length === 0) return;

  const { validateAndConvertFiles } = await loadAttachmentUtils();
  const converted = await validateAndConvertFiles(
    counted.accepted,
    request.source,
    request.providerKind,
    (file) => showToast(translate('errorGeneric', { fileName: file.name })),
  );
  const incoming = converted.filter((attachment) => request.canAcceptAttachment?.(attachment) ?? true);

  for (const attachment of incoming) {
    const copyKey = extractionFailureCopyKey(attachment.extractionErrorCode);
    if (copyKey) showToast(translate(copyKey, { fileName: attachment.fileName ?? '' }));
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
