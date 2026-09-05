import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import JSZip from 'jszip';
import type { Conversation, Provider, ChatMessage, Folder, Skill, Note, NoteFolder } from '@oriveo/shared';
import type { BackupData, BackupFile, ImportMode } from '..';
import {
  resetDBConnection,
  putConversation,
  putFolder,
  putProvider,
  putNote,
  putNoteFolder,
  getAllConversations,
  getAllFolders,
  getAllProviders,
  getAllNotes,
  getAllNoteFolders,
} from '../../infra/storage/idb';
import { loadCachedUserSkills, saveUserSkills } from '../../core/skills/cache';
import { setActiveUID } from '../../infra/storage/partition';
import { resetImageDBConnection } from '../../infra/storage/image-store';

/* ── jsdom polyfills ───────────────────────────────────── */

// jsdom's Blob/File may not implement arrayBuffer()
if (typeof Blob.prototype.arrayBuffer !== 'function') {
  Blob.prototype.arrayBuffer = function () {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as ArrayBuffer);
      reader.onerror = reject;
      reader.readAsArrayBuffer(this);
    });
  };
}

/* -- crypto.subtle polyfill (jsdom has no complete implementation) ----- */

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  // Node 20+ has crypto.subtle, but jsdom may not expose it
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', {
    value: nodeCrypto.webcrypto,
    writable: true,
    configurable: true,
  });
}

/* -- Deferred import, so the crypto mock is in place first ------------- */

const {
  exportBackup,
  parseBackupFile,
  generateImportPreview,
  executeImport,
} = await import('..');

/* -- Test helpers ------------------------------------------------------ */

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: `conv-${Math.random().toString(36).slice(2, 8)}`,
    title: 'Test Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeProvider(overrides: Partial<Provider> = {}): Provider {
  return {
    id: `prov-${Math.random().toString(36).slice(2, 8)}`,
    kind: 'openAI',
    status: { kind: 'connected' },
    models: [],
    catalogModels: [],
    apiKey: 'sk-test-key',
    apiKeyPreview: 'sk-...key',
    ...overrides,
  };
}

function makeFolder(overrides: Partial<Folder> = {}): Folder {
  return {
    id: `folder-${Math.random().toString(36).slice(2, 8)}`,
    name: 'Work',
    sortOrder: 1000,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeNote(overrides: Partial<Note> = {}): Note {
  return {
    id: `note-${Math.random().toString(36).slice(2, 8)}`,
    title: 'Saved answer',
    titleSource: 'placeholder',
    body: 'Useful saved answer body',
    tags: [],
    captureKind: 'blank',
    createdAt: '2026-06-19T09:00:00.000Z',
    updatedAt: '2026-06-19T10:00:00.000Z',
    ...overrides,
  };
}

function makeNoteFolder(overrides: Partial<NoteFolder> = {}): NoteFolder {
  return {
    id: `note-folder-${Math.random().toString(36).slice(2, 8)}`,
    name: 'Research',
    sortOrder: 1000,
    createdAt: '2026-06-19T09:00:00.000Z',
    updatedAt: '2026-06-19T10:00:00.000Z',
    ...overrides,
  };
}

function withNotesData(data: BackupData, notes: Note[], noteFolders: NoteFolder[]): BackupData {
  return {
    ...data,
    notes,
    noteFolders,
  } as BackupData;
}

function makeMessage(overrides: Partial<ChatMessage> = {}): ChatMessage {
  return {
    id: `msg-${Math.random().toString(36).slice(2, 8)}`,
    role: 'user',
    text: 'Hello',
    providerKind: 'openAI',
    providerName: 'OpenAI',
    modelName: 'gpt-4o',
    estimatedCost: 0,
    state: 'delivered',
    createdAt: new Date().toISOString(),
    ...overrides,
  };
}

function makeSkill(overrides: Partial<Skill> = {}): Skill {
  return {
    id: overrides.id ?? `skill-${Math.random().toString(36).slice(2, 8)}`,
    name: overrides.name ?? 'Backup Skill',
    description: overrides.description ?? 'Restored skill',
    icon: overrides.icon ?? '✨',
    color: overrides.color ?? '#8B5CF6',
    systemPrompt: overrides.systemPrompt ?? 'Use the attached knowledge.',
    modelCapabilityHint: overrides.modelCapabilityHint ?? 'any',
    starterMessages: overrides.starterMessages ?? [],
    knowledgeFiles: overrides.knowledgeFiles ?? [],
    knowledgeBase: overrides.knowledgeBase ?? null,
    useMemory: overrides.useMemory ?? true,
    isPinned: overrides.isPinned ?? false,
    pinOrder: overrides.pinOrder ?? 0,
    source: overrides.source ?? 'user',
    sortOrder: overrides.sortOrder ?? 0,
    usageCount: overrides.usageCount ?? 0,
    createdAt: overrides.createdAt ?? new Date().toISOString(),
    updatedAt: overrides.updatedAt ?? new Date().toISOString(),
  };
}

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

async function resetDB() {
  resetDBConnection();
  resetImageDBConnection();
  await clearAllDatabases();
  await setActiveUID('guest');
}

/* -- Extract data.json out of a ZIP Blob ------------------------------- */

async function extractDataJson(blob: Blob): Promise<BackupFile> {
  const zip = await JSZip.loadAsync(await blob.arrayBuffer());
  const dataJsonFile = zip.file('data.json');
  if (!dataJsonFile) throw new Error('data.json not found in ZIP');
  const jsonStr = await dataJsonFile.async('string');
  return JSON.parse(jsonStr);
}

/* ========================================================
   Tests
   ======================================================== */

describe('backup-service', () => {
  beforeEach(async () => {
    await resetDB();
  });

  /* -- Export ---------------------------------------------------- */

  describe('exportBackup', () => {
    it('exports a ZIP file containing data.json', async () => {
      await putConversation(makeConversation({ id: 'c1', title: 'Test' }));
      await putProvider(makeProvider({ id: 'p1', kind: 'openAI' }));

      const blob = await exportBackup({ includeApiKeys: false });

      expect(blob).toBeInstanceOf(Blob);

      const data = await extractDataJson(blob);
      expect(data.version).toBe(1);
      expect(data.platform).toBe('Web');
      expect(data.data.conversations).toHaveLength(1);
      expect(data.data.providers).toHaveLength(1);
    });

    it('scrubs sensitive fields from exported providers', async () => {
      await putProvider(makeProvider({
        id: 'p1',
        apiKey: 'sk-secret',
        apiKeyPreview: 'sk-...ret',
      }));

      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);

      expect(data.data.providers[0].apiKey).toBe('');
      expect(data.data.providers[0].apiKeyPreview).toBe('');
    });

    it('computes a checksum on export', async () => {
      await putConversation(makeConversation({ id: 'c1' }));

      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);

      expect(data.checksum).toMatch(/^sha256:[a-f0-9]{64}$/);
    });

    it('sets containsKeys to false when no keys are included', async () => {
      await putProvider(makeProvider({ id: 'p1' }));

      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);

      expect(data.containsKeys).toBe(false);
      expect(data.encryptedKeys).toBeNull();
    });

    it('encrypts and sets containsKeys when API keys are included', async () => {
      await putProvider(makeProvider({ id: 'p1', apiKey: 'sk-test' }));

      const blob = await exportBackup({
        includeApiKeys: true,
        password: 'testpassword123',
      });
      const data = await extractDataJson(blob);

      expect(data.containsKeys).toBe(true);
      expect(data.encryptedKeys).toBeTruthy();
      expect(typeof data.encryptedKeys).toBe('string');
    });

    it('exports a valid ZIP even with no data', async () => {
      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);

      expect(data.data.conversations).toHaveLength(0);
      expect(data.data.providers).toHaveLength(0);
    });

    it('exports the folders array and preserves conversation.folderID', async () => {
      const folder = makeFolder({ id: 'folder-export-1', name: 'Projects' });
      await putFolder(folder);
      await putConversation(makeConversation({
        id: 'conv-in-folder',
        title: 'Nested Chat',
        folderID: folder.id,
      }));

      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);

      expect(data.data.folders).toEqual([folder]);
      expect(data.data.conversations[0].folderID).toBe(folder.id);
    });

    it('exports active and trash notes plus noteFolders, so a full backup does not silently lose notes', async () => {
      const folder = makeNoteFolder({ id: 'note-folder-export-1' });
      const active = makeNote({ id: 'note-export-active', noteFolderID: folder.id });
      const trashed = makeNote({
        id: 'note-export-trash',
        noteFolderID: folder.id,
        deletedAt: '2026-06-19T12:00:00.000Z',
      });
      await putNoteFolder(folder);
      await putNote(active);
      await putNote(trashed);

      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);
      const backupData = data.data as BackupData & { notes?: Note[]; noteFolders?: NoteFolder[] };

      expect(backupData.noteFolders).toEqual([folder]);
      expect(backupData.notes?.map((note) => note.id).sort()).toEqual([
        active.id,
        trashed.id,
      ].sort());
      expect(backupData.notes?.find((note) => note.id === trashed.id)?.deletedAt).toBe(trashed.deletedAt);
    });

    it('exports user skills and scrubs knowledgeBase down to a manifest', async () => {
      const skill = makeSkill({
        id: 'skill-export-1',
        knowledgeBase: {
          provider: 'openai',
          retrievalModel: 'gpt-5.4-mini',
          vectorStoreId: 'vs_live_123',
          expiresAfterDays: 90,
          files: [
            {
              id: 'kb-1',
              name: 'guide.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 2048,
              ingestionMode: 'native_file',
              openAIFileId: 'file-live-1',
              status: 'ready',
              createdAt: '2026-04-12T00:00:00.000Z',
              updatedAt: '2026-04-12T00:00:00.000Z',
            },
          ],
          updatedAt: '2026-04-12T00:00:00.000Z',
        },
      });
      await saveUserSkills([skill]);

      const blob = await exportBackup({ includeApiKeys: false });
      const data = await extractDataJson(blob);

      expect(data.data.skills).toHaveLength(1);
      expect(data.data.skills?.[0]?.knowledgeBase?.vectorStoreId).toBe('');
      expect(data.data.skills?.[0]?.knowledgeBase?.files[0]?.openAIFileId).toBeUndefined();
      expect(data.data.skills?.[0]?.knowledgeBase?.files[0]?.status).toBe('disabled');
    });
  });

  /* -- Parsing --------------------------------------------------- */

  describe('parseBackupFile', () => {
    it('parses an exported ZIP file', async () => {
      await putConversation(makeConversation({ id: 'c1', title: 'Hello' }));

      const blob = await exportBackup({ includeApiKeys: false });
      const file = new File([blob], 'backup.oriveo');

      const { backupFile, imageEntries } = await parseBackupFile(file);

      expect(backupFile.version).toBe(1);
      expect(backupFile.data.conversations).toHaveLength(1);
      expect(backupFile.data.conversations[0].title).toBe('Hello');
      expect(imageEntries.size).toBe(0);
    });

    it('parses the plain JSON format', async () => {
      const json: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'iOS',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [makeConversation({ id: 'ios-conv' })],
        },
        encryptedKeys: null,
      };
      const blob = new Blob([JSON.stringify(json)], { type: 'application/json' });
      const file = new File([blob], 'backup.json');

      const { backupFile } = await parseBackupFile(file);

      expect(backupFile.platform).toBe('iOS');
      expect(backupFile.data.conversations).toHaveLength(1);
    });

    it('throws VERSION_TOO_NEW for a newer backup version', async () => {
      const json = { version: 999, data: { providers: [], conversations: [] } };
      const blob = new Blob([JSON.stringify(json)]);
      const file = new File([blob], 'future.oriveo');

      await expect(parseBackupFile(file)).rejects.toThrow('VERSION_TOO_NEW');
    });

    it('throws on an invalid format', async () => {
      const blob = new Blob(['not a backup file']);
      const file = new File([blob], 'invalid.oriveo');

      // Neither ZIP nor JSON and no password given, so it is treated as a legacy encrypted blob and raises PASSWORD_REQUIRED
      await expect(parseBackupFile(file)).rejects.toThrow('PASSWORD_REQUIRED');
    });

    it('throws PASSWORD_REQUIRED for a legacy encrypted file with no password', async () => {
      // A legacy encrypted binary prefix can contain control bytes; a later stray '{' must not make it look like JSON.
      const legacyEncryptedData = Uint8Array.from([
        0x04,
        0x10,
        0x1f,
        0x09,
        0x0a,
        0x0d,
        0x20,
        0x08,
        0x7b,
        0x01,
      ]);
      const file = new File([legacyEncryptedData], 'old.oriveo');

      await expect(parseBackupFile(file)).rejects.toThrow('PASSWORD_REQUIRED');
    });
  });

  /* -- Import preview -------------------------------------------- */

  describe('generateImportPreview', () => {
    it('counts new and existing conversations correctly', async () => {
      // c1 already exists locally
      await putConversation(makeConversation({ id: 'c1' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [
            makeConversation({ id: 'c1' }),  // existing
            makeConversation({ id: 'c2' }),  // new
            makeConversation({ id: 'c3' }),  // new
          ],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());

      expect(preview.totalConversations).toBe(3);
      expect(preview.existingConversationCount).toBe(1);
      expect(preview.newConversationCount).toBe(2);
    });

    it('detects existing providers by id, treating the same kind with a different id as a new instance', async () => {
      await putProvider(makeProvider({ id: 'local-openai', kind: 'openAI' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [
            makeProvider({ id: 'local-openai', kind: 'openAI' }),    // same id -> existing
            makeProvider({ id: 'backup-openai', kind: 'openAI' }),   // same kind, different id -> new instance
          ],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());

      expect(preview.totalProviders).toBe(2);
      expect(preview.existingProviderCount).toBe(1);
      expect(preview.newProviderCount).toBe(1);
    });

    it('normalizes UUID case when detecting existing providers', async () => {
      await putProvider(makeProvider({
        id: '550E8400-E29B-41D4-A716-446655440000',
        kind: 'openRouter',
      }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [
            makeProvider({
              id: '550e8400-e29b-41d4-a716-446655440000',
              kind: 'openRouter',
            }),
          ],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());

      expect(preview.existingProviderCount).toBe(1);
      expect(preview.newProviderCount).toBe(0);
    });

    it('counts notes and noteFolders in the backup, so the note coverage is visible before importing', async () => {
      await putNote(makeNote({ id: 'note-existing-preview' }));
      await putNoteFolder(makeNoteFolder({ id: 'note-folder-existing-preview' }));
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [
            makeNote({ id: 'note-existing-preview' }),
            makeNote({ id: 'note-new-preview' }),
          ],
          [
            makeNoteFolder({ id: 'note-folder-existing-preview' }),
            makeNoteFolder({ id: 'note-folder-new-preview' }),
          ],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());

      expect(preview.totalNotes).toBe(2);
      expect(preview.existingNoteCount).toBe(1);
      expect(preview.newNoteCount).toBe(1);
      expect(preview.totalNoteFolders).toBe(2);
      expect(preview.existingNoteFolderCount).toBe(1);
      expect(preview.newNoteFolderCount).toBe(1);
    });

    it('detects relay providers by UUID rather than by kind', async () => {
      await putProvider(makeProvider({ id: 'relay-1', kind: 'relay' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [
            makeProvider({ id: 'relay-1', kind: 'relay' }),  // same UUID -> existing
            makeProvider({ id: 'relay-2', kind: 'relay' }),  // different UUID -> new
          ],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());

      expect(preview.existingProviderCount).toBe(1);
      expect(preview.newProviderCount).toBe(1);
    });

    it('sets checksumValid to true when the checksum matches', async () => {
      // Export first to generate a real checksum
      await putConversation(makeConversation({ id: 'c1' }));
      const exportBlob = await exportBackup({ includeApiKeys: false });
      const file = new File([exportBlob], 'test.oriveo');
      const { backupFile } = await parseBackupFile(file);

      await resetDB();

      const preview = await generateImportPreview(backupFile, new Map());
      expect(preview.checksumValid).toBe(true);
    });

    it('sets checksumValid to null when there is no checksum', async () => {
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: { providers: [], conversations: [] },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      expect(preview.checksumValid).toBeNull();
    });
  });

  /* -- Import: new items only ------------------------------------ */

  describe('executeImport — importNew', () => {
    it('only imports conversations that do not exist locally', async () => {
      await putConversation(makeConversation({ id: 'c1', title: 'Local' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [
            makeConversation({ id: 'c1', title: 'Backup' }),  // existing -> skipped
            makeConversation({ id: 'c2', title: 'New' }),      // new -> imported
          ],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'importNew');

      expect(result.conversationsImported).toBe(1);
      expect(result.conversationsSkipped).toBe(1);

      // Verify that the local c1 was not overwritten
      const convs = await getAllConversations();
      const c1 = convs.find((c) => c.id === 'c1');
      expect(c1?.title).toBe('Local');
    });

    it('skips existing providers by id, importing the same kind with a different id as a new instance', async () => {
      await putProvider(makeProvider({ id: 'local-p', kind: 'openAI' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [
            makeProvider({ id: 'local-p', kind: 'openAI' }),    // same id -> skipped
            makeProvider({ id: 'backup-p', kind: 'openAI' }),   // same kind, different id -> imported
          ],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'importNew');

      expect(result.providersImported).toBe(1);
      expect(result.providersSkipped).toBe(1);

      const providers = await getAllProviders();
      expect(providers).toHaveLength(2);
      expect(providers.map((p) => p.id).sort()).toEqual(['backup-p', 'local-p']);
    });

    it('restores folders and keeps the conversation folderID relationship', async () => {
      const folder = makeFolder({ id: 'folder-import-1', name: 'Imported Folder' });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'iOS',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          folders: [folder],
          conversations: [
            makeConversation({
              id: 'conv-folder-import-1',
              title: 'Imported Chat',
              folderID: folder.id,
            }),
          ],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'importNew');

      expect(result.conversationsImported).toBe(1);

      const folders = await getAllFolders();
      const conversations = await getAllConversations();
      expect(folders).toEqual([folder]);
      expect(conversations[0].folderID).toBe(folder.id);
    });

    it('imports only notes and noteFolders missing locally, and keeps trash tombstones', async () => {
      const existingFolder = makeNoteFolder({ id: 'note-folder-import-existing', name: 'Local folder' });
      const newFolder = makeNoteFolder({ id: 'note-folder-import-new', name: 'Imported folder' });
      const existingNote = makeNote({ id: 'note-import-existing', title: 'Local note' });
      const newNote = makeNote({ id: 'note-import-new', noteFolderID: newFolder.id });
      const trashedNote = makeNote({
        id: 'note-import-trash',
        noteFolderID: newFolder.id,
        deletedAt: '2026-06-20T00:00:00.000Z',
      });
      await putNoteFolder(existingFolder);
      await putNote(existingNote);
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'iOS',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [
            makeNote({ id: existingNote.id, title: 'Backup note' }),
            newNote,
            trashedNote,
          ],
          [
            makeNoteFolder({ id: existingFolder.id, name: 'Backup folder' }),
            newFolder,
          ],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'importNew');

      expect(result.notesImported).toBe(2);
      expect(result.notesSkipped).toBe(1);
      expect(result.noteFoldersImported).toBe(1);
      expect(result.noteFoldersSkipped).toBe(1);
      const notes = await getAllNotes();
      expect(notes.find((note) => note.id === existingNote.id)?.title).toBe('Local note');
      expect(notes.find((note) => note.id === newNote.id)?.noteFolderID).toBe(newFolder.id);
      expect(notes.find((note) => note.id === trashedNote.id)?.deletedAt).toBe(trashedNote.deletedAt);
      const folders = await getAllNoteFolders();
      expect(folders.find((folder) => folder.id === existingFolder.id)?.name).toBe('Local folder');
      expect(folders.find((folder) => folder.id === newFolder.id)?.name).toBe('Imported folder');
    });

    it('importNew skips a deleted noteFolder and clears new note references to it', async () => {
      const deletedFolder = makeNoteFolder({
        id: 'note-folder-import-deleted',
        name: 'Deleted folder',
        deletedAt: '2026-06-22T00:00:00.000Z',
        updatedAt: '2026-06-22T00:00:00.000Z',
      });
      const note = makeNote({
        id: 'note-import-deleted-folder-ref',
        noteFolderID: deletedFolder.id,
      });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [note],
          [deletedFolder],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'importNew');

      expect((await getAllNoteFolders()).map((folder) => folder.id)).not.toContain(deletedFolder.id);
      expect((await getAllNotes()).find((item) => item.id === note.id)?.noteFolderID).toBeUndefined();
    });

    it('restores correctly from a legacy backup with no folders field', async () => {
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Android',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [
            makeConversation({ id: 'legacy-conv-1', title: 'Legacy Backup' }),
          ],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'importNew');

      expect(result.conversationsImported).toBe(1);
      expect(await getAllFolders()).toEqual([]);
      expect((await getAllConversations())[0].title).toBe('Legacy Backup');
    });

    it('restores user skills, clearing knowledgeBase while flagging that it needs re-uploading', async () => {
      const backupSkill = makeSkill({
        id: 'skill-import-1',
        knowledgeBase: {
          provider: 'openai',
          retrievalModel: 'gpt-5.4-mini',
          vectorStoreId: '',
          expiresAfterDays: 90,
          files: [
            {
              id: 'kb-1',
              name: 'guide.pdf',
              mimeType: 'application/pdf',
              sizeBytes: 2048,
              ingestionMode: 'native_file',
              status: 'disabled',
              createdAt: '2026-04-12T00:00:00.000Z',
              updatedAt: '2026-04-12T00:00:00.000Z',
            },
          ],
          updatedAt: '2026-04-12T00:00:00.000Z',
        },
      });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [],
          skills: [backupSkill],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'importNew');

      expect(result.skillsImported).toBe(1);
      expect(result.skillsRequiringKnowledgeReupload).toBe(1);
      const restoredSkills = await loadCachedUserSkills();
      expect(restoredSkills).toHaveLength(1);
      expect(restoredSkills[0]?.id).toBe('skill-import-1');
      expect(restoredSkills[0]?.knowledgeBase).toBeNull();
    });

    it('e2e roundtrip: message citations survive export and import unchanged', async () => {
      // Web search citations have to survive a backup, or the user loses the source
      // references after importing.
      const citations = [
        {
          url: 'https://example.com/article-1',
          title: 'Example Article 1',
          snippet: 'Snippet from first source',
          startIndex: 10,
          endIndex: 50,
        },
        {
          url: 'https://anthropic.com/news',
          title: 'Anthropic News',
          faviconUrl: 'https://anthropic.com/favicon.ico',
          index: 2,
        },
        {
          // url only, the minimal valid Citation
          url: 'https://minimal.example.org/',
        },
      ];

      const originalMsg = makeMessage({
        id: 'msg-with-citations',
        role: 'assistant',
        text: 'Here are the sources I used.',
        citations,
      });
      await putConversation(makeConversation({
        id: 'conv-citations-roundtrip',
        title: 'Citations roundtrip',
        messages: [originalMsg],
      }));

      // export, take the blob, parse, executeImport. Clearing the database first and using
      // replaceAll would be a purer roundtrip, but this test only cares about field fidelity.
      const blob = await exportBackup({ includeApiKeys: false });

      await resetDB();

      const file = new File([blob], 'backup.zip', { type: 'application/zip' });
      const parsed = await parseBackupFile(file);
      const preview = await generateImportPreview(parsed.backupFile, parsed.imageEntries);
      const result = await executeImport(preview, 'importNew');

      expect(result.conversationsImported).toBe(1);

      const restored = await getAllConversations();
      expect(restored).toHaveLength(1);
      const restoredMsg = restored[0]?.messages.find((m) => m.id === 'msg-with-citations');
      expect(restoredMsg).toBeDefined();
      // The citations array must be preserved exactly, with no field lost
      expect(restoredMsg?.citations).toEqual(citations);
    });
  });

  /* -- Import: merge ---------------------------------------------- */

  describe('executeImport — merge', () => {
    it('merges messages into an existing conversation', async () => {
      const t1 = '2026-03-01T10:00:00.000Z';
      const t2 = '2026-03-01T10:01:00.000Z';
      const t3 = '2026-03-01T10:02:00.000Z';

      await putConversation(makeConversation({
        id: 'c1',
        updatedAt: t2,
        messages: [
          makeMessage({ id: 'm1', text: 'Hello', createdAt: t1 }),
          makeMessage({ id: 'm2', text: 'World', createdAt: t2 }),
        ],
      }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'iOS',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [makeConversation({
            id: 'c1',
            updatedAt: t3,
            messages: [
              makeMessage({ id: 'm2', text: 'World', createdAt: t2 }),  // duplicate
              makeMessage({ id: 'm3', text: 'New!', createdAt: t3 }),   // new
            ],
          })],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'merge');

      expect(result.conversationsMerged).toBe(1);

      const convs = await getAllConversations();
      const c1 = convs.find((c) => c.id === 'c1')!;

      // Expect 3 messages: m1, the deduplicated m2, and m3
      expect(c1.messages).toHaveLength(3);
      expect(c1.messages.map((m) => m.id)).toEqual(['m1', 'm2', 'm3']);
    });

    it('takes the later updatedAt when merging', async () => {
      const early = '2026-01-01T00:00:00.000Z';
      const late = '2026-03-01T00:00:00.000Z';

      await putConversation(makeConversation({ id: 'c1', updatedAt: early, title: 'Old Title' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [makeConversation({ id: 'c1', updatedAt: late, title: 'New Title' })],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'merge');

      const convs = await getAllConversations();
      const c1 = convs.find((c) => c.id === 'c1')!;
      expect(c1.updatedAt).toBe(late);
      expect(c1.title).toBe('New Title');
    });

    it('merge writes new folders and lets a newer folder overwrite the local one', async () => {
      const older = makeFolder({
        id: 'folder-merge-existing',
        name: 'Old Name',
        updatedAt: '2026-03-01T00:00:00.000Z',
      });
      const newer = makeFolder({
        id: 'folder-merge-existing',
        name: 'New Name',
        updatedAt: '2026-03-02T00:00:00.000Z',
      });
      const added = makeFolder({
        id: 'folder-merge-added',
        name: 'Added Folder',
        updatedAt: '2026-03-03T00:00:00.000Z',
      });
      await putFolder(older);

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          folders: [newer, added],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'merge');

      const folders = await getAllFolders();
      expect(folders).toHaveLength(2);
      expect(folders.find((folder) => folder.id === older.id)?.name).toBe('New Name');
      expect(folders.find((folder) => folder.id === added.id)).toEqual(added);
    });

    it('does not create two folders out of UUID case variants when merging folders', async () => {
      const upper = 'F0E1D2C3-5555-4666-8777-888899990000';
      const local = makeFolder({
        id: upper,
        name: 'Local folder',
        updatedAt: '2026-03-01T00:00:00.000Z',
      });
      // The backup keeps the lowercase id from export time and has the later update, so it wins
      const backupVariant = makeFolder({
        id: upper.toLowerCase(),
        name: 'Renamed in backup',
        updatedAt: '2026-03-02T00:00:00.000Z',
      });
      await putFolder(local);

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          folders: [backupVariant],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'merge');

      const folders = await getAllFolders();
      expect(folders).toHaveLength(1);
      // Keep the local id and overwrite with the newer backup content
      expect(folders[0].id).toBe(upper);
      expect(folders[0].name).toBe('Renamed in backup');
    });

    it('takes the newer version by updatedAt when merging notes and noteFolders, counting winners as merged and losers as skipped', async () => {
      const localNewer = makeNote({
        id: 'note-merge-local-wins',
        title: 'Local newer',
        updatedAt: '2026-06-22T00:00:00.000Z',
      });
      const backupOlder = makeNote({
        id: localNewer.id,
        title: 'Backup older',
        updatedAt: '2026-06-21T00:00:00.000Z',
      });
      const localOlder = makeNote({
        id: 'note-merge-backup-wins',
        title: 'Local older',
        updatedAt: '2026-06-20T00:00:00.000Z',
      });
      const backupNewer = makeNote({
        id: localOlder.id,
        title: 'Backup newer',
        updatedAt: '2026-06-23T00:00:00.000Z',
      });
      const backupTrash = makeNote({
        id: 'note-merge-trash',
        title: 'Trash',
        updatedAt: '2026-06-24T00:00:00.000Z',
        deletedAt: '2026-06-24T01:00:00.000Z',
      });
      const localFolder = makeNoteFolder({
        id: 'note-folder-merge',
        name: 'Local Folder',
        updatedAt: '2026-06-20T00:00:00.000Z',
      });
      const backupFolder = makeNoteFolder({
        id: localFolder.id,
        name: 'Backup Folder',
        updatedAt: '2026-06-23T00:00:00.000Z',
      });
      // Note folder losing the comparison: updated locally, older in the backup, so the local copy is kept and counted as skipped
      const localFolderNewer = makeNoteFolder({
        id: 'note-folder-merge-local-wins',
        name: 'Local Folder Wins',
        updatedAt: '2026-06-25T00:00:00.000Z',
      });
      const backupFolderOlder = makeNoteFolder({
        id: localFolderNewer.id,
        name: 'Backup Folder Older',
        updatedAt: '2026-06-22T00:00:00.000Z',
      });
      await putNote(localNewer);
      await putNote(localOlder);
      await putNoteFolder(localFolder);
      await putNoteFolder(localFolderNewer);

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Android',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [backupOlder, backupNewer, backupTrash],
          [backupFolder, backupFolderOlder],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'merge');

      // merged counts only the last-write-wins winners (backupNewer / backupFolder); the losers (backupOlder / backupFolderOlder) count as skipped
      expect(result.notesImported).toBe(1);
      expect(result.notesMerged).toBe(1);
      expect(result.notesSkipped).toBe(1);
      expect(result.noteFoldersMerged).toBe(1);
      expect(result.noteFoldersSkipped).toBe(1);
      const notes = await getAllNotes();
      expect(notes.find((note) => note.id === localNewer.id)?.title).toBe('Local newer');
      expect(notes.find((note) => note.id === localOlder.id)?.title).toBe('Backup newer');
      expect(notes.find((note) => note.id === backupTrash.id)?.deletedAt).toBe(backupTrash.deletedAt);
      const folders = await getAllNoteFolders();
      expect(folders.find((folder) => folder.id === localFolder.id)?.name).toBe('Backup Folder');
      expect(folders.find((folder) => folder.id === localFolderNewer.id)?.name).toBe('Local Folder Wins');
    });

    it('a newer noteFolder tombstone in merge clears the folder reference of a local-only note', async () => {
      const folder = makeNoteFolder({
        id: 'note-folder-merge-deleted-wins',
        name: 'Local Folder',
        updatedAt: '2026-06-20T00:00:00.000Z',
      });
      const localOnlyNote = makeNote({
        id: 'note-local-only-folder-ref',
        noteFolderID: folder.id,
        updatedAt: '2026-06-20T01:00:00.000Z',
      });
      const tombstone = makeNoteFolder({
        id: folder.id,
        name: 'Deleted Folder',
        deletedAt: '2026-06-23T00:00:00.000Z',
        updatedAt: '2026-06-23T00:00:00.000Z',
      });
      await putNoteFolder(folder);
      await putNote(localOnlyNote);

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [],
          [tombstone],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'merge');

      expect((await getAllNoteFolders()).find((item) => item.id === folder.id)?.deletedAt).toBe(tombstone.deletedAt);
      expect((await getAllNotes()).find((note) => note.id === localOnlyNote.id)?.noteFolderID).toBeUndefined();
    });

    it('merge keeps a valid folder reference on a backup note when the local noteFolder is newer', async () => {
      const folder = makeNoteFolder({
        id: 'note-folder-merge-local-wins',
        name: 'Local Folder',
        updatedAt: '2026-06-24T00:00:00.000Z',
      });
      const olderTombstone = makeNoteFolder({
        id: folder.id,
        name: 'Old Deleted Folder',
        deletedAt: '2026-06-22T00:00:00.000Z',
        updatedAt: '2026-06-22T00:00:00.000Z',
      });
      const backupNote = makeNote({
        id: 'note-backup-keeps-local-folder',
        noteFolderID: folder.id,
      });
      await putNoteFolder(folder);

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [backupNote],
          [olderTombstone],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'merge');

      expect((await getAllNoteFolders()).find((item) => item.id === folder.id)?.name).toBe('Local Folder');
      expect((await getAllNotes()).find((note) => note.id === backupNote.id)?.noteFolderID).toBe(folder.id);
    });

    it('merge adds new conversations', async () => {
      await putConversation(makeConversation({ id: 'c1' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [makeConversation({ id: 'c2', title: 'Brand New' })],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'merge');

      expect(result.conversationsImported).toBe(1);
      expect(result.conversationsMerged).toBe(0);

      const convs = await getAllConversations();
      expect(convs).toHaveLength(2);
    });

    it('does not overwrite the local API key when merging providers', async () => {
      await putProvider(makeProvider({
        id: 'p1',
        kind: 'openAI',
        apiKey: 'local-key',
        apiKeyPreview: 'local-preview',
      }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [makeProvider({
            id: 'p1',
            kind: 'openAI',
            apiKey: '',
            apiKeyPreview: '',
          })],
          conversations: [],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'merge');

      const providers = await getAllProviders();
      const p1 = providers.find((p) => p.id === 'p1')!;
      expect(p1.apiKey).toBe('local-key');
    });
  });

  /* -- Import: replace everything --------------------------------- */

  describe('executeImport — replaceAll', () => {
    it('does not overwrite the current partition when expectedUID has changed', async () => {
      const local = makeProvider({ id: 'guest-local-provider' });
      await putProvider(local);
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [makeProvider({ id: 'user-a-backup-provider' })],
          conversations: [],
        },
        encryptedKeys: null,
      };
      const preview = await generateImportPreview(backupFile, new Map());

      await expect(executeImport(preview, 'replaceAll', undefined, 'user-A'))
        .rejects.toThrow('Backup import storage partition changed from user-A');

      expect((await getAllProviders()).map((provider) => provider.id)).toEqual([local.id]);
    });

    it('clears local data and writes the backup data', async () => {
      // 3 local conversations and 2 local providers
      await putConversation(makeConversation({ id: 'local-c1' }));
      await putConversation(makeConversation({ id: 'local-c2' }));
      await putConversation(makeConversation({ id: 'local-c3' }));
      await putProvider(makeProvider({ id: 'local-p1' }));
      await putProvider(makeProvider({ id: 'local-p2' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'iOS',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [makeProvider({ id: 'backup-p1' })],
          conversations: [makeConversation({ id: 'backup-c1' })],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'replaceAll');

      expect(result.conversationsImported).toBe(1);
      expect(result.providersImported).toBe(1);

      const convs = await getAllConversations();
      expect(convs).toHaveLength(1);
      expect(convs[0].id).toBe('backup-c1');

      const providers = await getAllProviders();
      expect(providers).toHaveLength(1);
      expect(providers[0].id).toBe('backup-p1');
    });

    it('replaces notes and noteFolders without leaving old notes behind', async () => {
      await putNote(makeNote({ id: 'old-note' }));
      await putNoteFolder(makeNoteFolder({ id: 'old-note-folder' }));
      const folder = makeNoteFolder({ id: 'backup-note-folder' });
      const note = makeNote({ id: 'backup-note', noteFolderID: folder.id });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [note],
          [folder],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      const result = await executeImport(preview, 'replaceAll');

      expect(result.notesImported).toBe(1);
      expect(result.noteFoldersImported).toBe(1);
      expect((await getAllNotes()).map((item) => item.id)).toEqual([note.id]);
      expect((await getAllNoteFolders()).map((item) => item.id)).toEqual([folder.id]);
    });

    it('replaceAll skips a deleted noteFolder and clears noteFolderID references', async () => {
      const deletedFolder = makeNoteFolder({
        id: 'note-folder-replace-deleted',
        deletedAt: '2026-06-22T00:00:00.000Z',
        updatedAt: '2026-06-22T00:00:00.000Z',
      });
      const note = makeNote({
        id: 'note-replace-deleted-folder-ref',
        noteFolderID: deletedFolder.id,
      });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [] },
          [note],
          [deletedFolder],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'replaceAll');

      expect((await getAllNoteFolders()).map((item) => item.id)).not.toContain(deletedFolder.id);
      expect((await getAllNotes()).find((item) => item.id === note.id)?.noteFolderID).toBeUndefined();
    });

    it('clears the original local data after a replace', async () => {
      await putConversation(makeConversation({ id: 'old-data' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: { providers: [], conversations: [] },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'replaceAll');

      const convs = await getAllConversations();
      expect(convs).toHaveLength(0);
    });

    it('replaces local folders and preserves conversation folderID', async () => {
      await putFolder(makeFolder({ id: 'folder-local-old', name: 'Local Old' }));
      await putConversation(makeConversation({ id: 'conv-local-old', title: 'Local Old Chat' }));

      const folder = makeFolder({ id: 'folder-replace-1', name: 'Replace Folder' });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          folders: [folder],
          conversations: [
            makeConversation({
              id: 'conv-replace-folder-1',
              title: 'Replace Chat',
              folderID: folder.id,
            }),
          ],
        },
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await executeImport(preview, 'replaceAll');

      expect(await getAllFolders()).toEqual([folder]);
      expect(await getAllConversations()).toMatchObject([
        { id: 'conv-replace-folder-1', folderID: folder.id },
      ]);
    });
  });

  /* -- End to end: export then import ----------------------------- */

  describe('round-trip: export → import', () => {
    it('BackupFolder serialization round-trips every field', () => {
      const folder = makeFolder({
        id: 'folder-roundtrip-1',
        name: 'Roundtrip Folder',
        sortOrder: 2500,
        firestoreUpdatedAt: '2026-03-15T10:30:00.000Z',
      });
      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [],
          conversations: [],
          folders: [folder],
        },
        encryptedKeys: null,
      };

      const decoded = JSON.parse(JSON.stringify(backupFile)) as BackupFile;

      expect(decoded.data.folders).toEqual([folder]);
    });

    it('export then import restores the full data', async () => {
      const conv = makeConversation({
        id: 'rt-c1',
        title: 'Round Trip',
        messages: [
          makeMessage({ id: 'rt-m1', text: 'Hello from export' }),
          makeMessage({ id: 'rt-m2', text: 'Goodbye from export' }),
        ],
        folderID: 'rt-folder-1',
      });
      const folder = makeFolder({ id: 'rt-folder-1', name: 'Round Trip Folder' });
      const prov = makeProvider({
        id: 'rt-p1',
        kind: 'anthropic',
        apiKey: 'sk-secret',
      });

      await putFolder(folder);
      await putConversation(conv);
      await putProvider(prov);

      // Export without keys
      const blob = await exportBackup({ includeApiKeys: false });

      // Clear locally
      await resetDB();

      // Import
      const file = new File([blob], 'roundtrip.oriveo');
      const { backupFile, imageEntries } = await parseBackupFile(file);
      const preview = await generateImportPreview(backupFile, imageEntries);

      expect(preview.checksumValid).toBe(true);

      const result = await executeImport(preview, 'importNew');

      expect(result.conversationsImported).toBe(1);
      expect(result.providersImported).toBe(1);

      const convs = await getAllConversations();
      expect(convs[0].title).toBe('Round Trip');
      expect(convs[0].messages).toHaveLength(2);
      expect(convs[0].folderID).toBe(folder.id);

      const folders = await getAllFolders();
      expect(folders).toEqual([folder]);

      // The API key should be empty, since it was not included
      const providers = await getAllProviders();
      expect(providers[0].apiKey).toBe('');
    });

    it('restores the key after exporting with keys and importing again', async () => {
      await putProvider(makeProvider({
        id: 'key-p1',
        kind: 'openAI',
        apiKey: 'sk-my-secret-key',
        apiKeyPreview: 'sk-...key',
      }));

      const password = 'secure-password-123';
      const blob = await exportBackup({ includeApiKeys: true, password });

      await resetDB();

      const file = new File([blob], 'withkeys.oriveo');
      const { backupFile, imageEntries } = await parseBackupFile(file);
      const preview = await generateImportPreview(backupFile, imageEntries);

      expect(preview.backupFile.containsKeys).toBe(true);

      const result = await executeImport(preview, 'importNew', password);

      expect(result.keysRestored).toBe(1);

      const providers = await getAllProviders();
      expect(providers[0].apiKey).toBe('sk-my-secret-key');
    });

    it('cross-platform: an iOS backup imports on web', async () => {
      // Simulate a ZIP exported by the iOS client
      const zip = new JSZip();
      const iosBackup: BackupFile = {
        version: 1,
        createdAt: '2026-03-15T10:30:00Z',
        appVersion: '1.0.0',
        platform: 'iOS',
        checksum: '',
        containsKeys: false,
        data: {
          providers: [makeProvider({ id: 'ios-p1', kind: 'anthropic', apiKey: '', apiKeyPreview: '' })],
          conversations: [makeConversation({
            id: 'ios-c1',
            title: 'From iPhone',
            messages: [makeMessage({ id: 'ios-m1', text: 'Sent from iOS' })],
          })],
        },
        encryptedKeys: null,
      };
      zip.file('data.json', JSON.stringify(iosBackup));
      const iosBlob = await zip.generateAsync({ type: 'blob' });

      const file = new File([iosBlob], 'ios-backup.oriveo');
      const { backupFile } = await parseBackupFile(file);

      expect(backupFile.platform).toBe('iOS');
      expect(backupFile.data.conversations[0].title).toBe('From iPhone');
    });
  });

  /* -- Consistent tombstone and dangling reference semantics across all three import modes -- */
  describe('executeImport - tombstone and dangling reference consistency across modes', () => {
    it.each(['importNew', 'merge', 'replaceAll'] as const)(
      '%s: importing a tombstoned folder F and a note N referencing F leaves F unwritten and N.folderID empty',
      async (mode: ImportMode) => {
        const tombstoneFolder = makeNoteFolder({
          id: 'note-folder-m5-tombstone',
          name: 'Deleted folder',
          deletedAt: '2026-06-22T00:00:00.000Z',
          updatedAt: '2026-06-22T00:00:00.000Z',
        });
        const note = makeNote({
          id: 'note-m5-dangling-ref',
          noteFolderID: tombstoneFolder.id,
        });
        const backupFile: BackupFile = {
          version: 1,
          createdAt: new Date().toISOString(),
          appVersion: '1.0.0',
          platform: 'Web',
          checksum: '',
          containsKeys: false,
          data: withNotesData({ providers: [], conversations: [] }, [note], [tombstoneFolder]),
          encryptedKeys: null,
        };

        const preview = await generateImportPreview(backupFile, new Map());
        await executeImport(preview, mode);

        // Tombstoned folders are not written to the database
        expect((await getAllNoteFolders()).map((folder) => folder.id)).not.toContain(tombstoneFolder.id);
        // A note referencing a tombstoned folder has its folderID cleared
        expect((await getAllNotes()).find((item) => item.id === note.id)?.noteFolderID).toBeUndefined();
      },
    );
  });

  /* -- Single-transaction atomicity of the main database import, plus rollback on failure -- */
  describe('executeImport - single-transaction atomicity of the main database', () => {
    // A value containing a Symbol makes an IndexedDB put throw DataCloneError, which is how a mid-write failure is constructed.
    function poisonNote(id: string): Note {
      return { ...makeNote({ id }), bad: Symbol('boom') } as unknown as Note;
    }

    it('replaceAll rolls the main database back entirely when a write fails midway, leaving no partial writes and restoring the old data', async () => {
      // Seed old data covering all five types
      await putConversation(makeConversation({ id: 'old-conv', title: 'Old' }));
      await putProvider(makeProvider({ id: 'old-prov', kind: 'openAI' }));
      await putFolder(makeFolder({ id: 'old-folder', name: 'Old folder' }));
      await putNote(makeNote({ id: 'old-note' }));
      await putNoteFolder(makeNoteFolder({ id: 'old-note-folder' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          {
            providers: [makeProvider({ id: 'new-prov', kind: 'anthropic' })],
            conversations: [makeConversation({ id: 'new-conv', title: 'New' })],
            folders: [makeFolder({ id: 'new-folder', name: 'New folder' })],
          } as BackupData,
          [makeNote({ id: 'new-note-ok' }), poisonNote('new-note-poison')],
          [makeNoteFolder({ id: 'new-note-folder' })],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await expect(executeImport(preview, 'replaceAll')).rejects.toBeDefined();

      // Full rollback: the old data is still there and not one new record landed
      expect((await getAllConversations()).map((c) => c.id)).toEqual(['old-conv']);
      expect((await getAllProviders()).map((p) => p.id)).toEqual(['old-prov']);
      expect((await getAllFolders()).map((f) => f.id)).toEqual(['old-folder']);
      expect((await getAllNotes()).map((n) => n.id)).toEqual(['old-note']);
      expect((await getAllNoteFolders()).map((f) => f.id)).toEqual(['old-note-folder']);
    });

    it('merge rolls the main database back entirely when a write fails midway, leaving no partial new data', async () => {
      await putNote(makeNote({ id: 'old-note' }));
      await putNoteFolder(makeNoteFolder({ id: 'old-note-folder' }));

      const backupFile: BackupFile = {
        version: 1,
        createdAt: new Date().toISOString(),
        appVersion: '1.0.0',
        platform: 'Web',
        checksum: '',
        containsKeys: false,
        data: withNotesData(
          { providers: [], conversations: [], folders: [makeFolder({ id: 'new-folder' })] } as BackupData,
          [makeNote({ id: 'new-note-ok' }), poisonNote('new-note-poison')],
          [makeNoteFolder({ id: 'new-note-folder' })],
        ),
        encryptedKeys: null,
      };

      const preview = await generateImportPreview(backupFile, new Map());
      await expect(executeImport(preview, 'merge')).rejects.toBeDefined();

      // merge does not clear the database; on failure no new data may be left behind, with no partial writes in folders, noteFolders or notes
      expect((await getAllFolders()).map((f) => f.id)).toEqual([]);
      expect((await getAllNotes()).map((n) => n.id).sort()).toEqual(['old-note']);
      expect((await getAllNoteFolders()).map((f) => f.id).sort()).toEqual(['old-note-folder']);
    });
  });
});
