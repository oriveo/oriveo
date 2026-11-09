/**
 * Backup file format handling.
 * Parses ZIP, JSON and the older fully encrypted blob, detects the format, and serializes
 * deterministically.
 */

import { BlobReader, ZipReader, configure, type FileEntry } from '@zip.js/zip.js';
import type { BackupEntryReader, BackupEntrySource, BackupFile, LegacyBackupPayload } from './backup-types';
import { decrypt, sha256hex } from './backup-crypto';
import { sanitizeMessageQuoteContext } from '@oriveo/shared';

export const BACKUP_VERSION = 1;

// Entries are inflated on the calling thread; there are no worker scripts to host.
configure({ useWebWorkers: false });

const ATTACHMENTS_PREFIX = 'attachments/';

/** Per-entry cap on actual decompressed bytes (the header size is not trusted). */
export const BACKUP_MAX_ENTRY_BYTES = 64 * 1024 * 1024;

/** Cap on the number of archive entries. */
export const BACKUP_MAX_ENTRY_COUNT = 65_536;

const RESOURCE_LIMIT_EXCEEDED = 'RESOURCE_LIMIT_EXCEEDED';

/** Leading bytes sniffed to tell an oversized plain JSON backup from a legacy encrypted blob. */
const JSON_SNIFF_BYTES = 64 * 1024;

/** sha256 hex of every attachments entry, computed by the parse-time scan, keyed like the reader. */
const scannedDigests = new WeakMap<BackupEntryReader, ReadonlyMap<string, string>>();

/**
 * Digests the zip parse already computed for this reader (attachmentChecksums keys), or undefined for readers
 * that were not produced by a zip scan (in-memory maps, JSON backups).
 */
export function scannedEntryDigests(reader: BackupEntryReader): ReadonlyMap<string, string> | undefined {
  return scannedDigests.get(reader);
}

export interface ParseBackupOptions {
  /** Per-entry cap on actual decompressed bytes; defaults to BACKUP_MAX_ENTRY_BYTES. Tests inject a smaller one. */
  maxEntryBytes?: number;
  /** Cap on the number of archive entries; defaults to BACKUP_MAX_ENTRY_COUNT. Tests inject a smaller one. */
  maxEntryCount?: number;
}

/* ========================================================
   Parse a backup file (ZIP, JSON, or the older encrypted blob)
   ======================================================== */

/**
 * A zip backup is read in place from the File through its central directory: only entry names stay in memory and
 * each entry is decompressed on demand. Plain JSON and the legacy encrypted blob are small and read whole.
 */
export async function parseBackupFile(
  file: File,
  password?: string,
  options: ParseBackupOptions = {},
): Promise<{ backupFile: BackupFile; imageEntries: BackupEntryReader }> {
  const maxEntryBytes = options.maxEntryBytes ?? BACKUP_MAX_ENTRY_BYTES;
  const head = new Uint8Array(await file.slice(0, 4).arrayBuffer());
  if (isZip(head)) {
    return parseZipBackup(file, maxEntryBytes, options.maxEntryCount ?? BACKUP_MAX_ENTRY_COUNT);
  }

  // A plain JSON backup is read whole, so it gets the same cap as one archive entry before it is read.
  if (file.size > maxEntryBytes && isJSON(new Uint8Array(await file.slice(0, JSON_SNIFF_BYTES).arrayBuffer()))) {
    throw new Error(RESOURCE_LIMIT_EXCEEDED);
  }

  const buffer = new Uint8Array(await file.arrayBuffer());

  // Older format: a fully encrypted blob (neither ZIP nor JSON) that needs a password.
  if (!isJSON(buffer)) {
    if (!password) throw new Error('PASSWORD_REQUIRED');
    return parseLegacyEncrypted(buffer, password);
  }

  // Plain JSON format (compatibility with older backups).
  return parseJsonBackup(buffer);
}

/**
 * Every entry is decompressed once here, before any preview or write: the entry count, each entry's actual bytes
 * and its CRC are checked, so an import that passes the preview cannot fail half way through replaceAll.
 */
async function parseZipBackup(
  file: Blob,
  maxEntryBytes: number,
  maxEntryCount: number,
): Promise<{ backupFile: BackupFile; imageEntries: BackupEntryReader }> {
  const entries: FileEntry[] = [];
  let entryCount = 0;
  let tooManyEntries = false;
  try {
    for await (const entry of new ZipReader(new BlobReader(file)).getEntriesGenerator()) {
      entryCount += 1;
      if (entryCount > maxEntryCount) {
        tooManyEntries = true;
        break;
      }
      if (!entry.directory) entries.push(entry);
    }
  } catch {
    throw new Error('INVALID_FORMAT');
  }
  if (tooManyEntries) throw new Error(RESOURCE_LIMIT_EXCEEDED);

  const dataJsonEntry = entries.find((entry) => entry.filename === 'data.json');
  if (!dataJsonEntry) throw new Error('INVALID_FORMAT');

  const jsonStr = new TextDecoder().decode(await readEntryCapped(dataJsonEntry, maxEntryBytes));
  const backupFile = JSON.parse(jsonStr) as BackupFile;

  if (!backupFile.version || !backupFile.data) throw new Error('INVALID_FORMAT');
  if (backupFile.version > BACKUP_VERSION) throw Object.assign(new Error('VERSION_TOO_NEW'), { version: backupFile.version as number });

  // attachments/<name> is keyed by its relative name, which is also its attachmentChecksums key.
  const byName = new Map<string, FileEntry>();
  const digests = new Map<string, string>();
  for (const entry of entries) {
    if (entry === dataJsonEntry) continue;
    // One entry in memory at a time; over the cap or a CRC mismatch rejects the whole file here.
    const bytes = await readEntryCapped(entry, maxEntryBytes);
    const name = readerEntryName(entry.filename);
    if (name === null) continue;
    byName.set(name, entry);
    digests.set(name, await sha256hex(bytes));
  }
  const names = [...byName.keys()];
  const imageEntries: BackupEntryReader = {
    names,
    has: (name) => byName.has(name),
    read: async (name) => {
      const entry = byName.get(name);
      return entry ? readEntryCapped(entry, maxEntryBytes) : null;
    },
  };
  scannedDigests.set(imageEntries, digests);

  return { backupFile: sanitizeBackupQuoteContexts(backupFile), imageEntries };
}

/** Reader name of an archive entry under attachments/ (its relative name), or null for any other entry. */
function readerEntryName(filename: string): string | null {
  if (!filename.startsWith(ATTACHMENTS_PREFIX)) return null;
  const relative = filename.slice(ATTACHMENTS_PREFIX.length);
  return relative || null;
}

/** Decompresses one entry, counting the bytes actually produced; past maxBytes it rejects with RESOURCE_LIMIT_EXCEEDED. */
async function readEntryCapped(entry: FileEntry, maxBytes: number): Promise<Uint8Array> {
  // The declared size only fails fast; acceptance is decided by the bytes the inflater produces.
  if (entry.uncompressedSize > maxBytes) throw new Error(RESOURCE_LIMIT_EXCEEDED);
  const chunks: Uint8Array[] = [];
  let total = 0;
  let exceeded = false;
  const sink = new WritableStream<Uint8Array>({
    write(chunk) {
      total += chunk.byteLength;
      if (total > maxBytes) {
        exceeded = true;
        throw new Error(RESOURCE_LIMIT_EXCEEDED);
      }
      chunks.push(new Uint8Array(chunk));
    },
  });
  try {
    await entry.getData(sink, { checkSignature: true });
  } catch {
    if (exceeded) throw new Error(RESOURCE_LIMIT_EXCEEDED);
    // A CRC mismatch or a damaged stream: the entry cannot be trusted.
    throw new Error('INVALID_FORMAT');
  }
  if (exceeded) throw new Error(RESOURCE_LIMIT_EXCEEDED);
  if (chunks.length === 1) return chunks[0];
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

const EMPTY_ENTRY_READER: BackupEntryReader = {
  names: [],
  has: () => false,
  read: async () => null,
};

/** Wraps an in-memory name → bytes map (tests, JSON backups) as a reader. */
export function backupEntryReaderFromMap(map: ReadonlyMap<string, Uint8Array>): BackupEntryReader {
  return {
    names: [...map.keys()],
    has: (name) => map.has(name),
    read: async (name) => map.get(name) ?? null,
  };
}

/** Normalizes what import entry points accept to a reader. */
export function toBackupEntryReader(source: BackupEntrySource): BackupEntryReader {
  return typeof (source as BackupEntryReader).read === 'function'
    ? source as BackupEntryReader
    : backupEntryReaderFromMap(source as ReadonlyMap<string, Uint8Array>);
}

async function parseJsonBackup(
  buffer: Uint8Array,
): Promise<{ backupFile: BackupFile; imageEntries: BackupEntryReader }> {
  const jsonStr = new TextDecoder().decode(buffer);
  const parsed = JSON.parse(jsonStr);

  // Newer JSON format (has version and data).
  if (parsed.version && parsed.data) {
    if (parsed.version > BACKUP_VERSION) throw Object.assign(new Error('VERSION_TOO_NEW'), { version: parsed.version as number });
    return { backupFile: sanitizeBackupQuoteContexts(parsed as BackupFile), imageEntries: EMPTY_ENTRY_READER };
  }

  // Older JSON format (an unencrypted BackupPayload).
  if (parsed.metadata?.version && parsed.conversations) {
    const legacy = parsed as LegacyBackupPayload;
    const backupFile = convertLegacyPayload(legacy);
    return { backupFile: sanitizeBackupQuoteContexts(backupFile), imageEntries: EMPTY_ENTRY_READER };
  }

  throw new Error('INVALID_FORMAT');
}

async function parseLegacyEncrypted(
  buffer: Uint8Array,
  password: string,
): Promise<{ backupFile: BackupFile; imageEntries: BackupEntryReader }> {
  const decrypted = await decrypt(buffer, password);
  const jsonStr = new TextDecoder().decode(decrypted);
  const parsed = JSON.parse(jsonStr);

  if (parsed.metadata?.version && parsed.conversations) {
    const legacy = parsed as LegacyBackupPayload;
    const backupFile = convertLegacyPayload(legacy);
    return { backupFile: sanitizeBackupQuoteContexts(backupFile), imageEntries: EMPTY_ENTRY_READER };
  }

  throw new Error('INVALID_FORMAT');
}

function convertLegacyPayload(legacy: LegacyBackupPayload): BackupFile {
  return {
    version: 1,
    createdAt: legacy.metadata.createdAt,
    appVersion: legacy.metadata.appVersion,
    platform: 'Web',
    checksum: '',
    containsKeys: legacy.metadata.includesApiKeys,
    data: {
      providers: legacy.providers,
      conversations: legacy.conversations,
    },
    encryptedKeys: null,
  };
}

function sanitizeBackupQuoteContexts(backupFile: BackupFile): BackupFile {
  let changed = false;
  const conversations = backupFile.data.conversations.map((conversation) => {
    let messagesChanged = false;
    const messages = conversation.messages.map((message) => {
      const sanitized = sanitizeMessageQuoteContext(message);
      if (sanitized !== message) messagesChanged = true;
      return sanitized;
    });
    if (!messagesChanged) return conversation;
    changed = true;
    return { ...conversation, messages };
  });
  if (!changed) return backupFile;
  return {
    ...backupFile,
    data: { ...backupFile.data, conversations },
  };
}

/* -- Format detection ------------------------------------ */

function isZip(data: Uint8Array): boolean {
  return data.length >= 4 && data[0] === 0x50 && data[1] === 0x4b;
}

function isJSON(data: Uint8Array): boolean {
  let index = 0;

  // A UTF-8 BOM prefix is allowed.
  if (data.length >= 3 && data[0] === 0xef && data[1] === 0xbb && data[2] === 0xbf) {
    index = 3;
  }

  // Only JSON-legal leading whitespace is skipped, so an arbitrary control byte is not mistaken for JSON.
  while (index < data.length && index < 10 && isJSONLeadingWhitespace(data[index])) {
    index += 1;
  }

  return data[index] === 0x7b || data[index] === 0x5b; // '{' or '['
}

function isJSONLeadingWhitespace(byte: number): boolean {
  return byte === 0x20 || byte === 0x09 || byte === 0x0a || byte === 0x0d;
}

/* -- Deterministic JSON serialization (sorted keys) ------- */

export function canonicalJSON(obj: any): string {
  return JSON.stringify(obj, (_key, value) => {
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      return Object.keys(value)
        .sort()
        .reduce<Record<string, any>>((sorted, k) => {
          sorted[k] = value[k];
          return sorted;
        }, {});
    }
    return value;
  });
}
