/**
 * Backup module barrel export
 *
 * Responsibilities of the internal modules:
 * - backup-crypto: AES-256-GCM encryption and decryption, SHA-256, Base64
 * - backup-format: ZIP/JSON and older-format parsing, deterministic serialization
 * - backup-export: export flow and provider sanitizing
 * - backup-import: import preview, the three import modes, message merging
 */

// Export
export {
  exportBackup,
  exportBackupToAutomaticStorage,
  saveBackupFile,
} from './backup-export';
export type {
  AutomaticBackupStorage,
  AutomaticBackupChunkWriter,
  AutomaticBackupStorageResult,
} from './backup-export';

// Parsing
export { parseBackupFile } from './backup-format';

// Import
export { generateImportPreview, executeImport } from './backup-import';
export { executeImportAndRefreshStore } from './backup-import-runner';

// Types (re-export for convenience)
export type {
  BackupFile,
  BackupData,
  BackupFolder,
  BackupNoteFolder,
  ExportOptions,
  ImportMode,
  ImportPreview,
  ImportResult,
  LegacyBackupPayload,
} from './backup-types';
