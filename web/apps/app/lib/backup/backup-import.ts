/**
 * Backup import flow.
 * Preview stats -> three import modes (new only / merge / replace all) -> image restore -> key restore
 */

import type { Provider, Conversation, ChatMessage, Folder, Skill, SkillUsage, Note, NoteFolder } from '@oriveo/shared';
import { isValidProviderKind, parseQuoteContext } from '@oriveo/shared';
import type { AppPreference } from '@oriveo/shared';
import type {
  BackupFile,
  ImportMode,
  ImportPreview,
  ImportResult,
} from './backup-types';
import {
  getAllConversations,
  getAllFolders,
  getAllProviders,
  putConversation,
  putFolder,
  putProvider,
  putNote,
  putNoteFolder,
  mergeAllInOneTx,
  replaceAllInOneTx,
  getAllNotes,
  getAllNoteFolders,
  setSessionValue,
} from '../infra/storage/idb';
import { saveImage, deleteImage } from '../infra/storage/image-store';
import { sha256hex, decrypt, base64ToUint8 } from './backup-crypto';
import { canonicalJSON } from './backup-format';
import { resetProviderStatus } from './backup-export';
import { getPreference, setPreference } from '../infra/storage/preferences';
import { trackEvent } from '../core/telemetry';
import { tryGetVanillaStore } from '../../providers/StoreProvider';
import { loadCachedUserSkills, saveUserSkills } from '../core/skills/cache';
import { buildOfficialEnabledModels } from '../core/providers/official-model-sync';
import { getMetadataSnapshot } from '../core/metadata/metadata-client';
import { normalizeNoteFolderIDs, normalizeNoteIDs, normalizeUUID } from '../utils/id-utils';
import type { CatalogMetadataInput } from '../core/providers/catalog-resolver';
import { getActiveUIDSync } from '../infra/storage/partition';

/** Abort as soon as the account partition changes mid-import: writes must land in the partition that started it. */
function assertExpectedImportUID(expectedUID?: string): void {
  if (expectedUID !== undefined && getActiveUIDSync() !== expectedUID) {
    throw new Error(`Backup import storage partition changed from ${expectedUID}`);
  }
}

/**
 * Rebuild non-relay providers from metadata.
 *   - catalogModels is always [] (official providers do not persist a catalog)
 *   - models are rebuilt by the metadata resolver from the prev enabled/default state in the backup
 */
function rebuildOfficialProviderFromMetadata(provider: Provider): Provider {
  if (provider.kind === 'relay') {
    return provider;
  }

  const metadata = getMetadataSnapshot() as CatalogMetadataInput | null;
  const build = buildOfficialEnabledModels(provider.kind, metadata, {
    prevEnabledIds: provider.models.map((m) => m.id),
    prevCatalogModels: provider.catalogModels,
    prevDefaultModelId: provider.models.find((m) => m.isDefault)?.id,
    updatedAt: provider.updatedAt,
    firestoreUpdatedAt: provider.firestoreUpdatedAt,
  }, {
    repairLegacyAutoEnabledAll: true,
  });

  // When metadata is unavailable (startup or offline) keep the enabled models but still clear
  // catalogModels, so an old backup cannot write the official catalog back into local storage.
  if (build.models.length === 0) {
    return { ...provider, catalogModels: [] };
  }

  return { ...provider, models: build.models, catalogModels: [] };
}

/* ── Generate import preview ──────────────────────────────── */

export async function generateImportPreview(
  backupFile: BackupFile,
  imageEntries: Map<string, Uint8Array>,
): Promise<ImportPreview> {
  const [existingConvs, existingProviders, existingNotes, existingNoteFolders] = await Promise.all([
    getAllConversations(),
    getAllProviders(),
    getAllNotes(),
    getAllNoteFolders(),
  ]);

  const existingConvIds = new Set(existingConvs.map((c) => normalizeUUID(c.id)));
  const existingProviderIds = new Set(existingProviders.map((p) => normalizeUUID(p.id)));
  const existingNoteIds = new Set(existingNotes.map((note) => normalizeUUID(note.id)));
  const existingNoteFolderIds = new Set(existingNoteFolders.map((folder) => normalizeUUID(folder.id)));

  const backupConvIds = backupFile.data.conversations.map((c) => normalizeUUID(c.id));
  const backupProviders = backupFile.data.providers;
  const backupNotes = backupFile.data.notes ?? [];
  const backupNoteFolders = backupFile.data.noteFolders ?? [];

  const existingConversationCount = backupConvIds.filter((id) => existingConvIds.has(id)).length;
  const existingProviderCount = backupProviders
    .filter((p) => existingProviderIds.has(normalizeUUID(p.id)))
    .length;
  const existingNoteCount = backupNotes
    .filter((note) => existingNoteIds.has(normalizeUUID(note.id)))
    .length;
  const existingNoteFolderCount = backupNoteFolders
    .filter((folder) => existingNoteFolderIds.has(normalizeUUID(folder.id)))
    .length;

  // checksum verification
  let checksumValid: boolean | null = null;
  if (backupFile.checksum && backupFile.checksum.startsWith('sha256:')) {
    const expectedHash = backupFile.checksum.slice(7);
    const dataJson = canonicalJSON(backupFile.data);
    const actualHash = await sha256hex(new TextEncoder().encode(dataJson));
    checksumValid = expectedHash === actualHash;
  }

  // Attachment checksum verification
  const attachmentChecksumIssues: string[] = [];
  if (backupFile.attachmentChecksums) {
    for (const [filename, expected] of Object.entries(backupFile.attachmentChecksums)) {
      const data = imageEntries.get(filename);
      if (!data) {
        attachmentChecksumIssues.push(filename);
        continue;
      }
      const expectedHash = expected.startsWith('sha256:') ? expected.slice(7) : expected;
      const actualHash = await sha256hex(data);
      if (expectedHash !== actualHash) {
        attachmentChecksumIssues.push(filename);
      }
    }
  }

  return {
    backupFile,
    totalConversations: backupConvIds.length,
    totalProviders: backupProviders.length,
    totalNotes: backupNotes.length,
    totalNoteFolders: backupNoteFolders.length,
    existingConversationCount,
    existingProviderCount,
    existingNoteCount,
    existingNoteFolderCount,
    newConversationCount: backupConvIds.length - existingConversationCount,
    newProviderCount: backupProviders.length - existingProviderCount,
    newNoteCount: backupNotes.length - existingNoteCount,
    newNoteFolderCount: backupNoteFolders.length - existingNoteFolderCount,
    hasImages: imageEntries.size > 0,
    checksumValid,
    attachmentChecksumIssues,
    imageEntries,
  };
}

/* ── Execute import ──────────────────────────────────────── */

export async function executeImport(
  preview: ImportPreview,
  mode: ImportMode,
  password?: string,
  expectedUID?: string,
): Promise<ImportResult> {
  assertExpectedImportUID(expectedUID);
  const result: ImportResult = {
    conversationsImported: 0,
    conversationsSkipped: 0,
    conversationsMerged: 0,
    providersImported: 0,
    providersSkipped: 0,
    providersMerged: 0,
    skillsImported: 0,
    skillsSkipped: 0,
    skillsMerged: 0,
    skillsRequiringKnowledgeReupload: 0,
    notesImported: 0,
    notesSkipped: 0,
    notesMerged: 0,
    noteFoldersImported: 0,
    noteFoldersSkipped: 0,
    noteFoldersMerged: 0,
    keysRestored: 0,
    imagesRestored: 0,
    restoredPreferences: false,
    restoredLastUsedModel: false,
  };

  const { backupFile, imageEntries } = preview;

  // Decrypt the API keys, if present
  let keyMap: Map<string, { apiKey: string; apiKeyPreview: string }> | null = null;
  if (backupFile.containsKeys && backupFile.encryptedKeys && password) {
    const encryptedData = base64ToUint8(backupFile.encryptedKeys);
    let decrypted: Uint8Array;
    try {
      decrypted = await decrypt(encryptedData, password);
    } catch {
      throw new Error('WRONG_PASSWORD');
    }
    assertExpectedImportUID(expectedUID);
    const keysObj = JSON.parse(new TextDecoder().decode(decrypted)) as {
      keys: { providerID: string; apiKey: string; apiKeyPreview: string }[];
    };
    keyMap = new Map(keysObj.keys.map((k) => [k.providerID, k]));
  }

  if (mode === 'replaceAll') {
    await executeReplaceAll(backupFile, imageEntries, keyMap, result, expectedUID);
  } else if (mode === 'merge') {
    await executeMerge(backupFile, imageEntries, keyMap, result);
  } else {
    await executeImportNew(backupFile, imageEntries, keyMap, result);
  }

  // Restore preferences and the last used model
  assertExpectedImportUID(expectedUID);
  const store = tryGetVanillaStore();
  if (backupFile.data.preferences) {
    const { theme, language } = backupFile.data.preferences;
    if (theme || language) {
      const currentPreferences = store?.getState().preferences ?? getPreference<AppPreference>(
        'preferences',
        {
          theme: 'dark',
          themeSetByUser: false,
          language: 'system',
          sendShortcut: 'enter',
        },
        expectedUID,
      );
      // theme in the backup is user data, so treat it as an explicit choice once restored
      const restoredPatch = theme
        ? { ...backupFile.data.preferences, themeSetByUser: true }
        : backupFile.data.preferences;
      setPreference('preferences', {
        ...currentPreferences,
        ...restoredPatch,
      }, expectedUID);
      store?.getState().setPreferences(restoredPatch);
      result.restoredPreferences = true;
    }
  }
  if (backupFile.data.lastUsedModelRef) {
    await setSessionValue('lastUsedModelRef', backupFile.data.lastUsedModelRef, expectedUID);
    assertExpectedImportUID(expectedUID);
    store?.getState().setLastUsedModelRef(backupFile.data.lastUsedModelRef);
    result.restoredLastUsedModel = true;
  }

  trackEvent('backup_imported', {
    mode,
    encrypted: Boolean(backupFile.containsKeys),
    conversations_imported: result.conversationsImported,
    conversations_merged: result.conversationsMerged,
    conversations_skipped: result.conversationsSkipped,
    providers_imported: result.providersImported,
    providers_merged: result.providersMerged,
    skills_imported: result.skillsImported,
    notes_imported: result.notesImported,
    notes_merged: result.notesMerged,
    notes_skipped: result.notesSkipped,
    note_folders_imported: result.noteFoldersImported,
    note_folders_merged: result.noteFoldersMerged,
    note_folders_skipped: result.noteFoldersSkipped,
    keys_restored: result.keysRestored,
    images_restored: result.imagesRestored,
  });

  return result;
}

/* ── Shared data loading for importNew/merge ────── */

interface ExistingData {
  conversations: Conversation[];
  folders: Folder[];
  providers: Provider[];
  notes: Note[];
  noteFolders: NoteFolder[];
  convIds: Set<string>;
  folderIds: Set<string>;
  providerIds: Set<string>;
  noteIds: Set<string>;
  noteFolderIds: Set<string>;
}

async function loadExistingData(): Promise<ExistingData> {
  const [conversations, folders, providers, notes, noteFolders] = await Promise.all([
    getAllConversations(),
    getAllFolders(),
    getAllProviders(),
    getAllNotes(),
    getAllNoteFolders(),
  ]);

  return {
    conversations,
    folders,
    providers,
    notes,
    noteFolders,
    // Compare through normalizeUUID (matching providerIds / noteIds below): the backup keeps the
    // casing from export time while the local copy may already be normalized to upper case by
    // cloud sync, so a raw string comparison would treat one entity as two and duplicate
    // conversations and folders on import.
    convIds: new Set(conversations.map((c) => normalizeUUID(c.id))),
    folderIds: new Set(folders.map((folder) => normalizeUUID(folder.id))),
    providerIds: new Set(providers.map((p) => normalizeUUID(p.id))),
    noteIds: new Set(notes.map((note) => normalizeUUID(note.id))),
    noteFolderIds: new Set(noteFolders.map((folder) => normalizeUUID(folder.id))),
  };
}

function parseEntityUpdatedAt(value: string | undefined): number {
  if (!value) return 0;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : 0;
}

function buildActiveNoteFolderIDSet(folders: NoteFolder[]): Set<string> {
  return new Set(
    folders
      .filter((folder) => !folder.deletedAt)
      .map((folder) => normalizeUUID(folder.id)),
  );
}

function normalizeImportedNoteFolder(folder: NoteFolder): NoteFolder {
  return normalizeNoteFolderIDs(folder);
}

function buildImportNewNoteFolders(
  existingFolders: NoteFolder[],
  backupFolders: NoteFolder[],
): NoteFolder[] {
  const byId = new Map<string, NoteFolder>();
  for (const folder of existingFolders) {
    const normalized = normalizeImportedNoteFolder(folder);
    if (!normalized.deletedAt) {
      byId.set(normalizeUUID(normalized.id), normalized);
    }
  }
  for (const folder of backupFolders) {
    const normalized = normalizeImportedNoteFolder(folder);
    const id = normalizeUUID(normalized.id);
    if (normalized.deletedAt || byId.has(id)) continue;
    byId.set(id, normalized);
  }
  return Array.from(byId.values());
}

function buildMergedNoteFolders(
  existingFolders: NoteFolder[],
  backupFolders: NoteFolder[],
): Map<string, NoteFolder> {
  const byId = new Map<string, NoteFolder>();
  for (const folder of existingFolders) {
    const normalized = normalizeImportedNoteFolder(folder);
    byId.set(normalizeUUID(normalized.id), normalized);
  }
  for (const folder of backupFolders) {
    const normalized = normalizeImportedNoteFolder(folder);
    const id = normalizeUUID(normalized.id);
    const local = byId.get(id);
    if (!local) {
      if (!normalized.deletedAt) {
        byId.set(id, normalized);
      }
      continue;
    }

    if (parseEntityUpdatedAt(normalized.updatedAt) > parseEntityUpdatedAt(local.updatedAt)) {
      byId.set(id, normalized);
    }
  }
  return byId;
}

function normalizeImportedNote(note: Note, activeFolderIds: Set<string>): Note {
  const normalized = normalizeNoteIDs({
    ...note,
    tags: note.tags ?? [],
  });
  if (normalized.noteFolderID && !activeFolderIds.has(normalizeUUID(normalized.noteFolderID))) {
    const { noteFolderID: _noteFolderID, ...rest } = normalized;
    return rest;
  }
  return normalized;
}

/* ── Mode A: import new only ──────────────────────────────── */

async function executeImportNew(
  backupFile: BackupFile,
  imageEntries: Map<string, Uint8Array>,
  keyMap: Map<string, { apiKey: string; apiKeyPreview: string }> | null,
  result: ImportResult,
) {
  const existing = await loadExistingData();
  const backupNoteFolders = (backupFile.data.noteFolders ?? []).map(normalizeImportedNoteFolder);
  const activeNoteFolderIds = buildActiveNoteFolderIDSet(
    buildImportNewNoteFolders(existing.noteFolders, backupNoteFolders),
  );

  for (const folder of backupFile.data.folders ?? []) {
    if (existing.folderIds.has(normalizeUUID(folder.id))) continue;
    await putFolder(folder);
  }

  for (const folder of backupNoteFolders) {
    if (folder.deletedAt || existing.noteFolderIds.has(normalizeUUID(folder.id))) {
      result.noteFoldersSkipped++;
      continue;
    }
    await putNoteFolder(folder);
    result.noteFoldersImported++;
  }

  for (const note of backupFile.data.notes ?? []) {
    const normalized = normalizeImportedNote(note, activeNoteFolderIds);
    if (existing.noteIds.has(normalizeUUID(normalized.id))) {
      result.notesSkipped++;
      continue;
    }
    await putNote(normalized);
    result.notesImported++;
  }

  // Import conversations
  for (const conv of backupFile.data.conversations) {
    if (existing.convIds.has(normalizeUUID(conv.id))) {
      result.conversationsSkipped++;
      continue;
    }
    await putConversation(conv);
    await restoreConversationImages(conv, imageEntries, result);
    result.conversationsImported++;
  }

  // Providers: skip anything with an unknown kind or an id already present locally.
  for (const prov of backupFile.data.providers) {
    if (!isValidProviderKind(prov.kind)) {
      result.providersSkipped++;
      continue;
    }
    if (existing.providerIds.has(normalizeUUID(prov.id))) {
      result.providersSkipped++;
      continue;
    }

    const restored = await applyRestoredKeys(prov, keyMap, result);
    const normalized = rebuildOfficialProviderFromMetadata(restored);
    await putProvider(resetProviderStatus(normalized));
    result.providersImported++;
  }

  await importNewSkills(backupFile.data.skills ?? [], result);
}

/* ── Mode B: merge ────────────────────────────────────── */

async function executeMerge(
  backupFile: BackupFile,
  imageEntries: Map<string, Uint8Array>,
  keyMap: Map<string, { apiKey: string; apiKeyPreview: string }> | null,
  result: ImportResult,
) {
  const existing = await loadExistingData();
  const existingConvMap = new Map(existing.conversations.map((c) => [normalizeUUID(c.id), c]));
  const existingFolderMap = new Map(existing.folders.map((folder) => [normalizeUUID(folder.id), folder]));
  const existingProviderMap = new Map(existing.providers.map((p) => [normalizeUUID(p.id), p]));
  const backupNoteFolders = (backupFile.data.noteFolders ?? []).map(normalizeImportedNoteFolder);
  const resolvedNoteFolderMap = buildMergedNoteFolders(existing.noteFolders, backupNoteFolders);
  const activeNoteFolderIds = buildActiveNoteFolderIDSet([...resolvedNoteFolderMap.values()]);

  // ── Precompute the pending snapshot per store (pure transforms, no IDB / image-store side effects) ──
  const foldersToPut: Folder[] = [];
  for (const backupFolder of backupFile.data.folders ?? []) {
    const local = existingFolderMap.get(normalizeUUID(backupFolder.id));
    if (!local) {
      foldersToPut.push(backupFolder);
      continue;
    }
    if (Date.parse(backupFolder.updatedAt) > Date.parse(local.updatedAt)) {
      // Keep the local id: writing the backup's casing variant back would land as a second folder
      // under a different IDB key (conversations and providers merge through `...local` and so
      // already carry the local id, notes go through normalizeImported*, only this path is a bare
      // push).
      foldersToPut.push({ ...backupFolder, id: local.id });
    }
  }

  for (const backupFolder of backupNoteFolders) {
    const local = existing.noteFolders.find((folder) => normalizeUUID(folder.id) === normalizeUUID(backupFolder.id));
    if (!local) {
      // Not present locally: a live folder is written and counted as imported, a tombstone is dropped and counted as skipped
      if (backupFolder.deletedAt) {
        result.noteFoldersSkipped++;
      } else {
        result.noteFoldersImported++;
      }
      continue;
    }

    // LWW: the counters follow buildMergedNoteFolders, so only a newer backup wins and counts as merged, otherwise the local copy stays and counts as skipped
    if (parseEntityUpdatedAt(backupFolder.updatedAt) > parseEntityUpdatedAt(local.updatedAt)) {
      result.noteFoldersMerged++;
    } else {
      result.noteFoldersSkipped++;
    }
  }

  // Merge keeps tombstone folders (deletedAt) so deletions propagate; notes referencing them are unlinked by normalizeImportedNote below.
  const noteFoldersToPut = [...resolvedNoteFolderMap.values()];

  const resolvedNotes = new Map<string, Note>();
  for (const note of existing.notes) {
    const normalized = normalizeNoteIDs({
      ...note,
      tags: note.tags ?? [],
    });
    resolvedNotes.set(normalizeUUID(normalized.id), normalized);
  }
  for (const backupNote of backupFile.data.notes ?? []) {
    const normalized = normalizeImportedNote(backupNote, activeNoteFolderIds);
    const local = resolvedNotes.get(normalizeUUID(normalized.id));
    if (!local) {
      resolvedNotes.set(normalizeUUID(normalized.id), normalized);
      result.notesImported++;
      continue;
    }

    // LWW: only a newer backup wins and counts as merged, otherwise the local copy stays and counts as skipped
    if (parseEntityUpdatedAt(normalized.updatedAt) > parseEntityUpdatedAt(local.updatedAt)) {
      resolvedNotes.set(normalizeUUID(normalized.id), normalized);
      result.notesMerged++;
    } else {
      result.notesSkipped++;
    }
  }
  const notesToPut = [...resolvedNotes.values()].map((note) => normalizeImportedNote(note, activeNoteFolderIds));

  // Merge conversations; image restore (image-store is a separate DB) is compensated after the main transaction.
  const conversationsToPut: Conversation[] = [];
  const convsForImageRestore: Conversation[] = [];
  for (const backupConv of backupFile.data.conversations) {
    const local = existingConvMap.get(normalizeUUID(backupConv.id));
    if (!local) {
      // New conversation, add it directly
      conversationsToPut.push(backupConv);
      convsForImageRestore.push(backupConv);
      result.conversationsImported++;
      continue;
    }

    // Existing conversation, merge the messages
    const mergedMessages = mergeMessages(local.messages, backupConv.messages);
    const newerUpdatedAt =
      local.updatedAt > backupConv.updatedAt ? local.updatedAt : backupConv.updatedAt;

    const merged: Conversation = {
      ...local,
      messages: mergedMessages,
      updatedAt: newerUpdatedAt,
      // Metadata comes from whichever side has the later updatedAt
      title: local.updatedAt >= backupConv.updatedAt ? local.title : backupConv.title,
      previewText:
        local.updatedAt >= backupConv.updatedAt ? local.previewText : backupConv.previewText,
    };

    conversationsToPut.push(merged);
    convsForImageRestore.push(backupConv);
    result.conversationsMerged++;
  }

  // Merge providers
  const providersToPut: Provider[] = [];
  for (const backupProv of backupFile.data.providers) {
    if (!isValidProviderKind(backupProv.kind)) {
      result.providersSkipped++;
      continue;
    }
    const local = existingProviderMap.get(normalizeUUID(backupProv.id));

    if (!local) {
      const restored = await applyRestoredKeys(backupProv, keyMap, result);
      const normalized = rebuildOfficialProviderFromMetadata(restored);
      providersToPut.push(resetProviderStatus(normalized));
      result.providersImported++;
      continue;
    }

    // Merge models by UUID; official providers do not merge catalogModels
    const mergedModels = mergeArrayByKey(local.models, backupProv.models, 'id');
    const mergedCatalog = local.kind === 'relay'
      ? mergeArrayByKey(local.catalogModels, backupProv.catalogModels, 'id')
      : [];

    const merged: Provider = {
      ...local,
      customName: backupProv.customName ?? local.customName,
      baseURLText: local.kind === 'relay' ? backupProv.baseURLText ?? local.baseURLText : local.baseURLText,
      models: mergedModels,
      catalogModels: mergedCatalog,
      // API keys never overwrite the local ones
    };

    // Restore the key when the local provider has none and the backup does
    if (!local.apiKey && keyMap?.has(backupProv.id)) {
      const keys = keyMap.get(backupProv.id)!;
      merged.apiKey = keys.apiKey;
      merged.apiKeyPreview = keys.apiKeyPreview;
      result.keysRestored++;
    }

    // Run official providers through the metadata resolver after the merge so the catalog stays authoritative
    providersToPut.push(rebuildOfficialProviderFromMetadata(merged));
    result.providersMerged++;
  }

  // ── Single main transaction: the five put groups are atomic and roll back together on failure ──
  await mergeAllInOneTx({
    conversations: conversationsToPut,
    providers: providersToPut,
    folders: foldersToPut,
    notes: notesToPut,
    noteFolders: noteFoldersToPut,
  });

  // Image restore is compensated separately: image-store is a separate DB and cannot join the main transaction, so atomicity is asymmetric
  for (const conv of convsForImageRestore) {
    await restoreConversationImages(conv, imageEntries, result);
  }

  await mergeSkills(backupFile.data.skills ?? [], result);
}

/* ── Mode C: replace all ────────────────────────────────── */

async function executeReplaceAll(
  backupFile: BackupFile,
  imageEntries: Map<string, Uint8Array>,
  keyMap: Map<string, { apiKey: string; apiKeyPreview: string }> | null,
  result: ImportResult,
  expectedUID?: string,
) {
  // Read the old conversations up front so orphan images can be cleaned up once the transaction commits (image-store is a separate DB and stays outside it)
  const existingConvs = await getAllConversations(expectedUID);
  assertExpectedImportUID(expectedUID);

  // ── Precompute the final in-memory snapshot (pure transforms: normalization, unlinking dangling refs, key restore, official catalog rebuild) ──
  const folders = backupFile.data.folders ?? [];
  const noteFolders = (backupFile.data.noteFolders ?? []).map(normalizeImportedNoteFolder);
  const activeNoteFolders = noteFolders.filter((folder) => !folder.deletedAt);
  const activeNoteFolderIds = buildActiveNoteFolderIDSet(activeNoteFolders);
  const notes = (backupFile.data.notes ?? []).map((note) => normalizeImportedNote(note, activeNoteFolderIds));
  const conversations = backupFile.data.conversations;
  const importableProviders = backupFile.data.providers.filter((prov) => isValidProviderKind(prov.kind));
  result.providersSkipped += backupFile.data.providers.length - importableProviders.length;
  const providers = await Promise.all(importableProviders.map(async (prov) => {
    const restored = await applyRestoredKeys(prov, keyMap, result);
    return resetProviderStatus(rebuildOfficialProviderFromMetadata(restored));
  }));
  assertExpectedImportUID(expectedUID);

  // ── Single main transaction: clear the five stores and write the full snapshot, rolling back as a whole on failure ──
  // Skip tombstones: only active note folders are written, and notes referencing one were already unlinked
  await replaceAllInOneTx(
    { conversations, providers, folders, notes, noteFolders: activeNoteFolders },
    expectedUID,
  );
  assertExpectedImportUID(expectedUID);

  result.noteFoldersImported += activeNoteFolders.length;
  result.notesImported += notes.length;
  result.conversationsImported += conversations.length;
  result.providersImported += providers.length;

  // ── Image compensation (image-store is a separate DB, so atomicity is asymmetric): delete the old orphans first, then restore the new images ──
  for (const conv of existingConvs) {
    for (const msg of conv.messages) {
      if (!msg.attachments) continue;
      for (const att of msg.attachments) {
        if (att.kind === 'image' && att.localImageID) {
          await deleteImage(att.localImageID, expectedUID);
          assertExpectedImportUID(expectedUID);
        }
      }
    }
  }
  for (const conv of conversations) {
    await restoreConversationImages(conv, imageEntries, result, expectedUID);
    assertExpectedImportUID(expectedUID);
  }

  await replaceAllSkills(backupFile.data.skills ?? [], result, expectedUID);
  assertExpectedImportUID(expectedUID);
}

/* ── Message merge algorithm ─────────────────────────── */

export function mergeMessages(local: ChatMessage[], backup: ChatMessage[]): ChatMessage[] {
  const seenIDs = new Set<string>();
  const mergedIndexes = new Map<string, number>();
  const merged: ChatMessage[] = [];

  // Merge both sources and sort by createdAt; ties break on UUID lexicographic order
  const all = [...local, ...backup].sort((a, b) => {
    const timeA = normalizeCreatedAt(a, local, backup);
    const timeB = normalizeCreatedAt(b, local, backup);
    if (timeA !== timeB) return timeA < timeB ? -1 : 1;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });

  // Dedupe through normalizeUUID: local message ids may already be normalized to upper case by
  // cloud sync while the backup keeps the casing from import time. Deduping on the raw string
  // would keep both copies, normalizeConversationIDs would then give them literally identical ids,
  // and MessageList's key={msg.id} would collide (same contract as upsertMessages /
  // sameNormalizedID).
  for (const msg of all) {
    const key = normalizeUUID(msg.id);
    if (!seenIDs.has(key)) {
      seenIDs.add(key);
      mergedIndexes.set(key, merged.length);
      merged.push(msg);
    } else {
      const existingIndex = mergedIndexes.get(key);
      if (existingIndex !== undefined) {
        const existing = merged[existingIndex];
        const quoteContext = parseQuoteContext(existing.quoteContext) ?? parseQuoteContext(msg.quoteContext);
        // The merge contract still lets the message that sorts first win; the other side only fills in a missing quote.
        if (!existing.quoteContext && quoteContext) {
          merged[existingIndex] = { ...existing, quoteContext };
        }
      }
    }
  }

  return merged;
}

/**
 * createdAt fallback for older backup versions: when createdAt is missing, assign an increasing
 * timestamp derived from the original array position.
 */
function normalizeCreatedAt(
  msg: ChatMessage,
  local: ChatMessage[],
  backup: ChatMessage[],
): string {
  if (msg.createdAt) return msg.createdAt;

  // Find the message's position in its original array to build an increasing epoch-based timestamp
  let idx = local.indexOf(msg);
  if (idx === -1) idx = backup.indexOf(msg);
  if (idx === -1) idx = 0;

  // A far enough past base time plus the index in milliseconds keeps the order increasing without overlapping real timestamps
  return new Date(946684800000 + idx * 1000).toISOString(); // 2000-01-01 + idx*1s
}

/* ── Helpers ──────────────────────────────────────────── */

/**
 * Image extension candidates: the one derived from mimeType first, then jpg as a fallback.
 *
 * iOS exports name the entry after the mimeType (png/gif/webp/heic) while Android and web always
 * write .jpg. Checking only .jpg would silently lose PNG images from an iOS archive.
 */
function imageExtensionCandidates(mimeType?: string): string[] {
  const subtype = (mimeType ?? '').split('/')[1]?.toLowerCase() ?? '';
  const mimeExtension =
    subtype === 'png' ? 'png'
    : subtype === 'gif' ? 'gif'
    : subtype === 'webp' ? 'webp'
    : subtype === 'heic' || subtype === 'heif' ? 'heic'
    : 'jpg';
  return mimeExtension === 'jpg' ? ['jpg'] : [mimeExtension, 'jpg'];
}

/**
 * Archive entry names under attachments/<name>.<ext> differ across clients on two axes, so the
 * import has to accept all of them.
 *
 * - Name: iOS and Android use attachment.id, web has historically used localImageID.
 * - Extension: see imageExtensionCandidates.
 *
 * Accepting only one convention means the entry is not found when restoring an archive written by
 * another client, and no restore path has a base64 fallback, so the image is lost silently. Hence
 * the fixed name-candidate x extension-candidate fallback order, which restores both old and new
 * archives from any client.
 */
function findAttachmentEntry(
  imageEntries: Map<string, Uint8Array>,
  candidateNames: (string | undefined)[],
  extensions: string[],
  suffix: string,
): Uint8Array | undefined {
  for (const name of candidateNames) {
    if (!name) continue;
    for (const ext of extensions) {
      const data = imageEntries.get(`${name}${suffix}.${ext}`);
      if (data) return data;
    }
  }
  return undefined;
}

/** Restore a conversation's images from the ZIP into the ImageStore */
async function restoreConversationImages(
  conv: Conversation,
  imageEntries: Map<string, Uint8Array>,
  result: ImportResult,
  expectedUID?: string,
) {
  for (const msg of conv.messages) {
    if (!msg.attachments) continue;
    for (const att of msg.attachments) {
      if (att.kind !== 'image' || !att.localImageID) continue;

      const candidateNames = [att.id, att.localImageID];
      const extensions = imageExtensionCandidates(att.mimeType);
      const imageData = findAttachmentEntry(imageEntries, candidateNames, extensions, '');
      const thumbData = findAttachmentEntry(imageEntries, candidateNames, extensions, '.thumb');

      if (imageData && thumbData) {
        await saveImage(
          att.localImageID,
          new Blob([imageData.buffer as ArrayBuffer], { type: 'image/jpeg' }),
          new Blob([thumbData.buffer as ArrayBuffer], { type: 'image/jpeg' }),
          'image/jpeg',
          expectedUID,
        );
        assertExpectedImportUID(expectedUID);
        result.imagesRestored++;
      } else if (imageData) {
        // No thumbnail, fall back to the full image
        const blob = new Blob([imageData.buffer as ArrayBuffer], { type: 'image/jpeg' });
        await saveImage(att.localImageID, blob, blob, 'image/jpeg', expectedUID);
        assertExpectedImportUID(expectedUID);
        result.imagesRestored++;
      }
    }
  }
}

/** Restore API keys onto providers */
async function applyRestoredKeys(
  provider: Provider,
  keyMap: Map<string, { apiKey: string; apiKeyPreview: string }> | null,
  result: ImportResult,
): Promise<Provider> {
  if (!keyMap) return provider;
  const keys = keyMap.get(provider.id);
  if (!keys) return provider;
  result.keysRestored++;
  return { ...provider, apiKey: keys.apiKey, apiKeyPreview: keys.apiKeyPreview };
}

/** Merge arrays, deduping by key */
function mergeArrayByKey<T extends Record<string, any>>(
  a: T[],
  b: T[],
  key: keyof T,
): T[] {
  const map = new Map<any, T>();
  for (const item of a) map.set(item[key], item);
  for (const item of b) {
    if (!map.has(item[key])) map.set(item[key], item);
  }
  return Array.from(map.values());
}

function restoreSkillFromBackup(skill: Skill): {
  skill: Skill;
  requiresKnowledgeReupload: boolean;
} {
  return {
    skill: {
      ...skill,
      knowledgeBase: null,
    },
    requiresKnowledgeReupload: Boolean(skill.knowledgeBase?.files.length),
  };
}

function parseUpdatedAt(value: string | undefined): number {
  if (!value) return 0;
  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function buildSkillUsageSnapshot(
  current: SkillUsage | null | undefined,
  skillsCount: number,
): SkillUsage {
  return {
    count: skillsCount,
    limit: current?.limit ?? null,
  };
}

async function persistUserSkills(skills: Skill[], expectedUID?: string): Promise<void> {
  await saveUserSkills(skills, expectedUID);
  assertExpectedImportUID(expectedUID);

  const store = tryGetVanillaStore();
  if (!store) return;

  const usage = buildSkillUsageSnapshot(store.getState().skillUsage, skills.length);
  store.getState().setUserSkills(skills, usage);
}

async function importNewSkills(backupSkills: Skill[], result: ImportResult): Promise<void> {
  if (backupSkills.length === 0) return;

  const existingSkills = await loadCachedUserSkills();
  const existingIDs = new Set(existingSkills.map((skill) => skill.id));
  const nextSkills = [...existingSkills];

  for (const backupSkill of backupSkills) {
    if (existingIDs.has(backupSkill.id)) {
      result.skillsSkipped++;
      continue;
    }

    const restored = restoreSkillFromBackup(backupSkill);
    nextSkills.push(restored.skill);
    existingIDs.add(backupSkill.id);
    result.skillsImported++;
    if (restored.requiresKnowledgeReupload) {
      result.skillsRequiringKnowledgeReupload++;
    }
  }

  if (nextSkills.length !== existingSkills.length) {
    await persistUserSkills(nextSkills);
  }
}

async function mergeSkills(backupSkills: Skill[], result: ImportResult): Promise<void> {
  if (backupSkills.length === 0) return;

  const existingSkills = await loadCachedUserSkills();
  const nextSkills = [...existingSkills];
  const existingIndexByID = new Map(existingSkills.map((skill, index) => [skill.id, index]));
  let changed = false;

  for (const backupSkill of backupSkills) {
    const existingIndex = existingIndexByID.get(backupSkill.id);
    const restored = restoreSkillFromBackup(backupSkill);

    if (existingIndex === undefined) {
      nextSkills.push(restored.skill);
      existingIndexByID.set(backupSkill.id, nextSkills.length - 1);
      result.skillsImported++;
      if (restored.requiresKnowledgeReupload) {
        result.skillsRequiringKnowledgeReupload++;
      }
      changed = true;
      continue;
    }

    result.skillsMerged++;
    if (parseUpdatedAt(backupSkill.updatedAt) >= parseUpdatedAt(nextSkills[existingIndex]?.updatedAt)) {
      nextSkills[existingIndex] = {
        ...nextSkills[existingIndex],
        ...restored.skill,
        knowledgeBase: null,
      };
      if (restored.requiresKnowledgeReupload) {
        result.skillsRequiringKnowledgeReupload++;
      }
      changed = true;
    }
  }

  if (changed) {
    await persistUserSkills(nextSkills);
  }
}

async function replaceAllSkills(
  backupSkills: Skill[],
  result: ImportResult,
  expectedUID?: string,
): Promise<void> {
  const restoredSkills = backupSkills.map(restoreSkillFromBackup);

  result.skillsImported += restoredSkills.length;
  result.skillsRequiringKnowledgeReupload += restoredSkills.reduce(
    (count, restored) => count + (restored.requiresKnowledgeReupload ? 1 : 0),
    0,
  );

  await persistUserSkills(restoredSkills.map((restored) => restored.skill), expectedUID);
}
