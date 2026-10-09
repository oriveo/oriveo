/**
 * The unified attachment import flow: two interleaved batches neither lose attachments nor exceed
 * the limit, and an extraction failure is announced at import time.
 *
 * Real React state connects the two entry points (useAttachmentIntake for the file picker,
 * useAttachmentDragDrop for drag and drop and paste) to one attachment tray, the way ChatView
 * wires them. Only the "read and convert the files" step is replaced, so the test controls when
 * it completes.
 */
import { act, render } from '@testing-library/react';
import { useCallback, useState } from 'react';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { Attachment } from '@oriveo/shared';
import {
  __resetAttachmentImportQueueForTest,
  appendAttachmentsWithinLimit,
  extractionFailureCopyKey,
} from '../attachment-import';
import { useAttachmentIntake } from '../../../hooks/useAttachmentIntake';
import { useAttachmentDragDrop } from '../../../hooks/useAttachmentDragDrop';

const { mockValidateAndConvertFiles, mockShowToast } = vi.hoisted(() => ({
  mockValidateAndConvertFiles: vi.fn(),
  mockShowToast: vi.fn(),
}));

vi.mock('../../../utils/attachment-utils-lazy', () => ({
  loadAttachmentUtils: () => Promise.resolve({ validateAndConvertFiles: mockValidateAndConvertFiles }),
}));
vi.mock('../../../../components/Toast', () => ({ showToast: mockShowToast }));
vi.mock('next-intl', () => {
  const translate = (key: string, values?: Record<string, unknown>) =>
    values ? `${key}(${JSON.stringify(values)})` : key;
  return { useTranslations: () => translate };
});

const file = (name: string) => new File(['x'], name, { type: 'text/plain' });
const toAttachment = (source: File, extra: Partial<Attachment> = {}): Attachment => ({
  id: `att-${source.name}`,
  kind: 'file',
  fileName: source.name,
  mimeType: 'text/plain',
  ...extra,
});

interface Harness {
  attachments: Attachment[];
  pickFiles: (files: File[]) => Promise<void>;
  dropFiles: (files: File[]) => Promise<void>;
  remove: (id: string) => void;
}

function renderComposer(): { current: Harness } {
  const handle = { current: null as unknown as Harness };
  function Composer() {
    const [attachments, setAttachments] = useState<Attachment[]>([]);
    const intake = useAttachmentIntake({ attachments, onAttachmentsChange: setAttachments, supportsImage: true });
    const onFilesAccepted = useCallback((incoming: Attachment[], max: number) => {
      setAttachments((current) => appendAttachmentsWithinLimit(current, incoming, max));
    }, []);
    const { dragHandlers } = useAttachmentDragDrop(onFilesAccepted, undefined, { existingAttachments: attachments });
    handle.current = {
      attachments,
      pickFiles: intake.handleAddFiles,
      dropFiles: (files) => dragHandlers.onDrop({ preventDefault: () => {}, dataTransfer: { files } } as never),
      remove: intake.handleRemoveAttachment,
    };
    return null;
  }
  render(<Composer />);
  return handle;
}

/** Lets queued imports and React renders run to completion. */
const settle = () => act(async () => { await new Promise((resolve) => setTimeout(resolve, 20)); });

describe('importAttachmentFiles', () => {
  beforeEach(() => {
    __resetAttachmentImportQueueForTest();
    mockValidateAndConvertFiles.mockReset();
    mockShowToast.mockReset();
    mockValidateAndConvertFiles.mockImplementation(async (files: File[]) => files.map((item) => toAttachment(item)));
  });

  afterEach(() => vi.restoreAllMocks());

  it('keeps both batches when the second arrives before the first has written back, caps the total at 3 and does not read the excess', async () => {
    const composer = renderComposer();
    let finishFirstBatch!: () => void;
    mockValidateAndConvertFiles.mockImplementationOnce((files: File[]) => new Promise<Attachment[]>((resolve) => {
      finishFirstBatch = () => resolve(files.map((item) => toAttachment(item)));
    }));

    // The first batch (file picker) has started reading and has not written back when the second
    // (drag and drop) arrives. Both entry points see an empty tray at this point.
    let first!: Promise<void>;
    let second!: Promise<void>;
    await act(async () => {
      first = composer.current.pickFiles([file('a1.txt'), file('a2.txt')]);
      second = composer.current.dropFiles([file('b1.txt'), file('b2.txt')]);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(composer.current.attachments).toEqual([]);
    expect(mockValidateAndConvertFiles).toHaveBeenCalledTimes(1);

    await act(async () => {
      finishFirstBatch();
      await Promise.all([first, second]);
    });
    await settle();

    expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a1.txt', 'a2.txt', 'b1.txt']);
    // The second batch's gate saw the first batch's result: one slot was left and b2 was never read.
    expect((mockValidateAndConvertFiles.mock.calls[1]?.[0] as File[]).map((item) => item.name)).toEqual(['b1.txt']);
    expect(mockShowToast).toHaveBeenCalledWith('tooManyFiles({"maxFiles":3})');
  });

  it('cuts the write-back to the real length at merge time, so a stale gate can neither exceed the limit nor overwrite', () => {
    const existing = ['a', 'b'].map((name) => toAttachment(file(`${name}.txt`)));
    const incoming = ['c', 'd'].map((name) => toAttachment(file(`${name}.txt`)));

    expect(appendAttachmentsWithinLimit(existing, incoming, 3).map((item) => item.fileName))
      .toEqual(['a.txt', 'b.txt', 'c.txt']);
    const full = [...existing, incoming[0]];
    expect(appendAttachmentsWithinLimit(full, [incoming[1]], 3)).toBe(full);
  });

  it('does not drop a freshly merged batch when an attachment is removed mid-import', async () => {
    const composer = renderComposer();
    await act(async () => { await composer.current.pickFiles([file('keep.txt'), file('drop.txt')]); });
    await settle();

    let finish!: () => void;
    mockValidateAndConvertFiles.mockImplementationOnce((files: File[]) => new Promise<Attachment[]>((resolve) => {
      finish = () => resolve(files.map((item) => toAttachment(item)));
    }));
    let pending!: Promise<void>;
    await act(async () => {
      pending = composer.current.dropFiles([file('late.txt')]);
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    // This remove callback was created before late.txt was merged in.
    const removeCapturedEarlier = composer.current.remove;
    await act(async () => { finish(); await pending; });
    act(() => removeCapturedEarlier('att-drop.txt'));
    await settle();

    expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['keep.txt', 'late.txt']);
  });

  describe('an extraction failure is announced at import time while the attachment keeps its error code', () => {
    it.each([
      ['encrypted_pdf', 'errorPasswordProtected'],
      ['password_protected_office', 'errorPasswordProtected'],
      ['corrupted_file', 'errorCorrupted'],
      ['scanned_pdf', 'errorNoText'],
      ['extraction_timeout', 'errorGeneric'],
      ['extraction_error', 'errorGeneric'],
    ])('%s shows %s', async (errorCode, copyKey) => {
      const composer = renderComposer();
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) =>
        files.map((item) => toAttachment(item, { extractionErrorCode: errorCode, base64Data: '' })));

      await act(async () => { await composer.current.pickFiles([file('report.pdf')]); });
      await settle();

      expect(mockShowToast).toHaveBeenCalledExactlyOnceWith(`${copyKey}({"fileName":"report.pdf"})`);
      expect(composer.current.attachments).toEqual([
        expect.objectContaining({ fileName: 'report.pdf', extractionErrorCode: errorCode }),
      ]);
    });

    // The toast has a single slot: shown one by one, only the last notice of a batch would be seen.
    it('summarizes a batch with several failures and too many files into one toast that keeps every notice', async () => {
      const composer = renderComposer();
      const codes: Record<string, string> = { 'a.pdf': 'encrypted_pdf', 'c.pdf': 'scanned_pdf' };
      mockValidateAndConvertFiles.mockImplementationOnce(async (files: File[]) =>
        files.map((item) => toAttachment(item, codes[item.name] ? { extractionErrorCode: codes[item.name], base64Data: '' } : {})));

      await act(async () => {
        await composer.current.pickFiles([file('a.pdf'), file('b.txt'), file('c.pdf'), file('d.txt')]);
      });
      await settle();

      const tooMany = 'tooManyFiles({"maxFiles":3})';
      expect(mockShowToast.mock.calls.at(-1)?.[0]).toBe([
        tooMany,
        'errorPasswordProtected({"fileName":"a.pdf"})',
        'errorNoText({"fileName":"c.pdf"})',
      ].join('\n'));
      // "Too many files" is shown once before the files are read; after that only the summary follows.
      expect(mockShowToast.mock.calls.map(([message]) => message)).toEqual([tooMany, expect.stringContaining('\n')]);
      expect(composer.current.attachments.map((item) => item.fileName)).toEqual(['a.pdf', 'b.txt', 'c.pdf']);
    });

    it('shows nothing for an attachment that extracted successfully', async () => {
      const composer = renderComposer();
      await act(async () => { await composer.current.pickFiles([file('ok.txt')]); });
      await settle();
      expect(mockShowToast).not.toHaveBeenCalled();
      expect(extractionFailureCopyKey(undefined)).toBeNull();
    });
  });
});
