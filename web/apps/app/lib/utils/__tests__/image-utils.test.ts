import { describe, it, expect, afterEach, vi } from 'vitest';

import { base64ToBlob, compressImage, createImageThumbnail } from '../image-utils';

/**
 * Both functions must return null when decoding fails or no canvas context is available.
 *
 * Returning the input unchanged would make the "thumbnail" the entire original image as base64:
 * a 100MB PNG becomes a 133MB single string in the message attachment's thumbnailBase64, which
 * A remote backend rejects at commit time against a 1MiB per-document limit, taking the whole batch of
 * messages with it (the client SDK queues the mutation and raises nothing at write time).
 */

const ORIGINAL_IMAGE = globalThis.Image;
const HUGE_BASE64 = 'A'.repeat(4096);

/** An Image that always fires onerror, simulating a picture the browser cannot decode. */
class FailingImage {
  width = 0;
  height = 0;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  set src(_value: string) {
    setTimeout(() => this.onerror?.(), 0);
  }
}

/** An Image that decodes normally, used to isolate the missing canvas context branch. */
class LoadingImage {
  width = 4000;
  height = 3000;
  onload: (() => void) | null = null;
  onerror: (() => void) | null = null;
  set src(_value: string) {
    setTimeout(() => this.onload?.(), 0);
  }
}

afterEach(() => {
  (globalThis as unknown as { Image: unknown }).Image = ORIGINAL_IMAGE;
  vi.restoreAllMocks();
});

describe('compressImage', () => {
  it('returns null on a decode failure instead of handing back the original base64 as the compressed result', async () => {
    (globalThis as unknown as { Image: unknown }).Image = FailingImage;
    await expect(compressImage(HUGE_BASE64, 'image/png')).resolves.toBeNull();
  });

  it('returns null when the canvas 2d context is unavailable', async () => {
    (globalThis as unknown as { Image: unknown }).Image = LoadingImage;
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(null);
    await expect(compressImage(HUGE_BASE64, 'image/png')).resolves.toBeNull();
  });
});

describe('createImageThumbnail', () => {
  it('returns null on a decode failure instead of using the original base64 as the thumbnail', async () => {
    (globalThis as unknown as { Image: unknown }).Image = FailingImage;
    await expect(createImageThumbnail(HUGE_BASE64, 'image/png')).resolves.toBeNull();
  });

  it('returns null when the canvas 2d context is unavailable', async () => {
    (globalThis as unknown as { Image: unknown }).Image = LoadingImage;
    vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(null);
    await expect(createImageThumbnail(HUGE_BASE64, 'image/png')).resolves.toBeNull();
  });
});

/** jsdom's Blob has no arrayBuffer()/text(), so read the bytes with FileReader. */
function blobToUint8(blob: Blob): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(new Uint8Array(reader.result as ArrayBuffer));
    reader.onerror = () => reject(reader.error);
    reader.readAsArrayBuffer(blob);
  });
}

/**
 * Image attachments and file attachment uploads share this chunked conversion.
 * `Uint8Array.from(atob(all), mapFn)` measures 150ms in a single synchronous block for a 5MB
 * input, which freezes the tab. The only risk in chunking is splitting on the wrong boundary
 * (base64 maps 4 characters onto 3 bytes), so these tests compare byte for byte.
 */
describe('base64ToBlob', () => {
  it(' ', async () => {
    // 3MB is roughly 4M base64 characters, which is certain to cross the 1MB chunk boundary.
    const size = 3 * 1024 * 1024;
    const raw = new Uint8Array(size);
    for (let i = 0; i < size; i++) raw[i] = (i * 31 + 7) & 0xff;
    let binary = '';
    for (let i = 0; i < size; i += 8192) {
      binary += String.fromCharCode(...raw.subarray(i, i + 8192));
    }

    const blob = await base64ToBlob(btoa(binary), 'image/png');

    expect(blob.type).toBe('image/png');
    expect(blob.size).toBe(size);
    const bytes = await blobToUint8(blob);
    let firstMismatch = -1;
    for (let i = 0; i < raw.length; i++) {
      if (bytes[i] !== raw[i]) { firstMismatch = i; break; }
    }
    expect(firstMismatch).toBe(-1);
  });

  it(' ', async () => {
    const blob = await base64ToBlob(btoa('tiny thumbnail bytes'), 'image/jpeg');
    expect(new TextDecoder().decode(await blobToUint8(blob))).toBe('tiny thumbnail bytes');
  });

  it('an empty base64 string produces an empty Blob', async () => {
    const blob = await base64ToBlob('', 'application/octet-stream');
    expect(blob.size).toBe(0);
  });
});
