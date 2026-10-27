import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import type { AppPreference } from '@oriveo/shared';
import type { BackupFile } from '..';
import { resetDBConnection } from '../../infra/storage/idb';
import { resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';
import { getPreference, setPreference } from '../../infra/storage/preferences';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { resolveDarkPaletteId } from '@oriveo/shared';

// Source of truth for the dark palette fixture: shared/theme-contracts/dark-palettes.v1.json
const darkPaletteCases = (JSON.parse(readFileSync(
  join(process.cwd(), '../../..', 'shared/theme-contracts/dark-palettes.v1.json'),
  'utf8',
)) as { resolveCases: Array<{ name: string; stored: unknown; renders: string }> }).resolveCases;
const darkPaletteCase = (name: string) => darkPaletteCases.find((c) => c.name === name)!;

// Backup memory fields: exported in the same shape as iOS / Android; on import each field is restored only when present and goes through the preference sync path.

const didUpdatePreferences = vi.fn();
vi.mock('../../core/sync-port', async () => {
  const actual = await vi.importActual<typeof import('../../core/sync-port')>('../../core/sync-port');
  return { ...actual, getSyncAdapter: () => ({ didUpdatePreferences }) };
});

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

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', { value: nodeCrypto.webcrypto, writable: true, configurable: true });
}

const { exportBackup, parseBackupFile, generateImportPreview, executeImport } = await import('..');
const { canonicalJSON } = await import('../backup-format');
const { sha256hex } = await import('../backup-crypto');

const DEFAULT_PREFS: AppPreference = { theme: 'dark', language: 'system', sendShortcut: 'enter' };

function localPrefs(): AppPreference {
  return getPreference<AppPreference>('preferences', DEFAULT_PREFS);
}

async function resetDB(): Promise<void> {
  resetDBConnection();
  resetImageDBConnection();
  for (const db of await indexedDB.databases()) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
  await setActiveUID('guest');
}

async function readDataJson(blob: Blob): Promise<BackupFile> {
  const zip = await JSZip.loadAsync(await blob.arrayBuffer());
  return JSON.parse(await zip.file('data.json')!.async('string'));
}

/** Hand-writes a backup in another client's shape (with a correct checksum) and runs it through the production preview + import. */
async function importHandWritten(preferences: Record<string, unknown>): Promise<void> {
  const data = { providers: [], conversations: [], preferences } as unknown as BackupFile['data'];
  const checksum = await sha256hex(new TextEncoder().encode(canonicalJSON(data)));
  const backupFile: BackupFile = {
    version: 1,
    createdAt: '2026-10-15T00:00:00Z',
    appVersion: '1.0.0',
    platform: 'iOS',
    checksum: `sha256:${checksum}`,
    containsKeys: false,
    data,
    encryptedKeys: null,
  };
  const preview = await generateImportPreview(backupFile, new Map());
  expect(preview.checksumValid).toBe(true);
  await executeImport(preview, 'importNew');
}

describe('backup memory preferences', () => {
  beforeEach(async () => {
    await resetDB();
    didUpdatePreferences.mockReset();
    setPreference('preferences', DEFAULT_PREFS);
  });

  it('export writes the iOS-shaped memory fields and import restores them', async () => {
    setPreference('preferences', {
      ...DEFAULT_PREFS,
      memoryText: 'I am a Go engineer.',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go.',
      memoryUpdatedAt: '2026-10-01T08:00:00.000Z',
    });

    const blob = await exportBackup({ includeApiKeys: false });
    const exported = await readDataJson(blob);
    expect(exported.data.preferences).toEqual({
      theme: 'dark',
      language: 'system',
      memoryText: 'I am a Go engineer.',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go.',
      memoryUpdatedAt: '2026-10-01T08:00:00.000Z',
    });

    await resetDB();
    setPreference('preferences', DEFAULT_PREFS);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'memory.oriveo'));
    const result = await executeImport(await generateImportPreview(backupFile, imageEntries), 'importNew');

    expect(result.restoredPreferences).toBe(true);
    expect(localPrefs()).toMatchObject({
      memoryText: 'I am a Go engineer.',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go.',
      memoryUpdatedAt: '2026-10-01T08:00:00.000Z',
    });
    expect(didUpdatePreferences).toHaveBeenCalledWith({
      memoryText: 'I am a Go engineer.',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Prefer Go.',
      memoryUpdatedAt: '2026-10-01T08:00:00.000Z',
    });
  });

  it('export omits empty memory fields and a false anti-forget flag', async () => {
    setPreference('preferences', { ...DEFAULT_PREFS, memoryText: '', memoryAntiForgetEnabled: false, memoryAntiForgetText: '' });
    const exported = await readDataJson(await exportBackup({ includeApiKeys: false }));
    expect(exported.data.preferences).toEqual({ theme: 'dark', language: 'system' });
  });

  it('imports a hand-written iOS preferences object, truncating text and normalizing the date', async () => {
    await importHandWritten({
      theme: 'light',
      language: 'system',
      memoryText: 'm'.repeat(2100),
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 's'.repeat(250),
      memoryUpdatedAt: '2026-09-30T12:34:56Z',
    });

    const prefs = localPrefs();
    expect(prefs.memoryText).toBe('m'.repeat(2000));
    expect(prefs.memoryAntiForgetEnabled).toBe(true);
    expect(prefs.memoryAntiForgetText).toBe('s'.repeat(200));
    expect(prefs.memoryUpdatedAt).toBe('2026-09-30T12:34:56.000Z');
    expect(prefs.theme).toBe('light');
  });

  it('an old backup without memory keys does not clear local memory', async () => {
    setPreference('preferences', {
      ...DEFAULT_PREFS,
      memoryText: 'Local memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Local summary',
      memoryUpdatedAt: '2026-10-10T00:00:00.000Z',
    });

    await importHandWritten({ theme: 'light', language: 'system' });

    expect(localPrefs()).toMatchObject({
      theme: 'light',
      memoryText: 'Local memory',
      memoryAntiForgetEnabled: true,
      memoryAntiForgetText: 'Local summary',
      memoryUpdatedAt: '2026-10-10T00:00:00.000Z',
    });
    expect(didUpdatePreferences).not.toHaveBeenCalled();
  });

  it('backup_restores_dark_palette', async () => {
    const known = darkPaletteCase('known_id_applies');
    setPreference('preferences', { ...DEFAULT_PREFS, darkPalette: known.stored as string, darkPaletteSetByUser: true });

    const blob = await exportBackup({ includeApiKeys: false });
    const exported = await readDataJson(blob);
    expect(exported.data.preferences?.darkPalette).toBe(known.stored);

    await resetDB();
    setPreference('preferences', DEFAULT_PREFS);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'palette.oriveo'));
    const result = await executeImport(await generateImportPreview(backupFile, imageEntries), 'importNew');

    expect(result.restoredPreferences).toBe(true);
    expect(localPrefs().darkPalette).toBe(known.stored);
    expect(localPrefs().darkPaletteSetByUser).toBe(true);
    expect(resolveDarkPaletteId(localPrefs().darkPalette)).toBe(known.renders);
  });

  it('backup_without_dark_palette_restores_default_dark', async () => {
    const missing = darkPaletteCase('missing_is_default_and_not_pushed');
    // When unset, the export omits the key
    expect((await readDataJson(await exportBackup({ includeApiKeys: false }))).data.preferences)
      .not.toHaveProperty('darkPalette');
    setPreference('preferences', { ...DEFAULT_PREFS, darkPalette: 'dark-forest', darkPaletteSetByUser: true });

    // An old backup without the field clears it to unset, the same rule as theme being overwritten by a backup
    await importHandWritten({ theme: 'dark', language: 'system' });

    const prefs = localPrefs();
    expect(prefs.darkPalette).toBeUndefined();
    expect(prefs.darkPaletteSetByUser).toBeUndefined();
    expect(resolveDarkPaletteId(prefs.darkPalette)).toBe(missing.renders);
  });

  it('backup_restores_dark_palette_custom_seed', async () => {
    setPreference('preferences', { ...DEFAULT_PREFS, darkPalette: 'custom', darkPaletteSetByUser: true, darkPaletteCustom: '#C084FC' });

    const blob = await exportBackup({ includeApiKeys: false });
    const exported = await readDataJson(blob);
    expect(exported.data.preferences?.darkPalette).toBe('custom');
    expect(exported.data.preferences?.darkPaletteCustom).toBe('#C084FC');

    await resetDB();
    setPreference('preferences', DEFAULT_PREFS);
    const { backupFile, imageEntries } = await parseBackupFile(new File([blob], 'custom.oriveo'));
    await executeImport(await generateImportPreview(backupFile, imageEntries), 'importNew');

    expect(localPrefs().darkPalette).toBe('custom');
    expect(localPrefs().darkPaletteCustom).toBe('#C084FC');
  });

  it('backup_without_dark_palette_custom_clears_seed', async () => {
    expect((await readDataJson(await exportBackup({ includeApiKeys: false }))).data.preferences)
      .not.toHaveProperty('darkPaletteCustom');
    setPreference('preferences', { ...DEFAULT_PREFS, darkPalette: 'custom', darkPaletteSetByUser: true, darkPaletteCustom: '#C084FC' });

    // An old backup without the field = unset; a lowercase seed is uppercased
    await importHandWritten({ theme: 'dark', language: 'system' });
    expect(localPrefs().darkPaletteCustom).toBeUndefined();
    await importHandWritten({ theme: 'dark', darkPalette: 'custom', darkPaletteCustom: '#c084fc', language: 'system' });
    expect(localPrefs().darkPaletteCustom).toBe('#C084FC');
  });
});
