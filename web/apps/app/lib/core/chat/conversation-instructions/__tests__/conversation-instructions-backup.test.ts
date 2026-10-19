import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Conversation } from '@oriveo/shared';
import type { ImportPreview } from '../../../../backup/backup-types';

const mocks = vi.hoisted(() => ({
  getAllConversations: vi.fn(),
  putConversation: vi.fn(),
  mergeAllInOneTx: vi.fn(),
  replaceAllInOneTx: vi.fn(),
}));

vi.mock('../../../../infra/storage/partition', () => ({
  getActiveUIDSync: () => 'user-A',
}));

vi.mock('../../../../infra/storage/idb', () => ({
  getAllConversations: (...args: unknown[]) => mocks.getAllConversations(...args),
  getAllFolders: vi.fn(async () => []),
  getAllProviders: vi.fn(async () => []),
  getAllNotes: vi.fn(async () => []),
  getAllNoteFolders: vi.fn(async () => []),
  putConversation: (...args: unknown[]) => mocks.putConversation(...args),
  putFolder: vi.fn(),
  putProvider: vi.fn(),
  putNote: vi.fn(),
  putNoteFolder: vi.fn(),
  mergeAllInOneTx: (...args: unknown[]) => mocks.mergeAllInOneTx(...args),
  replaceAllInOneTx: (...args: unknown[]) => mocks.replaceAllInOneTx(...args),
  setSessionValue: vi.fn(),
}));

vi.mock('../../../../infra/storage/memory-item-store', () => ({
  getAllMemoryItemRows: vi.fn(async () => []),
  getMemoryItemRow: vi.fn(async () => undefined),
  putMemoryItemRows: vi.fn(),
}));

vi.mock('../../../../infra/storage/image-store', () => ({
  deleteImage: vi.fn(),
  saveImage: vi.fn(),
}));

vi.mock('../../../../core/skills/cache', () => ({
  loadCachedUserSkills: vi.fn(async () => []),
  saveUserSkills: vi.fn(),
}));

vi.mock('../../../../infra/storage/preferences', () => ({
  getPreference: vi.fn((_key: string, fallback: unknown) => fallback),
  setPreference: vi.fn(),
}));

vi.mock('../../../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: () => null,
}));

vi.mock('../../../../core/metadata/metadata-client', () => ({
  getMetadataSnapshot: () => null,
  ensureProviderCatalogs: vi.fn(async () => {}),
}));
vi.mock('../../../../core/providers/official-model-sync', () => ({
  buildOfficialEnabledModels: () => ({ models: [] }),
}));
vi.mock('../../../../core/telemetry', () => ({ trackEvent: vi.fn() }));

import { executeImport } from '../../../../backup/backup-import';

function makeConversation(overrides: Partial<Conversation> = {}): Conversation {
  return {
    id: 'c1',
    title: 'Backup Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    providerKind: 'openAI',
    modelID: 'm1',
    previewText: 'Hello',
    estimatedCost: 0,
    isDraft: false,
    messages: [],
    draftText: '',
    updatedAt: '2026-10-15T00:00:00.000Z',
    createdAt: '2026-10-15T00:00:00.000Z',
    ...overrides,
  } as Conversation;
}

function preview(conversations: unknown[]): ImportPreview {
  return {
    backupFile: {
      version: 1,
      createdAt: '2026-10-15T00:00:00.000Z',
      appVersion: '1.0.0',
      platform: 'Web',
      checksum: '',
      containsKeys: false,
      encryptedKeys: null,
      data: { conversations, providers: [] },
    },
    imageEntries: new Map(),
  } as unknown as ImportPreview;
}

/** Export is whole-object serialization: a JSON round trip is the conversation DTO in the backup file. */
function throughBackup(conv: Conversation): unknown {
  return JSON.parse(JSON.stringify(conv));
}

function putConversations(): Conversation[] {
  return mocks.putConversation.mock.calls.map((call) => call[0] as Conversation);
}

describe('conversation instructions in backup import', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getAllConversations.mockResolvedValue([]);
    mocks.putConversation.mockResolvedValue(undefined);
    mocks.mergeAllInOneTx.mockResolvedValue(undefined);
    mocks.replaceAllInOneTx.mockResolvedValue(undefined);
  });

  it('backup_roundtrip_keeps_instructions', async () => {
    const conv = makeConversation({ instructions: '  Reply in French.\n' });

    await executeImport(preview([throughBackup(conv)]), 'importNew');
    expect(putConversations()[0]?.instructions).toBe('  Reply in French.\n');

    await executeImport(preview([throughBackup(conv)]), 'replaceAll');
    const replaced = mocks.replaceAllInOneTx.mock.calls[0]?.[0] as { conversations: Conversation[] };
    expect(replaced.conversations[0]?.instructions).toBe('  Reply in French.\n');

    // Normalization: over-long text is cut to 8000 code points.
    const long = makeConversation({ id: 'c2', instructions: 'x'.repeat(8001) });
    await executeImport(preview([throughBackup(long)]), 'importNew');
    expect([...(putConversations()[1]?.instructions ?? '')]).toHaveLength(8000);
  });

  it('old_backup_defaults_empty', async () => {
    const { instructions: _omit, ...legacy } = makeConversation();
    await executeImport(preview([legacy]), 'importNew');
    expect(putConversations()[0]?.instructions).toBe('');

    const blank = makeConversation({ id: 'c2', instructions: ' \n\t ' });
    await executeImport(preview([throughBackup(blank)]), 'replaceAll');
    const replaced = mocks.replaceAllInOneTx.mock.calls[0]?.[0] as { conversations: Conversation[] };
    expect(replaced.conversations[0]?.instructions).toBe('');
  });

  it('backup_merge_takes_instructions_with_title', async () => {
    const backup = makeConversation({
      title: 'Backup Title',
      instructions: 'Backup rules',
      updatedAt: '2026-10-15T00:00:00.000Z',
    });

    // Backup is newer: both title and instructions come from the backup.
    mocks.getAllConversations.mockResolvedValue([
      makeConversation({ title: 'Local Title', instructions: 'Local rules', updatedAt: '2026-10-14T00:00:00.000Z' }),
    ]);
    await executeImport(preview([throughBackup(backup)]), 'merge');
    let merged = (mocks.mergeAllInOneTx.mock.calls[0]?.[0] as { conversations: Conversation[] }).conversations[0];
    expect(merged?.title).toBe('Backup Title');
    expect(merged?.instructions).toBe('Backup rules');

    // Local is newer: both come from local (including a local clear).
    mocks.getAllConversations.mockResolvedValue([
      makeConversation({ title: 'Local Title', instructions: '', updatedAt: '2026-10-16T00:00:00.000Z' }),
    ]);
    await executeImport(preview([throughBackup(backup)]), 'merge');
    merged = (mocks.mergeAllInOneTx.mock.calls[1]?.[0] as { conversations: Conversation[] }).conversations[0];
    expect(merged?.title).toBe('Local Title');
    expect(merged?.instructions).toBe('');
  });
});
