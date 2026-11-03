// @vitest-environment node
/**
 * persistStudioRoundImages against the real image store on fake-indexeddb:
 * saved rounds read back byte-for-byte, cancels and failed writes roll the
 * whole round back.
 */
import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  imageExists,
  loadImageData,
  resetImageDBConnection,
  saveImage,
} from '../../../infra/storage/image-store';
import { setActiveUID } from '../../../infra/storage/partition';
import { resetDBConnection } from '../../../infra/storage/idb';
import {
  persistStudioRoundImages,
  type StudioRoundImageBytes,
  type StudioRoundStatus,
} from '../byok-persist';

const UID = 'guest';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function image(bytes: number[], mime = 'image/png', revisedPrompt: string | null = null): StudioRoundImageBytes {
  return { data: new Uint8Array(bytes), mime, width: 1024, height: 768, revisedPrompt };
}

function round(status: StudioRoundStatus, images: StudioRoundImageBytes[]) {
  return {
    status,
    errorKind: status === 'partial' ? ('partial' as const) : null,
    message: null,
    mayBeBilled: true,
    retried: false,
    nRequested: 3,
    delivered: images.length,
    composedPrompt: 'a red fox',
    adjustments: { prompt: [], params: [] },
    usage: { inputTokens: 10, outputTokens: 20, totalTokens: 30 },
    images,
  };
}

async function readBack(id: string) {
  const blob = await loadImageData(id, UID);
  expect(blob).not.toBeNull();
  return { bytes: Array.from(new Uint8Array(await blob!.arrayBuffer())), type: blob!.type };
}

/** Persist through the real store while recording every id written. */
function recordingPersist(written: string[], onWrite?: (index: number) => void) {
  return async (bytes: Uint8Array, mime: string) => {
    const id = crypto.randomUUID();
    await saveImage(id, new Blob([bytes as Uint8Array<ArrayBuffer>], { type: mime }), null, mime, UID);
    written.push(id);
    onWrite?.(written.length - 1);
    return id;
  };
}

describe('persistStudioRoundImages', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID(UID);
  });

  describe('saved', () => {
    it('writes every image and reads back the same bytes and mime', async () => {
      const input = round('completed', [image([1, 2, 3]), image([9, 8], 'image/webp', 'a red fox, revised')]);
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: new AbortController().signal,
      });

      expect(out.status).toBe('completed');
      expect(out.images).toHaveLength(2);
      expect(out.images[0]).toEqual({
        assetId: expect.any(String),
        mime: 'image/png',
        width: 1024,
        height: 768,
        revisedPrompt: null,
      });
      expect(out.images[1].revisedPrompt).toBe('a red fox, revised');
      expect(out.images[0].assetId).not.toBe(out.images[1].assetId);
      expect(await readBack(out.images[0].assetId)).toEqual({ bytes: [1, 2, 3], type: 'image/png' });
      expect(await readBack(out.images[1].assetId)).toEqual({ bytes: [9, 8], type: 'image/webp' });
    });

    it('keeps every other round field', async () => {
      const input = round('partial', [image([4, 5])]);
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: new AbortController().signal,
      });
      const { images: _in, ...restIn } = input;
      const { images: _out, ...restOut } = out;
      expect(restOut).toEqual(restIn);
      expect(out.images).toHaveLength(1);
    });

    it('returns a failed round unchanged without writing', async () => {
      const persist = vi.fn(async () => 'never');
      const input = { ...round('failed', []), errorKind: 'timeout' as const, message: 'slow' };
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: new AbortController().signal,
        persist,
      });
      expect(out).toEqual(input);
      expect(persist).not.toHaveBeenCalled();
    });
  });

  describe('cancelled', () => {
    it('writes nothing when the signal is already aborted', async () => {
      const controller = new AbortController();
      controller.abort();
      const persist = vi.fn(async () => 'never');
      const input = round('completed', [image([1]), image([2])]);
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: controller.signal,
        persist,
      });
      expect(persist).not.toHaveBeenCalled();
      expect(out.status).toBe('cancelled');
      expect(out.images).toEqual([]);
      expect(out.composedPrompt).toBe('a red fox');
    });

    it('deletes images already written when aborted mid-round', async () => {
      const controller = new AbortController();
      const written: string[] = [];
      const persist = vi.fn(recordingPersist(written, (index) => {
        if (index === 0) controller.abort();
      }));
      const input = round('completed', [image([1]), image([2]), image([3])]);
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: controller.signal,
        persist,
      });
      expect(persist).toHaveBeenCalledTimes(1);
      expect(written).toHaveLength(1);
      expect(await imageExists(written[0], UID)).toBe(false);
      expect(out.status).toBe('cancelled');
      expect(out.images).toEqual([]);
    });

    it('clears errorKind and message of a cancelled partial round', async () => {
      const controller = new AbortController();
      controller.abort();
      const input = { ...round('partial', [image([1])]), message: 'only 1 of 3 delivered' };
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: controller.signal,
        persist: vi.fn(async () => 'never'),
      });
      expect(out.status).toBe('cancelled');
      expect(out.errorKind).toBeNull();
      expect(out.message).toBeNull();
      expect(out.images).toEqual([]);
      expect(out.mayBeBilled).toBe(true);
      expect(out.delivered).toBe(1);
    });
  });

  describe('rollback', () => {
    it('deletes earlier writes and reports storage_full when a write throws', async () => {
      const written: string[] = [];
      const save = recordingPersist(written);
      let calls = 0;
      const persist = vi.fn(async (bytes: Uint8Array, mime: string) => {
        calls += 1;
        if (calls === 2) throw new DOMException('quota', 'QuotaExceededError');
        return save(bytes, mime);
      });
      const input = round('completed', [image([1]), image([2]), image([3])]);
      const out = await persistStudioRoundImages(input, {
        partitionUID: UID,
        signal: new AbortController().signal,
        persist,
      });

      expect(persist).toHaveBeenCalledTimes(2);
      expect(written).toHaveLength(1);
      expect(await imageExists(written[0], UID)).toBe(false);
      expect(out.status).toBe('failed');
      expect(out.errorKind).toBe('storage_full');
      expect(out.images).toEqual([]);
      const { images: _in, status: _s, errorKind: _e, ...restIn } = input;
      const { images: _out, status: _s2, errorKind: _e2, ...restOut } = out;
      expect(restOut).toEqual(restIn);
    });
  });
});
