import type {
  Provider,
  Conversation,
  Folder,
  AppPreference,
  LastUsedModelRef,
  Skill,
  Note,
  NoteFolder,
} from '@oriveo/shared';
import type { MemoryItem } from '@oriveo/core/context/memory-items';
import type { ContextCheckpointRow } from '../infra/storage/context-checkpoint-store';

/* ── Import modes ─────────────────────────────────────────── */

export type ImportMode = 'importNew' | 'merge' | 'replaceAll';

/* ── Top-level data.json schema ─────────────────── */

export interface BackupFile {
  version: number;
  createdAt: string;
  appVersion: string;
  platform: 'iOS' | 'Android' | 'Web';
  checksum: string;                              // "sha256:<hex>"
  containsKeys: boolean;
  data: BackupData;
  attachmentChecksums?: Record<string, string>;  // { "filename": "sha256:<hex>" }
  encryptedKeys?: string | null;                 // Base64, only when containsKeys=true
}

export interface BackupData {
  providers: Provider[];
  conversations: Conversation[];
  skills?: Skill[];
  folders?: BackupFolder[];
  notes?: Note[];
  noteFolders?: BackupNoteFolder[];
  /**
   * Same shape as iOS / Android: theme / language are always present; memory fields are written only when
   * they have a value -- memoryText / memoryAntiForgetText are omitted when empty, memoryAntiForgetEnabled
   * is written only when true, and memoryUpdatedAt is an ISO 8601 string.
   * darkPalette is omitted when unset; an old backup without this key clears it to unset after restore (rendered as the default dark).
   * darkPaletteCustom (the custom palette's seed color) follows darkPalette: omitted when unset, and an old backup without this key = cleared to unset after restore.
   */
  preferences?: Partial<Pick<
    AppPreference,
    'theme' | 'darkPalette' | 'darkPaletteCustom' | 'language' | 'memoryText' | 'memoryAntiForgetEnabled' | 'memoryAntiForgetText' | 'memoryUpdatedAt'
  >>;
  lastUsedModelRef?: LastUsedModelRef | null;
  /** Full context checkpoint table; older backups lack this key. createdAt is in milliseconds, nullable fields are null. */
  checkpoints?: BackupContextCheckpoint[];
  /** Memory item schema version (currently 2); older backups lack this key. */
  memorySchemaVersion?: number;
  /** Full memory item v2 table (including tombstones and conflicted items, in list order); older backups lack this key and are migrated from the memory fields in preferences on import. */
  memoryItems?: MemoryItem[];
}

export type BackupContextCheckpoint = ContextCheckpointRow;

export type BackupFolder = Folder;
export type BackupNoteFolder = NoteFolder;

/* ── Compatibility with the older fully encrypted blob format ──────────── */

export interface LegacyBackupPayload {
  metadata: {
    version: number;
    createdAt: string;
    appVersion: string;
    includesApiKeys: boolean;
  };
  conversations: Conversation[];
  providers: Provider[];
}

/* ── Export options ─────────────────────────────────────────── */

export interface ExportOptions {
  includeApiKeys: boolean;
  password?: string;
}

/* ── Import preview, shown after parsing and before executing ───────────────────── */

export interface ImportPreview {
  backupFile: BackupFile;
  totalConversations: number;
  totalProviders: number;
  totalNotes: number;
  totalNoteFolders: number;
  existingConversationCount: number;
  existingProviderCount: number;
  existingNoteCount: number;
  existingNoteFolderCount: number;
  newConversationCount: number;
  newProviderCount: number;
  newNoteCount: number;
  newNoteFolderCount: number;
  hasImages: boolean;
  checksumValid: boolean | null;       // null = no checksum, from an older version
  attachmentChecksumIssues: string[];  // file names that did not match
  /** Zip entries under attachments/ (relative names), read one at a time. */
  imageEntries: BackupEntryReader;
}

/**
 * Random access to the image entries of a backup by name. Only names are kept in memory; each read
 * decompresses one entry and rejects with RESOURCE_LIMIT_EXCEEDED past the per-entry byte cap.
 */
export interface BackupEntryReader {
  readonly names: readonly string[];
  has(name: string): boolean;
  read(name: string): Promise<Uint8Array | null>;
}

/** What import entry points accept: a reader, or an in-memory map (normalized to a reader). */
export type BackupEntrySource = BackupEntryReader | ReadonlyMap<string, Uint8Array>;

/* ── Import result ─────────────────────────────────────────── */

export interface ImportResult {
  conversationsImported: number;
  conversationsSkipped: number;
  conversationsMerged: number;
  providersImported: number;
  providersSkipped: number;
  providersMerged: number;
  skillsImported: number;
  skillsSkipped: number;
  skillsMerged: number;
  skillsRequiringKnowledgeReupload: number;
  notesImported: number;
  notesSkipped: number;
  notesMerged: number;
  noteFoldersImported: number;
  noteFoldersSkipped: number;
  noteFoldersMerged: number;
  keysRestored: number;
  imagesRestored: number;
  restoredPreferences: boolean;
  restoredLastUsedModel: boolean;
}
