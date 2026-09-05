import 'fake-indexeddb/auto';
import { describe, it, expect, beforeEach } from 'vitest';
import {
  saveImage,
  loadImageData,
  loadThumbnailData,
  deleteImage,
  imageExists,
  imageSizeBytes,
  resetImageDBConnection,
} from '../image-store';
import { setActiveUID } from '../partition';
import { resetDBConnection } from '../idb';

async function clearAllDatabases() {
  const dbs = await indexedDB.databases();
  for (const db of dbs) {
    if (db.name) indexedDB.deleteDatabase(db.name);
  }
}

function makeBlob(content = 'test-data', type = 'image/png'): Blob {
  return new Blob([content], { type });
}

describe('image-store.ts', () => {
  beforeEach(async () => {
    resetDBConnection();
    resetImageDBConnection();
    await clearAllDatabases();
    await setActiveUID('guest');
  });

  // -- 3.1 Partition isolation ---------------------------

  describe('partition isolation', () => {
    it('should not see guest images from user-A partition', async () => {
      // Save as guest
      await saveImage('img1', makeBlob('original'), makeBlob('thumb'), 'image/png');

      // Switch to user-A
      resetImageDBConnection();
      await setActiveUID('user-A');

      const data = await loadImageData('img1');
      expect(data).toBeNull();
    });

    it('should not see user-A images from guest partition', async () => {
      // Save as user-A
      resetImageDBConnection();
      await setActiveUID('user-A');
      await saveImage('img-A', makeBlob('user-A-data'), makeBlob('thumb-A'), 'image/png');

      // Switch back to guest
      resetImageDBConnection();
      await setActiveUID('guest');

      const exists = await imageExists('img-A');
      expect(exists).toBe(false);
    });

    it('expectedUID prevents stale replaceAll image writes and deletes after an account switch', async () => {
      await setActiveUID('user-A');
      resetImageDBConnection();
      await saveImage('shared-id', makeBlob('a'), makeBlob('a-thumb'), 'image/png');

      await setActiveUID('user-B');
      resetImageDBConnection();
      await saveImage('shared-id', makeBlob('b'), makeBlob('b-thumb'), 'image/png');

      await expect(
        saveImage('stale-a', makeBlob('stale'), makeBlob('stale-thumb'), 'image/png', 'user-A'),
      ).rejects.toThrow('Active image storage partition changed from user-A to user-B');
      await expect(deleteImage('shared-id', 'user-A'))
        .rejects.toThrow('Active image storage partition changed from user-A to user-B');

      expect(await imageExists('stale-a')).toBe(false);
      expect(await imageExists('shared-id')).toBe(true);
    });
  });

  // ── 3.2 resetImageDBConnection ────────────────────────

  describe('resetImageDBConnection', () => {
    it('should ensure isolation after reset + uid switch', async () => {
      await saveImage('img1', makeBlob('guest-data'), makeBlob('guest-thumb'), 'image/png');

      resetImageDBConnection();
      await setActiveUID('user-A');

      expect(await imageExists('img1')).toBe(false);

      // User-A writes their own
      await saveImage('img-A', makeBlob('userA-data'), makeBlob('userA-thumb'), 'image/png');
      expect(await imageExists('img-A')).toBe(true);
    });
  });

  // ── 3.3 CRUD ─────────────────────────────────────────

  describe('CRUD operations', () => {
    it('should save and load image data', async () => {
      const originalBlob = makeBlob('original-data');
      const thumbnailBlob = makeBlob('thumbnail-data');

      await saveImage('img1', originalBlob, thumbnailBlob, 'image/png');
      const loaded = await loadImageData('img1');

      expect(loaded).not.toBeNull();
      // fake-indexeddb may return Blob without .size; just verify it's truthy
      expect(loaded).toBeDefined();
    });

    it('should save and load thumbnail data', async () => {
      const thumbnailBlob = makeBlob('thumbnail-data');
      await saveImage('img1', makeBlob('original'), thumbnailBlob, 'image/png');

      const loaded = await loadThumbnailData('img1');
      expect(loaded).not.toBeNull();
      expect(loaded).toBeDefined();
    });

    it('should report imageExists correctly', async () => {
      expect(await imageExists('img1')).toBe(false);

      await saveImage('img1', makeBlob(), makeBlob(), 'image/png');
      expect(await imageExists('img1')).toBe(true);
    });

    it('should delete image', async () => {
      await saveImage('img1', makeBlob(), makeBlob(), 'image/png');
      await deleteImage('img1');

      expect(await imageExists('img1')).toBe(false);
    });

    it('should return null for nonexistent image', async () => {
      const data = await loadImageData('nonexistent');
      expect(data).toBeNull();
    });

    // Note: half of what imageSizeBytes does (measuring the real size) cannot be tested here,
    // because fake-indexeddb does not preserve Blobs. What goes in comes back as an empty object
    // (`{}`, with no .size); only a real browser returns a Blob handle. So this pins the part that
    // is testable: when the size cannot be probed it counts as 0 instead of throwing. The cost
    // calculation itself is covered in outbound-attachment-budget.test.ts with an injected probe.
    it('should report 0 bytes instead of throwing when the image is unmeasurable', async () => {
      // An unmeasurable size counts as 0: trimming one image too few is better than letting the size probe break the whole send.
      expect(await imageSizeBytes('nonexistent')).toBe(0);

      await saveImage('img1', makeBlob('0123456789'), makeBlob('t'), 'image/png');
      expect(await imageSizeBytes('img1')).toBe(0);
    });
  });
});
