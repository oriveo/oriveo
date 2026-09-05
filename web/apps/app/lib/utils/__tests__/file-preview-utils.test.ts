import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Attachment } from '@oriveo/shared';

vi.mock('../../core/sync-port', () => ({
  downloadFileBlob: vi.fn(),
  downloadFileURL: vi.fn(),
}));

import { buildLocalFileBlob, previewFileAttachment } from '../../utils/file-preview-utils';
import { downloadFileBlob, downloadFileURL } from '../../core/sync-port';

function makeAttachment(overrides: Partial<Attachment> = {}): Attachment {
  return {
    id: 'att-1',
    kind: 'file',
    fileName: 'paper.docx',
    mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    ...overrides,
  };
}

async function readBlobAsText(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result as string);
    reader.onerror = () => reject(reader.error);
    reader.readAsText(blob);
  });
}

describe('buildLocalFileBlob', () => {
  it('prefers original file bytes when available', async () => {
    const blob = buildLocalFileBlob(makeAttachment({
      base64Data: 'Extracted office text',
      downloadBase64Data: btoa('PKDOCX'),
    }));

    expect(blob).not.toBeNull();
    expect(blob!.type).toBe('application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    expect(await readBlobAsText(blob!)).toBe('PKDOCX');
  });

  it('falls back to plain text payload for legacy non-PDF attachments', async () => {
    const blob = buildLocalFileBlob(makeAttachment({
      fileName: 'notes.txt',
      mimeType: 'text/plain',
      base64Data: 'Hello notes',
      downloadBase64Data: undefined,
    }));

    expect(blob).not.toBeNull();
    expect(blob!.type).toBe('text/plain');
    expect(await readBlobAsText(blob!)).toBe('Hello notes');
  });
});

describe('previewFileAttachment', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.runOnlyPendingTimers();
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it('downloads local office attachments instead of opening a preview window', async () => {
    const clickSpy = vi.fn();
    const originalCreateElement = document.createElement.bind(document);

    vi.spyOn(document, 'createElement').mockImplementation(((tagName: string) => {
      const element = originalCreateElement(tagName);
      if (tagName.toLowerCase() === 'a') {
        Object.defineProperty(element, 'click', { value: clickSpy });
      }
      return element;
    }) as typeof document.createElement);

    Object.defineProperty(URL, 'createObjectURL', {
      value: vi.fn(() => 'blob:local-file'),
      configurable: true,
      writable: true,
    });
    const revokeSpy = vi.fn();
    Object.defineProperty(URL, 'revokeObjectURL', {
      value: revokeSpy,
      configurable: true,
      writable: true,
    });
    const openSpy = vi.spyOn(window, 'open').mockImplementation(() => null);

    await previewFileAttachment(
      makeAttachment({
        base64Data: 'Extracted office text',
        downloadBase64Data: btoa('PKDOCX'),
      }),
      vi.fn(),
      vi.fn(),
    );

    expect(clickSpy).toHaveBeenCalledOnce();
    expect(openSpy).not.toHaveBeenCalled();

    vi.runAllTimers();
    expect(revokeSpy).toHaveBeenCalledWith('blob:local-file');
  });

  it('prefers a remote blob download for files that are not stored locally', async () => {
    const clickSpy = vi.fn();
    const originalCreateElement = document.createElement.bind(document);

    vi.spyOn(document, 'createElement').mockImplementation(((tagName: string) => {
      const element = originalCreateElement(tagName);
      if (tagName.toLowerCase() === 'a') {
        Object.defineProperty(element, 'click', { value: clickSpy });
      }
      return element;
    }) as typeof document.createElement);

    Object.defineProperty(URL, 'createObjectURL', {
      value: vi.fn(() => 'blob:remote-file'),
      configurable: true,
      writable: true,
    });
    Object.defineProperty(URL, 'revokeObjectURL', {
      value: vi.fn(),
      configurable: true,
      writable: true,
    });

    vi.mocked(downloadFileBlob).mockResolvedValue(new Blob(['docx']));

    await previewFileAttachment(
      makeAttachment({ base64Data: undefined, storageRef: 'users/u/attachments/a1' }),
      vi.fn(),
      vi.fn(),
    );

    expect(downloadFileBlob).toHaveBeenCalledWith('users/u/attachments/a1');
    expect(downloadFileURL).not.toHaveBeenCalled();
    expect(clickSpy).toHaveBeenCalledOnce();
  });

  it('falls back to download URL fetch when blob fetch is unavailable', async () => {
    const clickSpy = vi.fn();
    const originalCreateElement = document.createElement.bind(document);

    vi.spyOn(document, 'createElement').mockImplementation(((tagName: string) => {
      const element = originalCreateElement(tagName);
      if (tagName.toLowerCase() === 'a') {
        Object.defineProperty(element, 'click', { value: clickSpy });
      }
      return element;
    }) as typeof document.createElement);

    Object.defineProperty(URL, 'createObjectURL', {
      value: vi.fn(() => 'blob:fetched-file'),
      configurable: true,
      writable: true,
    });
    Object.defineProperty(URL, 'revokeObjectURL', {
      value: vi.fn(),
      configurable: true,
      writable: true,
    });

    vi.mocked(downloadFileBlob).mockResolvedValue(null);
    vi.mocked(downloadFileURL).mockResolvedValue('https://example.com/file.docx');
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      blob: async () => new Blob(['remote-docx']),
    }));

    await previewFileAttachment(
      makeAttachment({ base64Data: undefined, storageRef: 'users/u/attachments/a1' }),
      vi.fn(),
      vi.fn(),
    );

    expect(downloadFileBlob).toHaveBeenCalledWith('users/u/attachments/a1');
    expect(downloadFileURL).toHaveBeenCalledWith('users/u/attachments/a1');
    expect(fetch).toHaveBeenCalledWith(expect.stringContaining('https://example.com/file.docx'));
    expect(fetch).toHaveBeenCalledWith(expect.stringContaining('response-content-disposition='));
    expect(clickSpy).toHaveBeenCalledOnce();
  });
});
