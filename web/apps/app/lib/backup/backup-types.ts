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
  preferences?: Pick<AppPreference, 'theme' | 'language'>;
  lastUsedModelRef?: LastUsedModelRef | null;
}

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
  imageEntries: Map<string, Uint8Array>;  // image data from the ZIP, held in memory
}

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
