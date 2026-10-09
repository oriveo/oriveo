/**
 * Per-file size limit of an attachment import.
 *
 * The limit guards memory: every file is read in full (a base64 string, plus an ArrayBuffer read
 * again by the extractor), and anything larger would bring the tab down. A file over it is rejected
 * before any bytes are read, and the user is always told.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Attachment } from '@oriveo/shared';
import { __resetAttachmentImportQueueForTest, importAttachmentFiles } from '../attachment-import';
import { FALLBACK_ATTACHMENT_BYTES, attachmentLimitMegabytes } from '../../../utils/attachment-size-policy';

const { mockValidateAndConvertFiles } = vi.hoisted(() => ({ mockValidateAndConvertFiles: vi.fn() }));

vi.mock('../../../utils/attachment-utils-lazy', () => ({
  loadAttachmentUtils: () => Promise.resolve({ validateAndConvertFiles: mockValidateAndConvertFiles }),
}));
vi.mock('../../../../components/Toast', () => ({ showToast: vi.fn() }));

const MB = 1024 * 1024;

function sizedFile(name: string, sizeBytes: number): File {
  const file = new File(['x'], name, { type: 'application/pdf' });
  Object.defineProperty(file, 'size', { value: sizeBytes });
  return file;
}

function runImport(files: File[]) {
  const onRejectedBySize = vi.fn();
  const commit = vi.fn();
  const done = importAttachmentFiles({
    files,
    source: 'file',
    getAttachments: () => [],
    commit,
    onRejectedBySize,
    translate: (key) => key,
  });
  return { done, onRejectedBySize, commit };
}

describe('attachment per-file size limit', () => {
  beforeEach(() => {
    __resetAttachmentImportQueueForTest();
    mockValidateAndConvertFiles.mockReset();
    mockValidateAndConvertFiles.mockImplementation(async (files: File[]) =>
      files.map((item): Attachment => ({ id: item.name, kind: 'file', fileName: item.name, mimeType: item.type })));
  });

  it('rejects a 60 MB file with the "file too large" notice and never converts it', async () => {
    const huge = sizedFile('huge.pdf', 60 * MB);
    const { done, onRejectedBySize, commit } = runImport([huge]);
    await done;

    expect(onRejectedBySize).toHaveBeenCalledWith([huge]);
    expect(mockValidateAndConvertFiles).not.toHaveBeenCalled();
    expect(commit).not.toHaveBeenCalled();
  });

  it('imports files within the limit as usual, including one of exactly 50 MB', async () => {
    const small = sizedFile('small.pdf', 25 * MB);
    const edge = sizedFile('edge.pdf', 50 * MB);
    const { done, onRejectedBySize, commit } = runImport([small, edge]);
    await done;

    expect(onRejectedBySize).not.toHaveBeenCalled();
    expect(mockValidateAndConvertFiles.mock.calls[0][0]).toEqual([small, edge]);
    expect(commit).toHaveBeenCalledTimes(1);
  });

  it('reports a file found to be too large only at conversion time instead of dropping it silently', async () => {
    const late = sizedFile('late.pdf', 1 * MB);
    const fine = sizedFile('fine.pdf', 1 * MB);
    mockValidateAndConvertFiles.mockImplementation(async (
      files: File[],
      _source: unknown,
      _providerKind: unknown,
      _onFileFailed: unknown,
      onFileTooLarge?: (file: File) => void,
    ) => {
      onFileTooLarge?.(late);
      return files.filter((item) => item !== late)
        .map((item): Attachment => ({ id: item.name, kind: 'file', fileName: item.name, mimeType: item.type }));
    });
    const { done, onRejectedBySize, commit } = runImport([late, fine]);
    await done;

    expect(onRejectedBySize).toHaveBeenCalledWith([late]);
    expect(commit.mock.calls[0][0].map((item: Attachment) => item.fileName)).toEqual(['fine.pdf']);
  });

  it('shows the limit in whole megabytes, rounded down', () => {
    expect(FALLBACK_ATTACHMENT_BYTES).toBe(50 * MB);
    expect(attachmentLimitMegabytes(50 * MB)).toBe(50);
    expect(attachmentLimitMegabytes(50 * MB - 1)).toBe(49);
  });
});
