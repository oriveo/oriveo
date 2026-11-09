// @vitest-environment node
// Node Blobs keep stream() / slice(); the export is written entry by entry into a WritableStream.
import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import JSZip from 'jszip';
import { BlobReader, Uint8ArrayWriter, ZipReader, type FileEntry } from '@zip.js/zip.js';
import type { Attachment, ChatMessage, Conversation } from '@oriveo/shared';
import type { BackupFile } from '../backup-types';
import { getPartitionDB, resetDBConnection } from '../../infra/storage/idb';
import { deleteImage, listImageIds, loadImageData, loadThumbnailData, resetImageDBConnection } from '../../infra/storage/image-store';
import { setActiveUID } from '../../infra/storage/partition';
import { BACKUP_VERSION, canonicalJSON, parseBackupFile } from '../backup-format';
import { executeImport, generateImportPreview } from '../backup-import';
import { sha256hex } from '../backup-crypto';
import { exportBackup } from '../backup-export';

const UID = 'uid-stream-export';
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const IMAGE_ID = 'img-export-0';

/** Deterministic PNG-headed pseudo-random bytes (xorshift32), distinct per seed. */
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

function conversationWithImage(id: string, imageId: string): Conversation {
  const attachments: Attachment[] = [{
    id: `${id}-att-0`, kind: 'image', fileName: '0.png', mimeType: 'image/png', localImageID: imageId,
  }];
  const message = {
    id: `${id}-m1`, role: 'user', text: 'hi', createdAt: new Date().toISOString(), attachments,
  } as unknown as ChatMessage;
  return {
    id, title: 'T', hasCustomTitle: false, providerID: 'p1', modelID: 'm1', previewText: 'hi',
    estimatedCost: 0, isDraft: false, messages: [message], draftText: '', updatedAt: new Date().toISOString(),
  };
}

interface Seed {
  attachmentId: string;
  chatOriginal: Uint8Array;
  chatThumb: Uint8Array;
}

/** Seeds local state through the production import: one chat image (original + thumbnail). */
async function seedLocal(): Promise<Seed> {
  const conversation = conversationWithImage('conv-export', IMAGE_ID);
  const attachmentId = conversation.messages[0].attachments![0].id;
  const chatOriginal = imageBytes(48 * 1024, 1);
  const chatThumb = imageBytes(8 * 1024, 2);
  const entries: Record<string, Uint8Array> = {
    [`attachments/${attachmentId}.png`]: chatOriginal,
    [`attachments/${attachmentId}.thumb.png`]: chatThumb,
  };
  const checksums: Record<string, string> = {};
  for (const [name, bytes] of Object.entries(entries)) {
    checksums[name.replace(/^attachments\//, '')] = `sha256:${await sha256hex(bytes)}`;
  }
  const data = { providers: [], conversations: [conversation] };
  const backup: BackupFile = {
    version: BACKUP_VERSION,
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
  for (const [name, bytes] of Object.entries(entries)) archive.file(name, bytes);
  const zipped = await archive.generateAsync({ type: 'uint8array' });
  const { backupFile, imageEntries } = await parseBackupFile(new File([zipped as Uint8Array<ArrayBuffer>], 'seed.oriveo'));
  await executeImport(await generateImportPreview(backupFile, imageEntries), 'importNew', undefined, UID);
  return { attachmentId, chatOriginal, chatThumb };
}

async function clearLocal() {
  const db = await getPartitionDB();
  await db.clear('conversations');
  for (const id of await listImageIds()) await deleteImage(id);
}

const bytesOf = async (blob: Blob | null) => (blob ? new Uint8Array(await blob.arrayBuffer()) : null);

describe('backup streamed export', () => {
  beforeEach(async () => {
    vi.restoreAllMocks();
    resetDBConnection();
    resetImageDBConnection();
    await setActiveUID(UID);
    await clearLocal();
  });

  it('backup_streamExport_roundTrip', async () => {
    const seed = await seedLocal();

    const generateAsync = vi.spyOn(JSZip.prototype, 'generateAsync');
    const chunks: Uint8Array[] = [];
    const destination = new WritableStream<Uint8Array>({
      write(chunk) { chunks.push(new Uint8Array(chunk)); },
    });

    await exportBackup({ includeApiKeys: false }, destination);

    expect(generateAsync, 'export must not build the whole archive with JSZip').not.toHaveBeenCalled();
    expect(chunks.length, 'the archive arrives in several chunks').toBeGreaterThan(1);

    const file = new File(chunks as Uint8Array<ArrayBuffer>[], 'export.oriveo');
    const entries = (await new ZipReader(new BlobReader(file)).getEntries())
      .filter((entry): entry is FileEntry => !entry.directory);
    const names = entries.map((entry) => entry.filename);
    expect(names).toEqual([
      'data.json',
      `attachments/${seed.attachmentId}.jpg`,
      `attachments/${seed.attachmentId}.thumb.jpg`,
    ]);

    const expected = new Map<string, Uint8Array>([
      [`attachments/${seed.attachmentId}.jpg`, seed.chatOriginal],
      [`attachments/${seed.attachmentId}.thumb.jpg`, seed.chatThumb],
    ]);
    for (const entry of entries.slice(1)) {
      const bytes = await entry.getData(new Uint8ArrayWriter());
      expect(bytes, entry.filename).toEqual(expected.get(entry.filename));
    }

    const { backupFile, imageEntries } = await parseBackupFile(file);
    expect(Object.keys(backupFile.attachmentChecksums ?? {}).sort()).toEqual([
      `${seed.attachmentId}.jpg`,
      `${seed.attachmentId}.thumb.jpg`,
    ].sort());
    const preview = await generateImportPreview(backupFile, imageEntries);
    expect(preview.checksumValid).toBe(true);
    expect(preview.attachmentChecksumIssues).toEqual([]);

    await clearLocal();
    await executeImport(preview, 'importNew', undefined, UID);
    expect(await bytesOf(await loadImageData(IMAGE_ID, UID))).toEqual(seed.chatOriginal);
    expect(await bytesOf(await loadThumbnailData(IMAGE_ID))).toEqual(seed.chatThumb);
  }, 60_000);

  it('backup_streamExport_noDataDescriptorOnStored', async () => {
    // Released Android ZipInputStream rejects STORED entries with general-purpose bit 3 (data descriptor).
    await seedLocal();
    const chunks: Uint8Array[] = [];
    const destination = new WritableStream<Uint8Array>({
      write(chunk) { chunks.push(new Uint8Array(chunk)); },
    });
    await exportBackup({ includeApiKeys: false }, destination);

    const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const view = new DataView(bytes.buffer);

    let eocd = -1;
    for (let i = bytes.length - 22; i >= 0; i--) {
      if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    expect(eocd, 'end of central directory record').toBeGreaterThanOrEqual(0);
    const count = view.getUint16(eocd + 10, true);
    let cursor = view.getUint32(eocd + 16, true);
    let storedCount = 0;
    for (let n = 0; n < count; n++) {
      expect(view.getUint32(cursor, true), 'central directory signature').toBe(0x02014b50);
      const method = view.getUint16(cursor + 10, true);
      const crc = view.getUint32(cursor + 16, true);
      const compressedSize = view.getUint32(cursor + 20, true);
      const size = view.getUint32(cursor + 24, true);
      const nameLength = view.getUint16(cursor + 28, true);
      const extraLength = view.getUint16(cursor + 30, true);
      const commentLength = view.getUint16(cursor + 32, true);
      const localOffset = view.getUint32(cursor + 42, true);
      const name = new TextDecoder().decode(bytes.subarray(cursor + 46, cursor + 46 + nameLength));
      cursor += 46 + nameLength + extraLength + commentLength;

      expect(view.getUint32(localOffset, true), `${name} local header signature`).toBe(0x04034b50);
      const localFlags = view.getUint16(localOffset + 6, true);
      const localMethod = view.getUint16(localOffset + 8, true);
      expect(localMethod, `${name} local method`).toBe(method);
      if (method !== 0) continue;
      storedCount += 1;
      expect(localFlags & 0x08, `${name} STORED entry must not set the data descriptor bit`).toBe(0);
      expect(view.getUint32(localOffset + 14, true), `${name} local CRC`).toBe(crc);
      expect(view.getUint32(localOffset + 18, true), `${name} local compressed size`).toBe(compressedSize);
      expect(view.getUint32(localOffset + 22, true), `${name} local size`).toBe(size);
    }
    expect(storedCount, 'image entries are written STORED').toBeGreaterThan(0);
  }, 60_000);
});
