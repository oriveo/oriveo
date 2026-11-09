// @vitest-environment node
// Node Blobs keep stream() / slice(); the zip reader reads the File in place.
import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import type { Attachment, ChatMessage, Conversation } from '@oriveo/shared';
import type { BackupFile } from '../backup-types';
import { getPartitionDB, resetDBConnection } from '../../infra/storage/idb';
import { deleteImage, listImageIds, loadImageData, loadThumbnailData, resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';
import { canonicalJSON, parseBackupFile } from '../backup-format';
import { executeImport, generateImportPreview } from '../backup-import';
import { sha256hex } from '../backup-crypto';

const UID = 'uid-stream';
const MIB = 1024 * 1024;
const ENTRY_LIMIT = MIB;

const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/**
 * Deterministic PNG-headed bytes, distinct per seed. Pseudo-random (xorshift32) so DEFLATE cannot shrink them:
 * the archive stays as large as the images and the zip reader has to read it in ranges.
 */
function imageBytes(size: number, seed: number): Uint8Array {
  const bytes = new Uint8Array(size);
  bytes.set(PNG);
  let state = (seed * 2654435761) >>> 0 || 1;
  for (let i = PNG.length; i < size; i++) {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    bytes[i] = state & 0xff;
  }
  return bytes;
}

function conversationWithImages(id: string, imageIds: string[]): Conversation {
  const attachments: Attachment[] = imageIds.map((imageId, i) => ({
    id: `${id}-att-${i}`, kind: 'image', fileName: `${i}.png`, mimeType: 'image/png', localImageID: imageId,
  }));
  const message = {
    id: `${id}-m1`, role: 'user', text: 'hi', createdAt: new Date().toISOString(), attachments,
  } as unknown as ChatMessage;
  return {
    id, title: 'T', hasCustomTitle: false, providerID: 'p1', modelID: 'm1', previewText: 'hi',
    estimatedCost: 0, isDraft: false, messages: [message], draftText: '', updatedAt: new Date().toISOString(),
  };
}

interface BuiltBackup {
  file: File;
  bytes: Uint8Array;
  chatImages: Map<string, { original: Uint8Array; thumb: Uint8Array }>;
}

/** An archive entry absent from attachmentChecksums; `store` writes it STORED instead of DEFLATE. */
interface ExtraEntry {
  name: string;
  bytes: Uint8Array;
  store?: boolean;
}

/**
 * Writes a version-2 backup zip: attachments/<att.id>[.thumb].png entries, then any unlisted extra entries.
 */
async function buildBackup(chatImageSizes: number[], extras: ExtraEntry[] = []): Promise<BuiltBackup> {
  const zip = new JSZip();
  const checksums: Record<string, string> = {};
  const imageIds = chatImageSizes.map((_, i) => `img-${i}`);
  const conversation = conversationWithImages('conv-stream', imageIds);
  const attachments = conversation.messages[0].attachments!;
  const chatImages = new Map<string, { original: Uint8Array; thumb: Uint8Array }>();
  for (const [i, size] of chatImageSizes.entries()) {
    const original = imageBytes(size, i * 2 + 1);
    const thumb = imageBytes(size, i * 2 + 2);
    const name = `${attachments[i].id}.png`;
    const thumbName = `${attachments[i].id}.thumb.png`;
    zip.file(`attachments/${name}`, original);
    zip.file(`attachments/${thumbName}`, thumb);
    checksums[name] = `sha256:${await sha256hex(original)}`;
    checksums[thumbName] = `sha256:${await sha256hex(thumb)}`;
    chatImages.set(imageIds[i], { original, thumb });
  }

  const data = { providers: [], conversations: [conversation] };
  const backup: BackupFile = {
    version: 2,
    createdAt: '2026-11-08T00:00:00.000Z',
    appVersion: '1.0.0',
    platform: 'Web',
    checksum: `sha256:${await sha256hex(new TextEncoder().encode(canonicalJSON(data)))}`,
    containsKeys: false,
    data: data as unknown as BackupFile['data'],
    attachmentChecksums: checksums,
    encryptedKeys: null,
  };
  const archive = new JSZip();
  archive.file('data.json', JSON.stringify(backup));
  for (const [name, entry] of Object.entries(zip.files)) {
    if (!entry.dir) archive.file(name, await entry.async('uint8array'));
  }
  for (const extra of extras) {
    archive.file(extra.name, extra.bytes, extra.store ? { compression: 'STORE' } : {});
  }
  const bytes = await archive.generateAsync({ type: 'uint8array', compression: 'DEFLATE', compressionOptions: { level: 1 } });
  return { file: fileOf(bytes), bytes, chatImages };
}

const fileOf = (bytes: Uint8Array) => new File([bytes as Uint8Array<ArrayBuffer>], 'backup.oriveo');

interface ZipEntryOffsets {
  /** Central directory record start. */
  central: number;
  /** Local file header start. */
  local: number;
  /** First byte of the entry's stored data. */
  data: number;
}

/** Locates an entry's central directory record, local header and data in an archive without a zip64 directory. */
function zipEntryOffsets(bytes: Uint8Array, name: string): ZipEntryOffsets {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let eocd = bytes.length - 22;
  while (eocd >= 0 && view.getUint32(eocd, true) !== 0x06054b50) eocd--;
  let cursor = view.getUint32(eocd + 16, true);
  const decoder = new TextDecoder();
  while (view.getUint32(cursor, true) === 0x02014b50) {
    const nameLength = view.getUint16(cursor + 28, true);
    const extraLength = view.getUint16(cursor + 30, true);
    const commentLength = view.getUint16(cursor + 32, true);
    const entryName = decoder.decode(bytes.subarray(cursor + 46, cursor + 46 + nameLength));
    if (entryName === name) {
      const local = view.getUint32(cursor + 42, true);
      const data = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
      return { central: cursor, local, data };
    }
    cursor += 46 + nameLength + extraLength + commentLength;
  }
  throw new Error(`entry ${name} not found`);
}

/** Seeds one local conversation so a destructive import attempt would be visible. */
async function seedLocalConversation(): Promise<string> {
  const local = conversationWithImages('conv-local-keep', []);
  await (await getPartitionDB()).put('conversations', local as never);
  return local.id;
}

async function previewOf(file: File, options: Parameters<typeof parseBackupFile>[2]) {
  const { backupFile, imageEntries } = await parseBackupFile(file, undefined, options);
  return generateImportPreview(backupFile, imageEntries);
}

const bytesOf = async (blob: Blob | null) => (blob ? new Uint8Array(await blob.arrayBuffer()) : null);

describe('backup streamed import', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await setActiveUID(UID);
    const db = await getPartitionDB();
    await db.clear('conversations');
    for (const id of await listImageIds()) await deleteImage(id);
  });

  it('backup_streamImport_totalOverOldBudget', async () => {
    const size = Math.round(0.9 * MIB);
    const built = await buildBackup([size, size, size, size, size]);
    const wholeRead = vi.spyOn(built.file, 'arrayBuffer');

    const { backupFile, imageEntries } = await parseBackupFile(built.file, undefined, { maxEntryBytes: ENTRY_LIMIT });
    const preview = await generateImportPreview(backupFile, imageEntries);
    expect(wholeRead, 'the zip branch must not read the whole file').not.toHaveBeenCalled();
    expect(preview.attachmentChecksumIssues).toEqual([]);
    expect(preview.checksumValid).toBe(true);

    const result = await executeImport(preview, 'importNew', undefined, UID);
    expect(wholeRead).not.toHaveBeenCalled();
    expect(result.imagesRestored).toBe(built.chatImages.size);
    for (const [imageId, expected] of built.chatImages) {
      expect(await bytesOf(await loadImageData(imageId, UID)), imageId).toEqual(expected.original);
      expect(await bytesOf(await loadThumbnailData(imageId)), `${imageId} thumb`).toEqual(expected.thumb);
    }
  }, 60_000);

  it('backup_streamImport_entryOverLimitRejected', async () => {
    const built = await buildBackup([Math.round(1.5 * MIB)]);
    const wholeRead = vi.spyOn(built.file, 'arrayBuffer');

    const preview = (async () => {
      const { backupFile, imageEntries } = await parseBackupFile(built.file, undefined, { maxEntryBytes: ENTRY_LIMIT });
      return generateImportPreview(backupFile, imageEntries);
    })();
    await expect(preview).rejects.toThrow('RESOURCE_LIMIT_EXCEEDED');
    expect(wholeRead).not.toHaveBeenCalled();
  }, 60_000);

  it('backup_streamImport_unlistedEntryOverLimitRejectedAtPreview', async () => {
    const built = await buildBackup([Math.round(0.2 * MIB)], [
      { name: 'attachments/unlisted.png', bytes: imageBytes(Math.round(1.5 * MIB), 7) },
    ]);
    const localId = await seedLocalConversation();

    let failure: unknown = null;
    try {
      const preview = await previewOf(built.file, { maxEntryBytes: ENTRY_LIMIT });
      // A preview that lets the archive through must not leave replaceAll to fail half way.
      await executeImport(preview, 'replaceAll', undefined, UID).catch(() => undefined);
    } catch (error) {
      failure = error;
    }
    expect((failure as Error | null)?.message, 'preview must reject the unlisted oversized entry').toBe('RESOURCE_LIMIT_EXCEEDED');
    const ids = (await (await getPartitionDB()).getAll('conversations')).map((c) => c.id);
    expect(ids, 'local data before replaceAll must be untouched').toEqual([localId]);
  }, 60_000);

  it('backup_streamImport_crcMismatchRejected', async () => {
    const built = await buildBackup([Math.round(0.1 * MIB)], [
      { name: 'attachments/stored.png', bytes: imageBytes(4096, 11), store: true },
    ]);
    const bytes = built.bytes.slice();
    bytes[zipEntryOffsets(bytes, 'attachments/stored.png').data + 100] ^= 0xff;

    await expect(previewOf(fileOf(bytes), { maxEntryBytes: ENTRY_LIMIT })).rejects.toThrow('INVALID_FORMAT');
  }, 60_000);

  it('backup_streamImport_entryCountOverLimitRejected', async () => {
    // data.json, one original, one thumb and the attachments folder entry JSZip writes: over a cap of three.
    const built = await buildBackup([4096]);

    await expect(previewOf(built.file, { maxEntryBytes: ENTRY_LIMIT, maxEntryCount: 3 }))
      .rejects.toThrow('RESOURCE_LIMIT_EXCEEDED');
    const accepted = await previewOf(built.file, { maxEntryBytes: ENTRY_LIMIT });
    expect(accepted.attachmentChecksumIssues).toEqual([]);
  }, 60_000);

  it('backup_streamImport_headerUnderstatesRejected', async () => {
    const name = 'attachments/understated.png';
    const built = await buildBackup([Math.round(0.1 * MIB)], [
      { name, bytes: imageBytes(Math.round(1.5 * MIB), 13) },
    ]);
    const bytes = built.bytes.slice();
    const offsets = zipEntryOffsets(bytes, name);
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    view.setUint32(offsets.central + 24, 1024, true);
    view.setUint32(offsets.local + 22, 1024, true);

    // The inflater stops as soon as the output passes the declared size, so the lie is caught as a damaged entry
    // long before the real 1.5 MiB is produced; the understated header cannot carry the entry past the preview.
    await expect(previewOf(fileOf(bytes), { maxEntryBytes: ENTRY_LIMIT })).rejects.toThrow('INVALID_FORMAT');
  }, 60_000);

  it('backup_streamImport_jsonOverLimitRejected', async () => {
    const backup = {
      version: 2, createdAt: '2026-11-08T00:00:00.000Z', appVersion: '1.0.0', platform: 'Web', checksum: '',
      containsKeys: false, encryptedKeys: null,
      data: { providers: [], conversations: [], notes: [{ padding: 'x'.repeat(Math.round(1.5 * MIB)) }] },
    };
    const file = new File([JSON.stringify(backup)], 'backup.json');
    const wholeRead = vi.spyOn(file, 'arrayBuffer');

    // Compared as a message so a resolved parse does not dump the padded backup into the report.
    const outcome = await parseBackupFile(file, undefined, { maxEntryBytes: ENTRY_LIMIT })
      .then(() => 'resolved', (error: Error) => error.message);
    expect(outcome).toBe('RESOURCE_LIMIT_EXCEEDED');
    expect(wholeRead, 'an oversized plain JSON must be refused before it is read whole').not.toHaveBeenCalled();
  }, 60_000);
});
