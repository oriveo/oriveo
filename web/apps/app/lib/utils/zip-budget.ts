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

/** Declares only the small slice of the JSZip entry structure this module uses, avoiding a dependency on the full JSZip types. */
export interface ArchiveEntry {
  name: string;
  dir: boolean;
  async: (type: 'string' | 'uint8array') => Promise<string | Uint8Array>;
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
    this.checkDeclared(entry);

    const text = String(await entry.async('string'));
    this.account(entry, text.length);
    return text;
  }

  /** Raw bytes (EPUB chapters must be decoded by HTML rules themselves, so JSZip must not decode them as UTF-8 first). */
  async readBytes(entry: ArchiveEntry): Promise<Uint8Array> {
    this.checkDeclared(entry);
    const bytes = (await entry.async('uint8array')) as Uint8Array;
    this.account(entry, bytes.byteLength);
    return bytes;
  }

  /**
   * Read and parse an XML part inside an OOXML / ODF / EPUB package (spec section 15, shared by all extractors):
   * if the first 1024 bytes after stripping the BOM contain `<!DOCTYPE` (case-insensitive) → `corrupted_file`, blocking XXE and billion-laughs in one step;
   * if `DOMParser('application/xml')` reports `parsererror` → `corrupted_file`.
   */
  async readXml(entry: ArchiveEntry): Promise<Document> {
    return parsePackageXml(await this.readBytes(entry));
  }

  private checkDeclared(entry: ArchiveEntry): void {
    const declared = declaredUncompressedSize(entry);
    if (declared !== undefined && declared > this.budget.maxEntryBytes) {
      throw new ExtractionError('file_too_large', `entry ${entry.name} declares ${declared} bytes`);
    }
    if (declared !== undefined && this.total + declared > this.budget.maxTotalBytes) {
      throw new ExtractionError('file_too_large', 'archive exceeds the total extraction budget');
    }
  }

  /** Re-check against the actually decompressed length: declared sizes are part of the archive, and a crafted archive can write anything. */
  private account(entry: ArchiveEntry, length: number): void {
    if (length > this.budget.maxEntryBytes) {
      throw new ExtractionError('file_too_large', `entry ${entry.name} expanded past the entry budget`);
    }
    this.total += length;
    if (this.total > this.budget.maxTotalBytes) {
      throw new ExtractionError('file_too_large', 'archive exceeds the total extraction budget');
    }
  }
}

const XML_SNIFF_BYTES = 1024;

/** XML part parsing from spec section 15; see {@link BoundedArchiveReader.readXml}. */
export function parsePackageXml(bytes: Uint8Array): Document {
  const utf16 = bytes.length >= 2 && ((bytes[0] === 0xfe && bytes[1] === 0xff) || (bytes[0] === 0xff && bytes[1] === 0xfe));
  const utf8Bom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
  const start = utf16 ? 2 : utf8Bom ? 3 : 0;
  let head = '';
  const end = Math.min(bytes.length, start + XML_SNIFF_BYTES);
  for (let i = start; i < end; i++) head += String.fromCharCode(bytes[i]);
  if (/<!doctype/i.test(head)) throw new ExtractionError('corrupted_file', 'DTD in package XML');

  let xml: string;
  try {
    const encoding = utf16 ? (bytes[0] === 0xfe ? 'utf-16be' : 'utf-16le') : 'utf-8';
    xml = new TextDecoder(encoding, { fatal: true }).decode(bytes);
  } catch {
    throw new ExtractionError('corrupted_file', 'package XML is not decodable');
  }
  // In UTF-16 bytes `<!DOCTYPE` is interleaved with zero bytes and invisible at the byte level; check the start again after decoding.
  if (utf16 && /<!doctype/i.test(xml.slice(0, XML_SNIFF_BYTES))) {
    throw new ExtractionError('corrupted_file', 'DTD in package XML');
  }
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  if (doc.getElementsByTagName('parsererror').length > 0) {
    throw new ExtractionError('corrupted_file', 'malformed package XML');
  }
  return doc;
}

/** zip entry lookup (spec sections 4A / 10): exact match first, then case-insensitive; directory entries do not count. */
export class ArchiveEntryLookup<Entry extends ArchiveEntry> {
  private readonly byLowerName = new Map<string, string>();

  constructor(private readonly files: Record<string, Entry>) {
    for (const [name, entry] of Object.entries(files)) {
      if (entry.dir) continue;
      const lower = name.toLowerCase();
      if (!this.byLowerName.has(lower)) this.byLowerName.set(lower, name);
    }
  }

  /** All file entry names (directories excluded). */
  get names(): string[] {
    return Object.keys(this.files).filter((name) => !this.files[name].dir);
  }

  find(path: string): Entry | null {
    const exact = Object.prototype.hasOwnProperty.call(this.files, path) ? this.files[path] : undefined;
    if (exact && !exact.dir) return exact;
    const name = this.byLowerName.get(path.toLowerCase());
    return name ? this.files[name] : null;
  }
}
