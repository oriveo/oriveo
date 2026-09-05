/**
 * Naming contract regression for image attachment entries.
 *
 * Both axes of attachments/<name>.<ext> once differed between clients: iOS and Android named entries by
 * attachment.id while web used localImageID, and iOS derived the extension from mimeType while Android
 * and web always wrote .jpg. Restoring an archive from another client could not find the entry, and the
 * restore path has no base64 fallback, so images vanished silently.
 * Export now settles on attachment.id, and import falls back across name candidates x extension
 * candidates so archives of every style restore.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import type { Conversation } from '@oriveo/shared';
import type { BackupFile, ImportPreview } from '../backup-types';

const ATTACHMENT_ID = 'ATT-0001';
const LOCAL_IMAGE_ID = 'IMG-0001';
const IMAGE_BYTES = new Uint8Array([1, 2, 3, 4]);
const THUMB_BYTES = new Uint8Array([9, 8, 7]);

const mocks = vi.hoisted(() => ({
  getAllConversations: vi.fn(),
  loadImageData: vi.fn(),
  loadThumbnailData: vi.fn(),
  saveImage: vi.fn(),
  deleteImage: vi.fn(),
  putConversation: vi.fn(),
}));

vi.mock('../../infra/storage/partition', () => ({
  getActiveUIDSync: () => 'guest',
}));

vi.mock('../../infra/storage/idb', () => ({
  getAllConversations: (...args: unknown[]) => mocks.getAllConversations(...args),
  getAllFolders: vi.fn(async () => []),
  getAllProviders: vi.fn(async () => []),
  getAllNotes: vi.fn(async () => []),
  getAllNoteFolders: vi.fn(async () => []),
  getSessionValue: vi.fn(async () => null),
  putConversation: (...args: unknown[]) => mocks.putConversation(...args),
  putFolder: vi.fn(),
  putProvider: vi.fn(),
  putNote: vi.fn(),
  putNoteFolder: vi.fn(),
  mergeAllInOneTx: vi.fn(),
  replaceAllInOneTx: vi.fn(),
  setSessionValue: vi.fn(),
}));

vi.mock('../../infra/storage/image-store', () => ({
  loadImageData: (...args: unknown[]) => mocks.loadImageData(...args),
  loadThumbnailData: (...args: unknown[]) => mocks.loadThumbnailData(...args),
  saveImage: (...args: unknown[]) => mocks.saveImage(...args),
  deleteImage: (...args: unknown[]) => mocks.deleteImage(...args),
}));

vi.mock('../../core/skills/cache', () => ({
  loadCachedUserSkills: vi.fn(async () => []),
  saveUserSkills: vi.fn(),
}));

vi.mock('../../infra/storage/preferences', () => ({
  getPreference: vi.fn((_key: string, fallback: unknown) => fallback),
  setPreference: vi.fn(),
}));

vi.mock('../../../providers/StoreProvider', () => ({
  tryGetVanillaStore: () => null,
}));

vi.mock('../../core/providers/desktop-stream', () => ({ IS_DESKTOP: false }));
vi.mock('../../core/metadata/metadata-client', () => ({ getMetadataSnapshot: () => null }));
vi.mock('../../core/providers/official-model-sync', () => ({
  buildOfficialEnabledModels: () => ({ models: [] }),
}));
vi.mock('../../core/telemetry', () => ({ trackEvent: vi.fn() }));

/* ── jsdom polyfill: fall back to FileReader when Blob.arrayBuffer is missing ── */

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

/* ── crypto.subtle polyfill (needed for the sha256 checksum) ── */

const { subtle } = globalThis.crypto ?? {};
if (!subtle || !subtle.digest) {
  const nodeCrypto = await import('node:crypto');
  Object.defineProperty(globalThis, 'crypto', {
    value: nodeCrypto.webcrypto,
    writable: true,
    configurable: true,
  });
}

const { exportBackup } = await import('../backup-export');
const { executeImport } = await import('../backup-import');

/* ── Test data ─────────────────────────────────────────── */

function imageConversation(mimeType = 'image/jpeg'): Conversation {
  return {
    id: 'conv-image',
    title: 'Image Chat',
    hasCustomTitle: false,
    providerID: 'p1',
    modelID: 'm1',
    previewText: '',
    estimatedCost: 0,
    isDraft: false,
    draftText: '',
    updatedAt: '2026-08-24T00:00:00.000Z',
    messages: [{
      id: 'msg-image',
      role: 'user',
      text: 'image',
      state: 'delivered',
      createdAt: '2026-08-24T00:00:00.000Z',
      attachments: [{
        id: ATTACHMENT_ID,
        kind: 'image',
        fileName: 'photo.jpg',
        mimeType,
        localImageID: LOCAL_IMAGE_ID,
      }],
    }],
  } as unknown as Conversation;
}

function previewWith(imageEntries: Map<string, Uint8Array>, mimeType = 'image/jpeg'): ImportPreview {
  const backupFile: BackupFile = {
    version: 1,
    createdAt: '2026-08-24T00:00:00.000Z',
    appVersion: '1.0.0',
    platform: 'Web',
    checksum: '',
    containsKeys: false,
    encryptedKeys: null,
    data: { providers: [], conversations: [imageConversation(mimeType)] },
  };
  return { backupFile, imageEntries } as ImportPreview;
}

async function blobBytes(blob: Blob): Promise<Uint8Array> {
  return new Uint8Array(await blob.arrayBuffer());
}

describe('backup image attachment entry naming', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.getAllConversations.mockResolvedValue([]);
    mocks.putConversation.mockResolvedValue(undefined);
    mocks.saveImage.mockResolvedValue(undefined);
    mocks.deleteImage.mockResolvedValue(undefined);
    mocks.loadImageData.mockResolvedValue(null);
    mocks.loadThumbnailData.mockResolvedValue(null);
  });

  it('names exported entries by attachment.id rather than localImageID', async () => {
    mocks.getAllConversations.mockResolvedValue([imageConversation()]);
    mocks.loadImageData.mockResolvedValue(new Blob([IMAGE_BYTES]));
    mocks.loadThumbnailData.mockResolvedValue(new Blob([THUMB_BYTES]));

    const blob = await exportBackup({ includeApiKeys: false });
    const zip = await JSZip.loadAsync(await blob.arrayBuffer());

    expect(zip.file(`attachments/${ATTACHMENT_ID}.jpg`)).not.toBeNull();
    expect(zip.file(`attachments/${ATTACHMENT_ID}.thumb.jpg`)).not.toBeNull();
    expect(zip.file(`attachments/${LOCAL_IMAGE_ID}.jpg`)).toBeNull();
    expect(zip.file(`attachments/${LOCAL_IMAGE_ID}.thumb.jpg`)).toBeNull();

    // The attachmentChecksums keys must stay in sync with the entry names, or the import preview reports corrupt attachments
    const dataJson = JSON.parse(await zip.file('data.json')!.async('string')) as BackupFile;
    expect(Object.keys(dataJson.attachmentChecksums ?? {}).sort()).toEqual([
      `${ATTACHMENT_ID}.jpg`,
      `${ATTACHMENT_ID}.thumb.jpg`,
    ]);
  });

  it('restores images from an archive that names entries by attachment.id', async () => {
    const result = await executeImport(previewWith(new Map([
      [`${ATTACHMENT_ID}.jpg`, IMAGE_BYTES],
      [`${ATTACHMENT_ID}.thumb.jpg`, THUMB_BYTES],
    ])), 'importNew');

    expect(result.imagesRestored).toBe(1);
    expect(mocks.saveImage).toHaveBeenCalledTimes(1);
    const [id, image, thumb] = mocks.saveImage.mock.calls[0];
    expect(id).toBe(LOCAL_IMAGE_ID);
    expect(await blobBytes(image as Blob)).toEqual(IMAGE_BYTES);
    expect(await blobBytes(thumb as Blob)).toEqual(THUMB_BYTES);
  });

  it('restores images from an older archive that names entries by localImageID', async () => {
    const result = await executeImport(previewWith(new Map([
      [`${LOCAL_IMAGE_ID}.jpg`, IMAGE_BYTES],
      [`${LOCAL_IMAGE_ID}.thumb.jpg`, THUMB_BYTES],
    ])), 'importNew');

    expect(result.imagesRestored).toBe(1);
    expect(mocks.saveImage).toHaveBeenCalledTimes(1);
    const [id, image, thumb] = mocks.saveImage.mock.calls[0];
    expect(id).toBe(LOCAL_IMAGE_ID);
    expect(await blobBytes(image as Blob)).toEqual(IMAGE_BYTES);
    expect(await blobBytes(thumb as Blob)).toEqual(THUMB_BYTES);
  });

  it('restores images from an archive using attachment.id naming with a mime-derived .png extension', async () => {
    // Exports that derive the extension from mimeType name a PNG entry <id>.png, so looking only for .jpg misses it
    const result = await executeImport(previewWith(new Map([
      [`${ATTACHMENT_ID}.png`, IMAGE_BYTES],
      [`${ATTACHMENT_ID}.thumb.png`, THUMB_BYTES],
    ]), 'image/png'), 'importNew');

    expect(result.imagesRestored).toBe(1);
    const [id, image, thumb] = mocks.saveImage.mock.calls[0];
    expect(id).toBe(LOCAL_IMAGE_ID);
    expect(await blobBytes(image as Blob)).toEqual(IMAGE_BYTES);
    expect(await blobBytes(thumb as Blob)).toEqual(THUMB_BYTES);
  });

  it('restores a PNG attachment from an archive that always writes .jpg', async () => {
    // Some exports write .jpg whatever the mime type, so the mime-derived extension must fall back to jpg
    const result = await executeImport(previewWith(new Map([
      [`${ATTACHMENT_ID}.jpg`, IMAGE_BYTES],
      [`${ATTACHMENT_ID}.thumb.jpg`, THUMB_BYTES],
    ]), 'image/png'), 'importNew');

    expect(result.imagesRestored).toBe(1);
    const [, image, thumb] = mocks.saveImage.mock.calls[0];
    expect(await blobBytes(image as Blob)).toEqual(IMAGE_BYTES);
    expect(await blobBytes(thumb as Blob)).toEqual(THUMB_BYTES);
  });

  it('restores nothing when neither naming matches, rather than silently writing the wrong image', async () => {
    const result = await executeImport(previewWith(new Map([
      ['SOMETHING-ELSE.jpg', IMAGE_BYTES],
    ])), 'importNew');

    expect(result.imagesRestored).toBe(0);
    expect(mocks.saveImage).not.toHaveBeenCalled();
  });
});
