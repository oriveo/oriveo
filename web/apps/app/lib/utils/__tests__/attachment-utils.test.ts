import { describe, it, expect, afterEach, vi } from 'vitest';

vi.mock('../../utils/office-parser', () => ({
  parseOfficeFile: vi.fn(async () => 'Extracted office text'),
}));

const mocks = vi.hoisted(() => ({
  saveImage: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('../../infra/storage/image-store', () => ({
  saveImage: mocks.saveImage,
}));

import { validateFile, fileToAttachment } from '../../utils/attachment-utils';

describe('validateFile', () => {
  function makeFile(name: string, type: string, size: number): File {
    const buffer = new ArrayBuffer(size);
    return new File([buffer], name, { type });
  }

  it('should accept valid image files', () => {
    const result = validateFile(makeFile('photo.png', 'image/png', 1024));
    expect(result.valid).toBe(true);
  });

  it('should accept valid text files', () => {
    const result = validateFile(makeFile('doc.txt', 'text/plain', 512));
    expect(result.valid).toBe(true);
  });

  it('should reject files over 50MB', () => {
    const result = validateFile(makeFile('big.png', 'image/png', 50 * 1024 * 1024 + 1));
    expect(result.valid).toBe(false);
  });

  it('should accept provider-supported video files', () => {
    const result = validateFile(makeFile('video.mp4', 'video/mp4', 1024));
    expect(result.valid).toBe(true);
  });

  it('should reject unsupported file types', () => {
    const result = validateFile(makeFile('archive.zip', 'application/zip', 1024));
    expect(result.valid).toBe(false);
  });
});

describe('fileToAttachment', () => {
  it('should keep original office file bytes for download', async () => {
    const file = new File(
      ['PKDOCX'],
      'paper.docx',
      { type: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' },
    );

    const attachment = await fileToAttachment(file);

    expect(attachment.fileName).toBe('paper.docx');
    expect(attachment.base64Data).toBe('Extracted office text');
    expect(attachment.downloadBase64Data).toBe(btoa('PKDOCX'));
  });

  it('should convert video files into video attachments', async () => {
    const file = new File(['VIDEO'], 'clip.mp4', { type: 'video/mp4' });

    const attachment = await fileToAttachment(file);

    expect(attachment.kind).toBe('video');
    expect(attachment.fileName).toBe('clip.mp4');
    expect(attachment.base64Data).toBe(btoa('VIDEO'));
  });

  describe('image decoding failures', () => {
    const ORIGINAL_IMAGE = globalThis.Image;

    class FailingImage {
      width = 0;
      height = 0;
      onload: (() => void) | null = null;
      onerror: (() => void) | null = null;
      set src(_value: string) {
        setTimeout(() => this.onerror?.(), 0);
      }
    }

    afterEach(() => {
      (globalThis as unknown as { Image: unknown }).Image = ORIGINAL_IMAGE;
      mocks.saveImage.mockClear();
    });

    // The one hard rule: the product of a failed decode must never reach thumbnailBase64, the field written into the remote message document.
    it('never writes the original image base64 into thumbnailBase64, while the attachment itself stays usable', async () => {
      (globalThis as unknown as { Image: unknown }).Image = FailingImage;
      const rawBytes = 'PNGBYTES'.repeat(4096);
      const file = new File([rawBytes], 'huge.png', { type: 'image/png' });

      const attachment = await fileToAttachment(file);

      expect(attachment.thumbnailBase64).toBeUndefined();
      // Too large to compress, but still an image: the bytes go to the ImageStore under an id.
      expect(attachment.kind).toBe('image');
      expect(attachment.localImageID).toBeDefined();
      // Compression did not happen, so the mime type and file name must return to those of the original file instead of staying image/jpeg.
      expect(attachment.mimeType).toBe('image/png');
      expect(attachment.fileName).toBe('huge.png');

      // ImageStore  
      const [, imageBlob, thumbBlob, storedMime] = mocks.saveImage.mock.calls[0];
      expect(imageBlob.size).toBe(rawBytes.length);
      expect(thumbBlob).toBeNull();
      expect(storedMime).toBe('image/png');
    });
  });
});
