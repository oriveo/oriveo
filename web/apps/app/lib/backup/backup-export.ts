/**
 * Backup export flow.
 * Collect data -> sanitize -> collect images -> checksum -> optional key encryption -> ZIP.
 */

import JSZip from 'jszip';
import type { AppPreference, LastUsedModelRef, Provider, Skill } from '@oriveo/shared';
import { credentialFreeRelayRequested, isValidProviderKind, stripRelayURLSecrets } from '@oriveo/shared';
import type { BackupFile, BackupData, ExportOptions } from './backup-types';
import {
  getAllConversations,
  getAllFolders,
  getAllProviders,
  getAllNotes,
  getAllNoteFolders,
  getSessionValue,
} from '../infra/storage/idb';
import { loadImageData, loadThumbnailData } from '../infra/storage/image-store';
import { sha256hex, encrypt, uint8ToBase64 } from './backup-crypto';
import { canonicalJSON } from './backup-format';
import { getPreference } from '../infra/storage/preferences';
import { loadCachedUserSkills } from '../core/skills/cache';
import { trackEvent } from '../core/telemetry';
import { APP_VERSION } from '../version';

const BACKUP_VERSION = 1;

export interface AutomaticBackupStorageResult {
  storage: string;
  fileName: string;
  fileSizeBytes: number;
}

export interface AutomaticBackupChunkWriter {
  write: (chunk: Uint8Array) => Promise<void>;
  close: () => Promise<AutomaticBackupStorageResult>;
  abort: (reason?: unknown) => Promise<void>;
}

export interface AutomaticBackupStorage {
  createWriter: (fileName: string) => Promise<AutomaticBackupChunkWriter>;
}

interface ExportAutomaticBackupOptions {
  storage: AutomaticBackupStorage;
  fileName: string;
}

/* ========================================================
   Export
   ======================================================== */

export async function exportBackup(options: ExportOptions): Promise<Blob> {
  const zip = await buildBackupZip(options);
  const blob = await zip.generateAsync({ type: 'blob' });
  trackEvent('backup_exported', {
    encrypted: Boolean(options.includeApiKeys),
    size_bytes: blob.size,
    target: 'manual_download',
  });
  return blob;
}

export async function exportBackupToAutomaticStorage(
  options: ExportOptions,
  automaticOptions: ExportAutomaticBackupOptions,
): Promise<AutomaticBackupStorageResult> {
  const zip = await buildBackupZip(options);
  const writer = await automaticOptions.storage.createWriter(automaticOptions.fileName);

  try {
    const bytesWritten = await writeZipToChunkWriter(zip, writer);
    const metadata = await writer.close();
    trackEvent('backup_exported', {
      encrypted: Boolean(options.includeApiKeys),
      size_bytes: metadata.fileSizeBytes || bytesWritten,
      target: 'automatic_storage',
    });
    return {
      storage: metadata.storage,
      fileName: metadata.fileName || automaticOptions.fileName,
      fileSizeBytes: metadata.fileSizeBytes || bytesWritten,
    };
  } catch (error) {
    try {
      await writer.abort(error);
    } catch {
      // fallback cleanup failure should not hide the root cause
    }
    throw error;
  }
}

async function buildBackupZip(options: ExportOptions): Promise<JSZip> {
  const [conversations, folders, providers, notes, noteFolders, lastUsedModelRef, skills] = await Promise.all([
    getAllConversations(),
    getAllFolders(),
    getAllProviders(),
    getAllNotes(),
    getAllNoteFolders(),
    getSessionValue<LastUsedModelRef | null>('lastUsedModelRef'),
    loadCachedUserSkills(),
  ]);
  // The backup format has no way to express "unset", so an unset preference exports the product default currently in effect (dark).
  const preferences = getPreference<AppPreference>('preferences', {
    theme: 'dark',
    language: 'system',
    sendShortcut: 'enter',
  });

  // Provider field sanitization
  const sanitizedProviders = sanitizeProviders(providers);
  const sanitizedSkills = sanitizeSkillsForBackup(skills);

  // Collect image attachments and write them into the ZIP.
  const zip = new JSZip();
  const attachmentChecksums: Record<string, string> = {};

  for (const conv of conversations) {
    for (const msg of conv.messages) {
      if (!msg.attachments) continue;
      for (const att of msg.attachments) {
        if (att.kind !== 'image' || !att.localImageID) continue;

        const [imageBlob, thumbBlob] = await Promise.all([
          loadImageData(att.localImageID),
          loadThumbnailData(att.localImageID),
        ]);

        // The <name> in attachments/<name>.jpg is always attachment.id. The iOS and Android clients
        // have always used attachment.id and only Web used localImageID, so restoring across clients
        // could not find the entry under the other side's naming rule - and no restore path has a
        // base64 fallback, so the image was silently lost. The import side keeps a localImageID
        // fallback so archives exported under the old naming still restore.
        if (imageBlob) {
          const filename = `${att.id}.jpg`;
          const data = new Uint8Array(await imageBlob.arrayBuffer());
          zip.file(`attachments/${filename}`, data);
          attachmentChecksums[filename] = `sha256:${await sha256hex(data)}`;
        }

        if (thumbBlob) {
          const thumbFilename = `${att.id}.thumb.jpg`;
          const thumbData = new Uint8Array(await thumbBlob.arrayBuffer());
          zip.file(`attachments/${thumbFilename}`, thumbData);
          attachmentChecksums[thumbFilename] = `sha256:${await sha256hex(thumbData)}`;
        }
      }
    }
  }

  // Build the data object.
  const data: BackupData = {
    providers: sanitizedProviders,
    conversations,
    ...(sanitizedSkills.length > 0 ? { skills: sanitizedSkills } : {}),
    folders,
    notes,
    noteFolders,
    preferences: {
      theme: preferences.theme,
      language: preferences.language,
    },
    lastUsedModelRef,
  };

  // Deterministic serialization with sorted keys.
  const dataJson = canonicalJSON(data);
  const checksum = await sha256hex(new TextEncoder().encode(dataJson));

  // Optional API key encryption.
  let encryptedKeys: string | null = null;
  if (options.includeApiKeys && options.password) {
    const keys = providers
      // Relay credentials stay on this device. Besides the primary key, custom headers/query
      // can carry additional secrets and are already stripped from the portable provider copy.
      .filter((p) => p.kind !== 'relay' && p.apiKey)
      .map((p) => ({
        providerID: p.id,
        apiKey: p.apiKey,
        apiKeyPreview: p.apiKeyPreview,
      }));

    if (keys.length > 0) {
      const keysJson = JSON.stringify({ keys });
      const encrypted = await encrypt(
        new TextEncoder().encode(keysJson),
        options.password,
      );
      encryptedKeys = uint8ToBase64(encrypted);
    }
  }

  // Build data.json.
  const backupFile: BackupFile = {
    version: BACKUP_VERSION,
    createdAt: new Date().toISOString(),
    appVersion: process.env.NEXT_PUBLIC_APP_VERSION ?? APP_VERSION,
    platform: 'Web',
    checksum: `sha256:${checksum}`,
    containsKeys: !!encryptedKeys,
    data,
    attachmentChecksums:
      Object.keys(attachmentChecksums).length > 0 ? attachmentChecksums : undefined,
    encryptedKeys,
  };

  zip.file('data.json', canonicalJSON(backupFile));
  return zip;
}

async function writeZipToChunkWriter(
  zip: JSZip,
  writer: AutomaticBackupChunkWriter,
): Promise<number> {
  return await new Promise<number>((resolve, reject) => {
    let rejected = false;
    let bytesWritten = 0;
    let drain = Promise.resolve();

    const fail = (error: unknown) => {
      if (rejected) return;
      rejected = true;
      reject(error);
    };

    const stream = zip.generateInternalStream({
      type: 'uint8array',
      streamFiles: true,
      compression: 'DEFLATE',
    });

    stream.on('data', (chunk: Uint8Array) => {
      stream.pause();
      drain = drain
        .then(async () => {
          bytesWritten += chunk.byteLength;
          await writer.write(chunk);
          if (!rejected) stream.resume();
        })
        .catch(fail);
    });

    stream.on('error', fail);
    stream.on('end', () => {
      drain
        .then(() => resolve(bytesWritten))
        .catch(fail);
    });

    stream.resume();
  });
}

/* -- File System Access API progressive enhancement export ---------------- */

export async function saveBackupFile(blob: Blob, filename: string): Promise<void> {
  if ('showSaveFilePicker' in window) {
    try {
      const handle = await (window as any).showSaveFilePicker({
        suggestedName: filename,
        types: [
          {
            description: 'Oriveo Backup',
            accept: { 'application/x-oriveo-backup': ['.oriveo'] },
          },
        ],
      });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
      return;
    } catch (err: any) {
      // The user dismissed the picker: rethrow instead of falling back.
      if (err?.name === 'AbortError') throw err;
    }
  }

  // Fallback: Blob download
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

/* -- Provider field sanitization ------------------------------------------ */

/** Strips secrets and non-portable fields from providers before export. */
export function sanitizeProviders(providers: Provider[]): Provider[] {
  return providers.filter((p) => isValidProviderKind(p.kind)).map((p) => {
    const isRelay = p.kind === 'relay';
    return {
      ...p,
      apiKey: '',
      apiKeyPreview: '',
      status: { kind: 'connected' as const },
      lastCheckedAt: undefined,
      lastError: undefined,
      baseURLText: isRelay ? stripRelayURLSecrets(p.baseURLText) : p.baseURLText,
      relayResolvedBaseURLText: isRelay
        ? stripRelayURLSecrets(p.relayResolvedBaseURLText)
        : p.relayResolvedBaseURLText,
      relayRequested: isRelay
        ? credentialFreeRelayRequested(p.relayRequested)
        : p.relayRequested,
      // Official providers do not export catalogModels (they are resolved dynamically from metadata); Relay keeps them.
      catalogModels: isRelay ? p.catalogModels : [],
    };
  });
}

/** Resets provider status to issue, the marker used after a backup restore. */
export function resetProviderStatus(provider: Provider): Provider {
  return {
    ...provider,
    status: { kind: 'issue', message: 'Restored from backup' },
    lastCheckedAt: undefined,
    lastError: undefined,
  };
}

function sanitizeSkillsForBackup(skills: Skill[]): Skill[] {
  return skills.map((skill) => ({
    ...skill,
    knowledgeBase: sanitizeKnowledgeBaseForBackup(skill.knowledgeBase),
  }));
}

function sanitizeKnowledgeBaseForBackup(skillKnowledgeBase: Skill['knowledgeBase']): Skill['knowledgeBase'] {
  if (!skillKnowledgeBase) return null;

  return {
    ...skillKnowledgeBase,
    vectorStoreId: '',
    files: skillKnowledgeBase.files.map((file) => {
      const { openAIFileId: _openAIFileId, ...manifestFile } = file;
      return {
        ...manifestFile,
        status: 'disabled',
      };
    }),
  };
}
