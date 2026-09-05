/**
 * Backup file format handling.
 * Parses ZIP, JSON and the older fully encrypted blob, detects the format, and serializes
 * deterministically.
 */

import JSZip from 'jszip';
import type { BackupFile, LegacyBackupPayload } from './backup-types';
import { decrypt } from './backup-crypto';
import { sanitizeMessageQuoteContext } from '@oriveo/shared';

const BACKUP_VERSION = 1;

/* ========================================================
   Parse a backup file (ZIP, JSON, or the older encrypted blob)
   ======================================================== */

export async function parseBackupFile(
  file: File,
  password?: string,
): Promise<{ backupFile: BackupFile; imageEntries: Map<string, Uint8Array> }> {
  const buffer = new Uint8Array(await file.arrayBuffer());

  // Older format: a fully encrypted blob (neither ZIP nor JSON) that needs a password.
  if (!isZip(buffer) && !isJSON(buffer)) {
    if (!password) throw new Error('PASSWORD_REQUIRED');
    return parseLegacyEncrypted(buffer, password);
  }

  // ZIP format.
  if (isZip(buffer)) {
    return parseZipBackup(buffer);
  }

  // Plain JSON format (compatibility with older backups).
  return parseJsonBackup(buffer);
}

async function parseZipBackup(
  buffer: Uint8Array,
): Promise<{ backupFile: BackupFile; imageEntries: Map<string, Uint8Array> }> {
  const zip = await JSZip.loadAsync(buffer);

  const dataJsonFile = zip.file('data.json');
  if (!dataJsonFile) throw new Error('INVALID_FORMAT');

  const jsonStr = await dataJsonFile.async('string');
  const backupFile = JSON.parse(jsonStr) as BackupFile;

  if (!backupFile.version || !backupFile.data) throw new Error('INVALID_FORMAT');
  if (backupFile.version > BACKUP_VERSION) throw new Error('VERSION_TOO_NEW');

  // Read the images under attachments/.
  const imageEntries = new Map<string, Uint8Array>();
  const attachmentsFolder = zip.folder('attachments');
  if (attachmentsFolder) {
    const filePromises: Promise<void>[] = [];
    attachmentsFolder.forEach((relativePath, zipEntry) => {
      filePromises.push(
        zipEntry.async('uint8array').then((data) => {
          imageEntries.set(relativePath, data);
        }),
      );
    });
    await Promise.all(filePromises);
  }

  return { backupFile: sanitizeBackupQuoteContexts(backupFile), imageEntries };
}

async function parseJsonBackup(
  buffer: Uint8Array,
): Promise<{ backupFile: BackupFile; imageEntries: Map<string, Uint8Array> }> {
  const jsonStr = new TextDecoder().decode(buffer);
  const parsed = JSON.parse(jsonStr);

  // Newer JSON format (has version and data).
  if (parsed.version && parsed.data) {
    if (parsed.version > BACKUP_VERSION) throw new Error('VERSION_TOO_NEW');
    return { backupFile: sanitizeBackupQuoteContexts(parsed as BackupFile), imageEntries: new Map() };
  }

  // Older JSON format (an unencrypted BackupPayload).
  if (parsed.metadata?.version && parsed.conversations) {
    const legacy = parsed as LegacyBackupPayload;
    const backupFile = convertLegacyPayload(legacy);
    return { backupFile: sanitizeBackupQuoteContexts(backupFile), imageEntries: new Map() };
  }

  throw new Error('INVALID_FORMAT');
}

async function parseLegacyEncrypted(
  buffer: Uint8Array,
  password: string,
): Promise<{ backupFile: BackupFile; imageEntries: Map<string, Uint8Array> }> {
  const decrypted = await decrypt(buffer, password);
  const jsonStr = new TextDecoder().decode(decrypted);
  const parsed = JSON.parse(jsonStr);

  if (parsed.metadata?.version && parsed.conversations) {
    const legacy = parsed as LegacyBackupPayload;
    const backupFile = convertLegacyPayload(legacy);
    return { backupFile: sanitizeBackupQuoteContexts(backupFile), imageEntries: new Map() };
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
