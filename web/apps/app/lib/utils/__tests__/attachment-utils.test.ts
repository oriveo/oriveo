import { describe, it, expect, afterEach, vi } from 'vitest';
import * as Sentry from '@sentry/nextjs';

vi.mock('../../utils/office-parser', () => ({
  parseOfficeFile: vi.fn(async () => 'Extracted office text'),
}));

const mocks = vi.hoisted(() => ({
  saveImage: vi.fn().mockResolvedValue(undefined),
}));

vi.mock('../../infra/storage/image-store', () => ({
  saveImage: mocks.saveImage,
}));

vi.mock('../../core/telemetry', () => ({
  trackEvent: vi.fn(),
}));

import { validateFile, fileToAttachment, validateAndConvertFiles } from '../../utils/attachment-utils';

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

  // A saved web page is mostly markup. Forwarding it verbatim spends the context window on tags,
  // so it goes through the HTML extractor exactly as on the other clients.
  it('extracts prose from an HTML attachment instead of forwarding the markup', async () => {
    const html = '<html><head><style>p{color:red}</style></head><body><script>ignored()</script><p>Visible prose.</p></body></html>';
    const file = new File([html], 'page.html', { type: 'text/html' });

    const attachment = await fileToAttachment(file);

    expect(attachment.base64Data).toContain('Visible prose.');
    expect(attachment.base64Data).not.toContain('<p>');
    expect(attachment.base64Data).not.toContain('ignored()');
  });

  it('accepts .htm and .xhtml, which reach the extractor rather than validation', () => {
    expect(validateFile(new File(['<p>hi</p>'], 'page.htm', { type: 'text/html' })).valid).toBe(true);
    expect(validateFile(new File(['<p>hi</p>'], 'page.xhtml', { type: 'application/xhtml+xml' })).valid).toBe(true);
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

      // The ImageStore call carries the uncompressed bytes and no thumbnail.
      const [, imageBlob, thumbBlob, storedMime] = mocks.saveImage.mock.calls[0];
      expect(imageBlob.size).toBe(rawBytes.length);
      expect(thumbBlob).toBeNull();
      expect(storedMime).toBe('image/png');
    });
  });
});

describe('validateAndConvertFiles', () => {
  // Drive the real FileReader failure path: reader.error is the DOMException the browser reports
  // once the file behind the handle is gone.
  function failReadsOf(fileName: string, error: unknown) {
    const original = FileReader.prototype.readAsDataURL;
    return vi.spyOn(FileReader.prototype, 'readAsDataURL').mockImplementation(function (this: FileReader, blob: Blob) {
      if ((blob as File).name !== fileName) return original.call(this, blob);
      Object.defineProperty(this, 'error', { value: error });
      setTimeout(() => this.onerror?.(new ProgressEvent('error') as ProgressEvent<FileReader>), 0);
    });
  }

  afterEach(() => {
    vi.restoreAllMocks();
    vi.mocked(Sentry.captureException).mockClear();
  });

  it.each(['NotFoundError', 'NotReadableError'])('skips only the unreadable file (%s), reports it, and converts the rest', async (name) => {
    failReadsOf('gone.txt', new DOMException('A requested file or directory could not be found', name));
    const onUnreadable = vi.fn();
    const gone = new File(['x'], 'gone.txt', { type: 'text/plain' });
    const ok = new File(['hello'], 'ok.txt', { type: 'text/plain' });

    const attachments = await validateAndConvertFiles([gone, ok], 'drag_drop', undefined, onUnreadable);

    expect(attachments.map((a) => a.fileName)).toEqual(['ok.txt']);
    expect(onUnreadable).toHaveBeenCalledTimes(1);
    expect(onUnreadable).toHaveBeenCalledWith(gone);
  });

  // A file over the limit used to be skipped here without a word: nothing reached the tray and no
  // notice was shown.
  it('does not read a file over the limit and reports it as too large instead of dropping it silently', async () => {
    const onFailed = vi.fn();
    const onTooLarge = vi.fn();
    const huge = new File(['x'], 'huge.txt', { type: 'text/plain' });
    Object.defineProperty(huge, 'size', { value: 60 * 1024 * 1024 });
    const ok = new File(['hello'], 'ok.txt', { type: 'text/plain' });
    const read = vi.spyOn(FileReader.prototype, 'readAsDataURL');

    const attachments = await validateAndConvertFiles([huge, ok], 'file', undefined, onFailed, onTooLarge);

    expect(attachments.map((a) => a.fileName)).toEqual(['ok.txt']);
    expect(onTooLarge).toHaveBeenCalledTimes(1);
    expect(onTooLarge).toHaveBeenCalledWith(huge);
    expect(onFailed).not.toHaveBeenCalled();
    expect(read.mock.calls.some(([blob]) => (blob as File).name === 'huge.txt')).toBe(false);
  });

  it('does not report a file of an unsupported type as too large', async () => {
    const onTooLarge = vi.fn();
    const exe = new File(['x'], 'tool.exe', { type: 'application/x-msdownload' });

    const attachments = await validateAndConvertFiles([exe], 'file', undefined, undefined, onTooLarge);

    expect(attachments).toEqual([]);
    expect(onTooLarge).not.toHaveBeenCalled();
  });

  // These errors used to propagate while none of the three entry points caught them: one unhandled
  // rejection, and the whole batch, converted files included, vanished without notice.
  it('drops only the failing file on any other error, converts the rest, and reports the error explicitly', async () => {
    failReadsOf('bad.txt', new TypeError('boom'));
    const onFileFailed = vi.fn();
    const before = new File(['a'], 'before.txt', { type: 'text/plain' });
    const bad = new File(['x'], 'bad.txt', { type: 'text/plain' });
    const after = new File(['b'], 'after.txt', { type: 'text/plain' });

    const attachments = await validateAndConvertFiles([before, bad, after], 'file', undefined, onFileFailed);

    expect(attachments.map((a) => a.fileName)).toEqual(['before.txt', 'after.txt']);
    expect(onFileFailed).toHaveBeenCalledExactlyOnceWith(bad);
    expect(Sentry.captureException).toHaveBeenCalledExactlyOnceWith(
      expect.objectContaining({ message: 'boom' }),
      expect.objectContaining({ tags: expect.objectContaining({ module: 'attachment.import' }) }),
    );
  });

  it('does not report an unreadable file, which is an environment condition', async () => {
    failReadsOf('gone.txt', new DOMException('gone', 'NotFoundError'));
    await validateAndConvertFiles([new File(['x'], 'gone.txt', { type: 'text/plain' })], 'file', undefined, vi.fn());
    expect(Sentry.captureException).not.toHaveBeenCalled();
  });

  // The picker, drag and drop, and paste can each start a batch while the previous one is still
  // being read, and every file is read into memory in full.
  it('queues two imports: the second does not start reading before the first has finished', async () => {
    const order: string[] = [];
    const original = FileReader.prototype.readAsDataURL;
    vi.spyOn(FileReader.prototype, 'readAsDataURL').mockImplementation(function (this: FileReader, blob: Blob) {
      const name = (blob as File).name;
      order.push(`start:${name}`);
      this.addEventListener('loadend', () => order.push(`end:${name}`));
      return original.call(this, blob);
    });
    const batch = (...names: string[]) => names.map((name) => new File([name], name, { type: 'text/plain' }));

    const [first, second] = await Promise.all([
      validateAndConvertFiles(batch('a1.txt', 'a2.txt'), 'file'),
      validateAndConvertFiles(batch('b1.txt'), 'paste'),
    ]);

    expect(first.map((a) => a.fileName)).toEqual(['a1.txt', 'a2.txt']);
    expect(second.map((a) => a.fileName)).toEqual(['b1.txt']);
    expect(order).toEqual([
      'start:a1.txt', 'end:a1.txt', 'start:a2.txt', 'end:a2.txt', 'start:b1.txt', 'end:b1.txt',
    ]);
  });

  it('does not let a batch that failed as a whole block later imports', async () => {
    const telemetry = await import('../../core/telemetry');
    vi.spyOn(telemetry, 'trackEvent').mockImplementationOnce(() => { throw new Error('telemetry down'); });
    await expect(
      validateAndConvertFiles([new File(['x'], 'one.txt', { type: 'text/plain' })], 'file'),
    ).rejects.toThrow('telemetry down');

    const next = await validateAndConvertFiles([new File(['y'], 'two.txt', { type: 'text/plain' })], 'file');
    expect(next.map((a) => a.fileName)).toEqual(['two.txt']);
  });
});
