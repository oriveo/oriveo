import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Conversation, Skill } from '@oriveo/shared';
import type { ImportPreview } from '../backup-types';

const mocks = vi.hoisted(() => ({
  activeUID: 'user-A',
  getAllConversations: vi.fn(),
  replaceAllInOneTx: vi.fn(),
  setSessionValue: vi.fn(),
  deleteImage: vi.fn(),
  saveImage: vi.fn(),
  saveUserSkills: vi.fn(),
  setPreference: vi.fn(),
  setPreferences: vi.fn(),
  setLastUsedModelRef: vi.fn(),
  setUserSkills: vi.fn(),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUIDSync: () => mocks.activeUID,
}));

vi.mock('../../infra/storage/idb', () => ({
  getAllConversations: (...args: unknown[]) => mocks.getAllConversations(...args),
  getAllFolders: vi.fn(async () => []),
  getAllProviders: vi.fn(async () => []),
  getAllNotes: vi.fn(async () => []),
  getAllNoteFolders: vi.fn(async () => []),
  putConversation: vi.fn(),
  putFolder: vi.fn(),
  putProvider: vi.fn(),
  putNote: vi.fn(),
  putNoteFolder: vi.fn(),
  mergeAllInOneTx: vi.fn(),
  replaceAllInOneTx: (...args: unknown[]) => mocks.replaceAllInOneTx(...args),
  setSessionValue: (...args: unknown[]) => mocks.setSessionValue(...args),
}));

vi.mock('../../infra/storage/image-store', () => ({
  deleteImage: (...args: unknown[]) => mocks.deleteImage(...args),
  saveImage: (...args: unknown[]) => mocks.saveImage(...args),
}));

vi.mock('../../core/skills/cache', () => ({
  loadCachedUserSkills: vi.fn(async () => []),
  saveUserSkills: (...args: unknown[]) => mocks.saveUserSkills(...args),
}));

vi.mock('../../infra/storage/preferences', () => ({
  getPreference: vi.fn((_key: string, fallback: unknown) => fallback),
  setPreference: (...args: unknown[]) => mocks.setPreference(...args),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: () => ({
    getState: () => ({
      preferences: { theme: 'system', language: 'system', sendShortcut: 'enter' },
      skillUsage: null,
      setPreferences: mocks.setPreferences,
      setLastUsedModelRef: mocks.setLastUsedModelRef,
      setUserSkills: mocks.setUserSkills,
    }),
  }),
}));

vi.mock('../../core/providers/desktop-stream', () => ({ IS_DESKTOP: false }));
vi.mock('../../core/metadata/metadata-client', () => ({ getMetadataSnapshot: () => null }));
vi.mock('../../core/providers/official-model-sync', () => ({
  buildOfficialEnabledModels: () => ({ models: [] }),
}));
vi.mock('../../core/telemetry', () => ({ trackEvent: vi.fn() }));

import { executeImport } from '../backup-import';

function preview(overrides: Partial<ImportPreview['backupFile']['data']> = {}): ImportPreview {
  return {
    backupFile: {
      version: 1,
      createdAt: '2026-07-17T00:00:00.000Z',
      appVersion: '1.0.0',
      platform: 'Web',
      checksum: '',
      containsKeys: false,
      encryptedKeys: null,
      data: {
        conversations: [],
        providers: [],
        preferences: { theme: 'dark', language: 'zh-CN' },
        lastUsedModelRef: { providerID: 'p1', modelID: 'm1' },
        ...overrides,
      },
    },
    imageEntries: new Map(),
  } as ImportPreview;
}

function imageConversation(localImageID: string): Conversation {
  return {
    id: 'c1',
    title: 'Imported',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    draftText: '',
    updatedAt: '2026-07-17T00:00:00.000Z',
    messages: [{
      id: 'm1',
      role: 'user',
      text: 'image',
      state: 'delivered',
      attachments: [{ kind: 'image', localImageID, mimeType: 'image/jpeg', name: 'image.jpg' }],
    }],
  } as Conversation;
}

describe('replaceAll account-switch fail-closed windows', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.activeUID = 'user-A';
    mocks.getAllConversations.mockResolvedValue([]);
    mocks.replaceAllInOneTx.mockResolvedValue(undefined);
    mocks.deleteImage.mockResolvedValue(undefined);
    mocks.saveImage.mockResolvedValue(undefined);
    mocks.saveUserSkills.mockResolvedValue(undefined);
    mocks.setSessionValue.mockResolvedValue(undefined);
  });

  it('binds post-tx image cleanup to captured UID and aborts before skills/preferences after switching', async () => {
    mocks.getAllConversations.mockResolvedValue([imageConversation('old-image')]);
    mocks.deleteImage.mockImplementation(async (_id: string, expectedUID?: string) => {
      expect(expectedUID).toBe('user-A');
      mocks.activeUID = 'user-B';
    });

    await expect(executeImport(preview(), 'replaceAll', undefined, 'user-A'))
      .rejects.toThrow('Backup import storage partition changed from user-A');

    expect(mocks.replaceAllInOneTx).toHaveBeenCalledWith(expect.anything(), 'user-A');
    expect(mocks.saveUserSkills).not.toHaveBeenCalled();
    expect(mocks.setPreference).not.toHaveBeenCalled();
    expect(mocks.setSessionValue).not.toHaveBeenCalled();
  });

  it('binds skills cache to captured UID and never updates the new account Store', async () => {
    const skill = { id: 'skill-1', name: 'Imported skill' } as Skill;
    mocks.saveUserSkills.mockImplementation(async (_skills: Skill[], expectedUID?: string) => {
      expect(expectedUID).toBe('user-A');
      mocks.activeUID = 'user-B';
    });

    await expect(executeImport(preview({ skills: [skill] }), 'replaceAll', undefined, 'user-A'))
      .rejects.toThrow('Backup import storage partition changed from user-A');

    expect(mocks.setUserSkills).not.toHaveBeenCalled();
    expect(mocks.setPreference).not.toHaveBeenCalled();
    expect(mocks.setSessionValue).not.toHaveBeenCalled();
  });

  it('binds last-used session write to captured UID and blocks the stale Store update', async () => {
    mocks.setSessionValue.mockImplementation(async (
      _key: string,
      _value: unknown,
      expectedUID?: string,
    ) => {
      expect(expectedUID).toBe('user-A');
      mocks.activeUID = 'user-B';
    });

    await expect(executeImport(preview(), 'replaceAll', undefined, 'user-A'))
      .rejects.toThrow('Backup import storage partition changed from user-A');

    expect(mocks.setPreference).toHaveBeenCalled();
    expect(mocks.setLastUsedModelRef).not.toHaveBeenCalled();
  });
});
