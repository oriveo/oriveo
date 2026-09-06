/**
 * Decompression budget for the zip-backed attachment formats (Office and EPUB).
 *
 * A zip stores the uncompressed size of every entry, so a few kilobytes on disk can declare
 * gigabytes of output. Reading such an archive is enough to exhaust the tab: the same trick that
 * makes a "zip bomb" works just as well through a document the user was invited to attach. The
 * budget below is the same one the mobile clients apply, so a file that is refused on one platform
 * is refused on all of them.
 *
 * Both halves are needed. The declared sizes are checked up front, which rejects the cheap bombs
 * without reading a byte; the length of each entry is then checked again after decompression,
 * because the header is attacker-controlled and may simply understate the truth.
 */

import { ExtractionError } from '../core/attachments/file-text-extractor';

export interface ArchiveBudget {
  /** Largest single entry that may be decompressed. */
  maxEntryBytes: number;
  /** Largest total across every entry read from one archive. */
  maxTotalBytes: number;
  /** Most entries an archive may declare. */
  maxEntries: number;
}

export const ATTACHMENT_ARCHIVE_BUDGET: ArchiveBudget = {
  maxEntryBytes: 8 * 1024 * 1024,
  maxTotalBytes: 32 * 1024 * 1024,
  maxEntries: 4_096,
};

/** The subset of a JSZip entry this module needs, so it does not depend on the whole type. */
interface ArchiveEntry {
  name: string;
  dir: boolean;
  async: (type: 'string') => Promise<string>;
}

type ArchiveFiles = Record<string, ArchiveEntry & { _data?: { uncompressedSize?: number } }>;

function declaredUncompressedSize(entry: ArchiveEntry): number | undefined {
  const declared = (entry as { _data?: { uncompressedSize?: unknown } })._data?.uncompressedSize;
  return typeof declared === 'number' && Number.isFinite(declared) && declared >= 0
    ? declared
    : undefined;
}

/**
 * Rejects an archive whose central directory is already outside the budget.
 *
 * Entries with no declared size are simply not counted here; the reader still bounds them once
 * their content is in hand.
 */
export function assertArchiveWithinBudget(
  files: ArchiveFiles,
  budget: ArchiveBudget = ATTACHMENT_ARCHIVE_BUDGET,
): void {
  const entries = Object.values(files);
  if (entries.length > budget.maxEntries) {
    throw new ExtractionError('file_too_large', `archive declares ${entries.length} entries`);
  }

  let declaredTotal = 0;
  for (const entry of entries) {
    if (entry.dir) continue;
    const size = declaredUncompressedSize(entry);
    if (size === undefined) continue;
    if (size > budget.maxEntryBytes) {
      throw new ExtractionError('file_too_large', `entry ${entry.name} declares ${size} bytes`);
    }
    declaredTotal += size;
    if (declaredTotal > budget.maxTotalBytes) {
      throw new ExtractionError('file_too_large', 'archive declares more than the total budget');
    }
  }
}

/**
 * Reads entries as text while holding the running total inside the budget.
 *
 * One reader per archive: the total is per document, so a thousand small chapters cannot add up to
 * more than a single oversized entry would have been allowed.
 */
export class BoundedArchiveReader {
  private total = 0;

  constructor(private readonly budget: ArchiveBudget = ATTACHMENT_ARCHIVE_BUDGET) {}

  async readText(entry: ArchiveEntry): Promise<string> {
    const declared = declaredUncompressedSize(entry);
    if (declared !== undefined && declared > this.budget.maxEntryBytes) {
      throw new ExtractionError('file_too_large', `entry ${entry.name} declares ${declared} bytes`);
    }
    if (declared !== undefined && this.total + declared > this.budget.maxTotalBytes) {
      throw new ExtractionError('file_too_large', 'archive exceeds the total extraction budget');
    }

    const text = await entry.async('string');
    // Re-check against what actually came out: the declared size is part of the archive and a
    // crafted one can claim anything.
    if (text.length > this.budget.maxEntryBytes) {
      throw new ExtractionError('file_too_large', `entry ${entry.name} expanded past the entry budget`);
    }
    this.total += text.length;
    if (this.total > this.budget.maxTotalBytes) {
      throw new ExtractionError('file_too_large', 'archive exceeds the total extraction budget');
    }
    return text;
  }
}
